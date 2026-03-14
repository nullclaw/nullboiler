const std = @import("std");
const log = std.log.scoped(.store);
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ── Helpers ───────────────────────────────────────────────────────────

fn allocStr(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) ![]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    const copy = try allocator.alloc(u8, len);
    @memcpy(copy, ptr[0..len]);
    return copy;
}

fn allocStrOpt(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt, col: c_int) !?[]const u8 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return try allocStr(allocator, stmt, col);
}

fn colInt(stmt: ?*c.sqlite3_stmt, col: c_int) i64 {
    return c.sqlite3_column_int64(stmt, col);
}

fn colIntOpt(stmt: ?*c.sqlite3_stmt, col: c_int) ?i64 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return c.sqlite3_column_int64(stmt, col);
}

fn bindTextOpt(stmt: ?*c.sqlite3_stmt, col: c_int, val: ?[]const u8) void {
    if (val) |v| {
        _ = c.sqlite3_bind_text(stmt, col, v.ptr, @intCast(v.len), SQLITE_STATIC);
    } else {
        _ = c.sqlite3_bind_null(stmt, col);
    }
}

fn bindIntOpt(stmt: ?*c.sqlite3_stmt, col: c_int, val: ?i64) void {
    if (val) |v| {
        _ = c.sqlite3_bind_int64(stmt, col, v);
    } else {
        _ = c.sqlite3_bind_null(stmt, col);
    }
}

// ── Store ─────────────────────────────────────────────────────────────

pub const Store = struct {
    db: ?*c.sqlite3,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Self {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        if (db) |d| {
            _ = c.sqlite3_busy_timeout(d, 5000);
        }

        var self = Self{ .db = db, .allocator = allocator };
        self.configurePragmas();
        try self.migrate();

        log.info("database initialized", .{});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
            self.db = null;
        }
    }

    fn configurePragmas(self: *Self) void {
        const pragmas = [_][*:0]const u8{
            "PRAGMA journal_mode = WAL;",
            "PRAGMA synchronous = NORMAL;",
            "PRAGMA foreign_keys = ON;",
            "PRAGMA busy_timeout = 5000;",
            "PRAGMA temp_store = MEMORY;",
            "PRAGMA cache_size = -2000;",
        };
        for (pragmas) |pragma| {
            var err_msg: [*c]u8 = null;
            const prc = c.sqlite3_exec(self.db, pragma, null, null, &err_msg);
            if (prc != c.SQLITE_OK) {
                if (err_msg) |msg| {
                    log.warn("pragma failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                    c.sqlite3_free(msg);
                }
            }
        }
    }

    fn migrate(self: *Self) !void {
        // Migration 001
        const sql_001 = @embedFile("migrations/001_init.sql");
        var err_msg: [*c]u8 = null;
        var prc = c.sqlite3_exec(self.db, sql_001.ptr, null, null, &err_msg);
        if (prc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration 001 failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }

        // Migration 002 — new tables (idempotent via IF NOT EXISTS)
        const sql_002 = @embedFile("migrations/002_advanced_steps.sql");
        prc = c.sqlite3_exec(self.db, sql_002.ptr, null, null, &err_msg);
        if (prc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration 002 failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }

        // Migration 003 — tracker integration state
        const sql_003 = @embedFile("migrations/003_tracker.sql");
        prc = c.sqlite3_exec(self.db, sql_003.ptr, null, null, &err_msg);
        if (prc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration 003 failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }

        // Migration 004 — orchestration schema (workflows, checkpoints, agent_events)
        const sql_004 = @embedFile("migrations/004_orchestration.sql");
        prc = c.sqlite3_exec(self.db, sql_004.ptr, null, null, &err_msg);
        if (prc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration 004 failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }
    }

    pub fn beginTransaction(self: *Self) !void {
        try self.execSql("BEGIN IMMEDIATE TRANSACTION;");
    }

    pub fn commitTransaction(self: *Self) !void {
        try self.execSql("COMMIT;");
    }

    pub fn rollbackTransaction(self: *Self) !void {
        try self.execSql("ROLLBACK;");
    }

    fn execSql(self: *Self, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.warn("sql exec failed (rc={d}): {s}", .{ rc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.SqliteExecFailed;
        }
    }

    // ── Worker CRUD ───────────────────────────────────────────────────

    pub fn insertWorker(
        self: *Self,
        id: []const u8,
        url: []const u8,
        token: []const u8,
        protocol: []const u8,
        model: ?[]const u8,
        tags_json: []const u8,
        max_concurrent: i64,
        source: []const u8,
    ) !void {
        const sql = "INSERT INTO workers (id, url, token, protocol, model, tags_json, max_concurrent, source, status, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'active', ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, url.ptr, @intCast(url.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, token.ptr, @intCast(token.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, protocol.ptr, @intCast(protocol.len), SQLITE_STATIC);
        bindTextOpt(stmt, 5, model);
        _ = c.sqlite3_bind_text(stmt, 6, tags_json.ptr, @intCast(tags_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, max_concurrent);
        _ = c.sqlite3_bind_text(stmt, 8, source.ptr, @intCast(source.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 9, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn listWorkers(self: *Self, allocator: std.mem.Allocator) ![]types.WorkerRow {
        const sql = "SELECT id, url, token, protocol, model, tags_json, max_concurrent, source, status, consecutive_failures, circuit_open_until_ms, last_error_text, last_health_ms, created_at_ms FROM workers ORDER BY created_at_ms DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayListUnmanaged(types.WorkerRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = try allocStr(allocator, stmt, 0),
                .url = try allocStr(allocator, stmt, 1),
                .token = try allocStr(allocator, stmt, 2),
                .protocol = try allocStr(allocator, stmt, 3),
                .model = try allocStrOpt(allocator, stmt, 4),
                .tags_json = try allocStr(allocator, stmt, 5),
                .max_concurrent = colInt(stmt, 6),
                .source = try allocStr(allocator, stmt, 7),
                .status = try allocStr(allocator, stmt, 8),
                .consecutive_failures = colInt(stmt, 9),
                .circuit_open_until_ms = colIntOpt(stmt, 10),
                .last_error_text = try allocStrOpt(allocator, stmt, 11),
                .last_health_ms = colIntOpt(stmt, 12),
                .created_at_ms = colInt(stmt, 13),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getWorker(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?types.WorkerRow {
        const sql = "SELECT id, url, token, protocol, model, tags_json, max_concurrent, source, status, consecutive_failures, circuit_open_until_ms, last_error_text, last_health_ms, created_at_ms FROM workers WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return types.WorkerRow{
            .id = try allocStr(allocator, stmt, 0),
            .url = try allocStr(allocator, stmt, 1),
            .token = try allocStr(allocator, stmt, 2),
            .protocol = try allocStr(allocator, stmt, 3),
            .model = try allocStrOpt(allocator, stmt, 4),
            .tags_json = try allocStr(allocator, stmt, 5),
            .max_concurrent = colInt(stmt, 6),
            .source = try allocStr(allocator, stmt, 7),
            .status = try allocStr(allocator, stmt, 8),
            .consecutive_failures = colInt(stmt, 9),
            .circuit_open_until_ms = colIntOpt(stmt, 10),
            .last_error_text = try allocStrOpt(allocator, stmt, 11),
            .last_health_ms = colIntOpt(stmt, 12),
            .created_at_ms = colInt(stmt, 13),
        };
    }

    pub fn deleteWorker(self: *Self, id: []const u8) !void {
        const sql = "DELETE FROM workers WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn updateWorkerStatus(self: *Self, id: []const u8, status: []const u8, health_ms: i64) !void {
        const sql = "UPDATE workers SET status = ?, last_health_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, health_ms);
        _ = c.sqlite3_bind_text(stmt, 3, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn markWorkerSuccess(self: *Self, id: []const u8, health_ms: i64) !void {
        const sql = "UPDATE workers SET status = 'active', consecutive_failures = 0, circuit_open_until_ms = NULL, last_error_text = NULL, last_health_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, health_ms);
        _ = c.sqlite3_bind_text(stmt, 2, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn markWorkerFailure(
        self: *Self,
        id: []const u8,
        error_text: []const u8,
        health_ms: i64,
        failure_threshold: i64,
        circuit_open_until_ms: i64,
    ) !void {
        const sql =
            "UPDATE workers SET " ++
            "consecutive_failures = consecutive_failures + 1, " ++
            "last_error_text = ?, " ++
            "last_health_ms = ?, " ++
            "status = CASE WHEN consecutive_failures + 1 >= ? THEN 'dead' ELSE status END, " ++
            "circuit_open_until_ms = CASE WHEN consecutive_failures + 1 >= ? THEN ? ELSE circuit_open_until_ms END " ++
            "WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, error_text.ptr, @intCast(error_text.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, health_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, failure_threshold);
        _ = c.sqlite3_bind_int64(stmt, 4, failure_threshold);
        _ = c.sqlite3_bind_int64(stmt, 5, circuit_open_until_ms);
        _ = c.sqlite3_bind_text(stmt, 6, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn deleteWorkersBySource(self: *Self, source: []const u8) !void {
        const sql = "DELETE FROM workers WHERE source = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, source.ptr, @intCast(source.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Run CRUD ──────────────────────────────────────────────────────

    pub fn insertRun(
        self: *Self,
        id: []const u8,
        idempotency_key: ?[]const u8,
        status: []const u8,
        workflow_json: []const u8,
        input_json: []const u8,
        callbacks_json: []const u8,
    ) !void {
        const sql = "INSERT INTO runs (id, idempotency_key, status, workflow_json, input_json, callbacks_json, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 2, idempotency_key);
        _ = c.sqlite3_bind_text(stmt, 3, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, workflow_json.ptr, @intCast(workflow_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, input_json.ptr, @intCast(input_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, callbacks_json.ptr, @intCast(callbacks_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, now);
        _ = c.sqlite3_bind_int64(stmt, 8, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getRun(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?types.RunRow {
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, state_json, config_json, parent_run_id FROM runs WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return types.RunRow{
            .id = try allocStr(allocator, stmt, 0),
            .idempotency_key = try allocStrOpt(allocator, stmt, 1),
            .status = try allocStr(allocator, stmt, 2),
            .workflow_json = try allocStr(allocator, stmt, 3),
            .input_json = try allocStr(allocator, stmt, 4),
            .callbacks_json = try allocStr(allocator, stmt, 5),
            .error_text = try allocStrOpt(allocator, stmt, 6),
            .created_at_ms = colInt(stmt, 7),
            .updated_at_ms = colInt(stmt, 8),
            .started_at_ms = colIntOpt(stmt, 9),
            .ended_at_ms = colIntOpt(stmt, 10),
            .state_json = try allocStrOpt(allocator, stmt, 11),
            .config_json = try allocStrOpt(allocator, stmt, 12),
            .parent_run_id = try allocStrOpt(allocator, stmt, 13),
        };
    }

    pub fn getRunByIdempotencyKey(self: *Self, allocator: std.mem.Allocator, key: []const u8) !?types.RunRow {
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, state_json, config_json, parent_run_id FROM runs WHERE idempotency_key = ? ORDER BY created_at_ms DESC LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, key.ptr, @intCast(key.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return types.RunRow{
            .id = try allocStr(allocator, stmt, 0),
            .idempotency_key = try allocStrOpt(allocator, stmt, 1),
            .status = try allocStr(allocator, stmt, 2),
            .workflow_json = try allocStr(allocator, stmt, 3),
            .input_json = try allocStr(allocator, stmt, 4),
            .callbacks_json = try allocStr(allocator, stmt, 5),
            .error_text = try allocStrOpt(allocator, stmt, 6),
            .created_at_ms = colInt(stmt, 7),
            .updated_at_ms = colInt(stmt, 8),
            .started_at_ms = colIntOpt(stmt, 9),
            .ended_at_ms = colIntOpt(stmt, 10),
            .state_json = try allocStrOpt(allocator, stmt, 11),
            .config_json = try allocStrOpt(allocator, stmt, 12),
            .parent_run_id = try allocStrOpt(allocator, stmt, 13),
        };
    }

    pub fn listRuns(self: *Self, allocator: std.mem.Allocator, status_filter: ?[]const u8, limit: i64, offset: i64) ![]types.RunRow {
        var stmt: ?*c.sqlite3_stmt = null;
        if (status_filter != null) {
            const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, state_json, config_json, parent_run_id FROM runs WHERE status = ? ORDER BY created_at_ms DESC LIMIT ? OFFSET ?";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            _ = c.sqlite3_bind_text(stmt, 1, status_filter.?.ptr, @intCast(status_filter.?.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 2, limit);
            _ = c.sqlite3_bind_int64(stmt, 3, offset);
        } else {
            const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, state_json, config_json, parent_run_id FROM runs ORDER BY created_at_ms DESC LIMIT ? OFFSET ?";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            _ = c.sqlite3_bind_int64(stmt, 1, limit);
            _ = c.sqlite3_bind_int64(stmt, 2, offset);
        }
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayListUnmanaged(types.RunRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = try allocStr(allocator, stmt, 0),
                .idempotency_key = try allocStrOpt(allocator, stmt, 1),
                .status = try allocStr(allocator, stmt, 2),
                .workflow_json = try allocStr(allocator, stmt, 3),
                .input_json = try allocStr(allocator, stmt, 4),
                .callbacks_json = try allocStr(allocator, stmt, 5),
                .error_text = try allocStrOpt(allocator, stmt, 6),
                .created_at_ms = colInt(stmt, 7),
                .updated_at_ms = colInt(stmt, 8),
                .started_at_ms = colIntOpt(stmt, 9),
                .ended_at_ms = colIntOpt(stmt, 10),
                .state_json = try allocStrOpt(allocator, stmt, 11),
                .config_json = try allocStrOpt(allocator, stmt, 12),
                .parent_run_id = try allocStrOpt(allocator, stmt, 13),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn updateRunStatus(self: *Self, id: []const u8, status: []const u8, error_text: ?[]const u8) !void {
        const sql = "UPDATE runs SET status = ?, error_text = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_STATIC);
        bindTextOpt(stmt, 2, error_text);
        _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 4, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getActiveRuns(self: *Self, allocator: std.mem.Allocator) ![]types.RunRow {
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, state_json, config_json, parent_run_id FROM runs WHERE status IN ('running', 'paused') ORDER BY created_at_ms DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayListUnmanaged(types.RunRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = try allocStr(allocator, stmt, 0),
                .idempotency_key = try allocStrOpt(allocator, stmt, 1),
                .status = try allocStr(allocator, stmt, 2),
                .workflow_json = try allocStr(allocator, stmt, 3),
                .input_json = try allocStr(allocator, stmt, 4),
                .callbacks_json = try allocStr(allocator, stmt, 5),
                .error_text = try allocStrOpt(allocator, stmt, 6),
                .created_at_ms = colInt(stmt, 7),
                .updated_at_ms = colInt(stmt, 8),
                .started_at_ms = colIntOpt(stmt, 9),
                .ended_at_ms = colIntOpt(stmt, 10),
                .state_json = try allocStrOpt(allocator, stmt, 11),
                .config_json = try allocStrOpt(allocator, stmt, 12),
                .parent_run_id = try allocStrOpt(allocator, stmt, 13),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ── Step CRUD ─────────────────────────────────────────────────────

    pub fn insertStep(self: *Self, id: []const u8, run_id: []const u8, def_step_id: []const u8, step_type: []const u8, status: []const u8, input_json: []const u8, max_attempts: i64, timeout_ms: ?i64, parent_step_id: ?[]const u8, item_index: ?i64) !void {
        const sql = "INSERT INTO steps (id, run_id, def_step_id, type, status, input_json, max_attempts, timeout_ms, next_attempt_at_ms, parent_step_id, item_index, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, def_step_id.ptr, @intCast(def_step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, step_type.ptr, @intCast(step_type.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, input_json.ptr, @intCast(input_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, max_attempts);
        bindIntOpt(stmt, 8, timeout_ms);
        bindTextOpt(stmt, 9, parent_step_id);
        bindIntOpt(stmt, 10, item_index);
        _ = c.sqlite3_bind_int64(stmt, 11, now);
        _ = c.sqlite3_bind_int64(stmt, 12, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn insertStepWithIteration(self: *Self, id: []const u8, run_id: []const u8, def_step_id: []const u8, step_type: []const u8, status: []const u8, input_json: []const u8, max_attempts: i64, timeout_ms: ?i64, parent_step_id: ?[]const u8, item_index: ?i64, iteration_index: i64) !void {
        const sql = "INSERT INTO steps (id, run_id, def_step_id, type, status, input_json, max_attempts, timeout_ms, next_attempt_at_ms, parent_step_id, item_index, iteration_index, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, def_step_id.ptr, @intCast(def_step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, step_type.ptr, @intCast(step_type.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, input_json.ptr, @intCast(input_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, max_attempts);
        bindIntOpt(stmt, 8, timeout_ms);
        bindTextOpt(stmt, 9, parent_step_id);
        bindIntOpt(stmt, 10, item_index);
        _ = c.sqlite3_bind_int64(stmt, 11, iteration_index);
        _ = c.sqlite3_bind_int64(stmt, 12, now);
        _ = c.sqlite3_bind_int64(stmt, 13, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn insertStepDep(self: *Self, step_id: []const u8, depends_on: []const u8) !void {
        const sql = "INSERT INTO step_deps (step_id, depends_on) VALUES (?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, depends_on.ptr, @intCast(depends_on.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getStepsByRun(self: *Self, allocator: std.mem.Allocator, run_id: []const u8) ![]types.StepRow {
        const sql = "SELECT id, run_id, def_step_id, type, status, worker_id, input_json, output_json, error_text, attempt, max_attempts, timeout_ms, next_attempt_at_ms, parent_step_id, item_index, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, child_run_id, iteration_index FROM steps WHERE run_id = ? ORDER BY created_at_ms ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.StepRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, try readStepRow(allocator, stmt));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn getStep(self: *Self, allocator: std.mem.Allocator, id: []const u8) !?types.StepRow {
        const sql = "SELECT id, run_id, def_step_id, type, status, worker_id, input_json, output_json, error_text, attempt, max_attempts, timeout_ms, next_attempt_at_ms, parent_step_id, item_index, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, child_run_id, iteration_index FROM steps WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return try readStepRow(allocator, stmt);
    }

    pub fn updateStepStatus(self: *Self, id: []const u8, status: []const u8, worker_id: ?[]const u8, output_json: ?[]const u8, error_text: ?[]const u8, attempt: i64) !void {
        const sql = "UPDATE steps SET status = ?, worker_id = ?, output_json = ?, error_text = ?, attempt = ?, next_attempt_at_ms = NULL, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_STATIC);
        bindTextOpt(stmt, 2, worker_id);
        bindTextOpt(stmt, 3, output_json);
        bindTextOpt(stmt, 4, error_text);
        _ = c.sqlite3_bind_int64(stmt, 5, attempt);
        _ = c.sqlite3_bind_int64(stmt, 6, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 7, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn claimReadyStep(self: *Self, step_id: []const u8, worker_id: ?[]const u8, now_ms: i64) !bool {
        const sql =
            "UPDATE steps SET status = 'running', worker_id = ?, updated_at_ms = ?, started_at_ms = COALESCE(started_at_ms, ?) " ++
            "WHERE id = ? AND status = 'ready' AND (next_attempt_at_ms IS NULL OR next_attempt_at_ms <= ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        bindTextOpt(stmt, 1, worker_id);
        _ = c.sqlite3_bind_int64(stmt, 2, now_ms);
        _ = c.sqlite3_bind_int64(stmt, 3, now_ms);
        _ = c.sqlite3_bind_text(stmt, 4, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, now_ms);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStepFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    pub fn scheduleStepRetry(self: *Self, step_id: []const u8, next_attempt: i64, attempt: i64, error_text: []const u8) !void {
        const sql = "UPDATE steps SET status = 'ready', worker_id = NULL, output_json = NULL, error_text = ?, attempt = ?, next_attempt_at_ms = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, error_text.ptr, @intCast(error_text.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, attempt);
        _ = c.sqlite3_bind_int64(stmt, 3, next_attempt);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 5, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn countStepsByStatus(self: *Self, run_id: []const u8, status: []const u8) !i64 {
        const sql = "SELECT COUNT(*) FROM steps WHERE run_id = ? AND status = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, status.ptr, @intCast(status.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return colInt(stmt, 0);
    }

    pub fn getChildSteps(self: *Self, allocator: std.mem.Allocator, parent_step_id: []const u8) ![]types.StepRow {
        const sql = "SELECT id, run_id, def_step_id, type, status, worker_id, input_json, output_json, error_text, attempt, max_attempts, timeout_ms, next_attempt_at_ms, parent_step_id, item_index, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms, child_run_id, iteration_index FROM steps WHERE parent_step_id = ? ORDER BY item_index ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, parent_step_id.ptr, @intCast(parent_step_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.StepRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, try readStepRow(allocator, stmt));
        }
        return list.toOwnedSlice(allocator);
    }

    /// Count how many running tasks a worker currently has.
    pub fn countRunningStepsByWorker(self: *Self, worker_id: []const u8) !i64 {
        const sql = "SELECT COUNT(*) FROM steps WHERE worker_id = ? AND status = 'running'";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, worker_id.ptr, @intCast(worker_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return colInt(stmt, 0);
    }

    fn readStepRow(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt) !types.StepRow {
        return types.StepRow{
            .id = try allocStr(allocator, stmt, 0),
            .run_id = try allocStr(allocator, stmt, 1),
            .def_step_id = try allocStr(allocator, stmt, 2),
            .type = try allocStr(allocator, stmt, 3),
            .status = try allocStr(allocator, stmt, 4),
            .worker_id = try allocStrOpt(allocator, stmt, 5),
            .input_json = try allocStr(allocator, stmt, 6),
            .output_json = try allocStrOpt(allocator, stmt, 7),
            .error_text = try allocStrOpt(allocator, stmt, 8),
            .attempt = colInt(stmt, 9),
            .max_attempts = colInt(stmt, 10),
            .timeout_ms = colIntOpt(stmt, 11),
            .next_attempt_at_ms = colIntOpt(stmt, 12),
            .parent_step_id = try allocStrOpt(allocator, stmt, 13),
            .item_index = colIntOpt(stmt, 14),
            .created_at_ms = colInt(stmt, 15),
            .updated_at_ms = colInt(stmt, 16),
            .started_at_ms = colIntOpt(stmt, 17),
            .ended_at_ms = colIntOpt(stmt, 18),
            .child_run_id = try allocStrOpt(allocator, stmt, 19),
            .iteration_index = colIntOpt(stmt, 20) orelse 0,
        };
    }

    // ── Event CRUD ────────────────────────────────────────────────────

    pub fn insertEvent(self: *Self, run_id: []const u8, step_id: ?[]const u8, kind: []const u8, data_json: []const u8) !void {
        const sql = "INSERT INTO events (run_id, step_id, kind, data_json, ts_ms) VALUES (?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 2, step_id);
        _ = c.sqlite3_bind_text(stmt, 3, kind.ptr, @intCast(kind.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, data_json.ptr, @intCast(data_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getEventsByRun(self: *Self, allocator: std.mem.Allocator, run_id: []const u8) ![]types.EventRow {
        const sql = "SELECT id, run_id, step_id, kind, data_json, ts_ms FROM events WHERE run_id = ? ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.EventRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = colInt(stmt, 0),
                .run_id = try allocStr(allocator, stmt, 1),
                .step_id = try allocStrOpt(allocator, stmt, 2),
                .kind = try allocStr(allocator, stmt, 3),
                .data_json = try allocStr(allocator, stmt, 4),
                .ts_ms = colInt(stmt, 5),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ── Artifact CRUD ─────────────────────────────────────────────────

    pub fn insertArtifact(self: *Self, id: []const u8, run_id: []const u8, step_id: ?[]const u8, kind: []const u8, uri: []const u8, meta_json: []const u8) !void {
        const sql = "INSERT INTO artifacts (id, run_id, step_id, kind, uri, meta_json, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 3, step_id);
        _ = c.sqlite3_bind_text(stmt, 4, kind.ptr, @intCast(kind.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, uri.ptr, @intCast(uri.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, meta_json.ptr, @intCast(meta_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getArtifactsByRun(self: *Self, allocator: std.mem.Allocator, run_id: []const u8) ![]types.ArtifactRow {
        const sql = "SELECT id, run_id, step_id, kind, uri, meta_json, created_at_ms FROM artifacts WHERE run_id = ? ORDER BY created_at_ms ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.ArtifactRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = try allocStr(allocator, stmt, 0),
                .run_id = try allocStr(allocator, stmt, 1),
                .step_id = try allocStrOpt(allocator, stmt, 2),
                .kind = try allocStr(allocator, stmt, 3),
                .uri = try allocStr(allocator, stmt, 4),
                .meta_json = try allocStr(allocator, stmt, 5),
                .created_at_ms = colInt(stmt, 6),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ── Tracker Runs ─────────────────────────────────────────────────

    pub fn upsertTrackerRun(
        self: *Self,
        task_id: []const u8,
        tracker_run_id: []const u8,
        boiler_run_id: []const u8,
        lease_id: []const u8,
        lease_token: []const u8,
        pipeline_id: []const u8,
        agent_role: []const u8,
        task_title: []const u8,
        task_stage: []const u8,
        task_version: i64,
        success_trigger: ?[]const u8,
        artifact_kind: []const u8,
        state: []const u8,
        claimed_at_ms: i64,
        last_heartbeat_ms: ?i64,
        lease_expires_at_ms: ?i64,
        completed_at_ms: ?i64,
        last_error_text: ?[]const u8,
    ) !void {
        const sql =
            "INSERT INTO tracker_runs (" ++
            "task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text" ++
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " ++
            "ON CONFLICT(task_id) DO UPDATE SET " ++
            "tracker_run_id = excluded.tracker_run_id, boiler_run_id = excluded.boiler_run_id, lease_id = excluded.lease_id, lease_token = excluded.lease_token, " ++
            "pipeline_id = excluded.pipeline_id, agent_role = excluded.agent_role, task_title = excluded.task_title, task_stage = excluded.task_stage, task_version = excluded.task_version, " ++
            "success_trigger = excluded.success_trigger, artifact_kind = excluded.artifact_kind, state = excluded.state, claimed_at_ms = excluded.claimed_at_ms, " ++
            "last_heartbeat_ms = excluded.last_heartbeat_ms, lease_expires_at_ms = excluded.lease_expires_at_ms, completed_at_ms = excluded.completed_at_ms, last_error_text = excluded.last_error_text";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, task_id.ptr, @intCast(task_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, tracker_run_id.ptr, @intCast(tracker_run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, boiler_run_id.ptr, @intCast(boiler_run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, lease_id.ptr, @intCast(lease_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, lease_token.ptr, @intCast(lease_token.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, pipeline_id.ptr, @intCast(pipeline_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 7, agent_role.ptr, @intCast(agent_role.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 8, task_title.ptr, @intCast(task_title.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 9, task_stage.ptr, @intCast(task_stage.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 10, task_version);
        bindTextOpt(stmt, 11, success_trigger);
        _ = c.sqlite3_bind_text(stmt, 12, artifact_kind.ptr, @intCast(artifact_kind.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 13, state.ptr, @intCast(state.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 14, claimed_at_ms);
        bindIntOpt(stmt, 15, last_heartbeat_ms);
        bindIntOpt(stmt, 16, lease_expires_at_ms);
        bindIntOpt(stmt, 17, completed_at_ms);
        bindTextOpt(stmt, 18, last_error_text);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getTrackerRunByTaskId(self: *Self, allocator: std.mem.Allocator, task_id: []const u8) !?types.TrackerRunRow {
        const sql = "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs WHERE task_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, task_id.ptr, @intCast(task_id.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try readTrackerRunRow(allocator, stmt);
    }

    pub fn getTrackerRunByBoilerRunId(self: *Self, allocator: std.mem.Allocator, boiler_run_id: []const u8) !?types.TrackerRunRow {
        const sql = "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs WHERE boiler_run_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, boiler_run_id.ptr, @intCast(boiler_run_id.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
        return try readTrackerRunRow(allocator, stmt);
    }

    pub fn listTrackerRuns(self: *Self, allocator: std.mem.Allocator, state_filter: ?[]const u8, limit: ?i64) ![]types.TrackerRunRow {
        var stmt: ?*c.sqlite3_stmt = null;
        if (state_filter) |state| {
            const sql = if (limit != null)
                "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs WHERE state = ? ORDER BY claimed_at_ms DESC LIMIT ?"
            else
                "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs WHERE state = ? ORDER BY claimed_at_ms DESC";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            _ = c.sqlite3_bind_text(stmt, 1, state.ptr, @intCast(state.len), SQLITE_STATIC);
            if (limit) |l| _ = c.sqlite3_bind_int64(stmt, 2, l);
        } else {
            const sql = if (limit != null)
                "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs ORDER BY claimed_at_ms DESC LIMIT ?"
            else
                "SELECT task_id, tracker_run_id, boiler_run_id, lease_id, lease_token, pipeline_id, agent_role, task_title, task_stage, task_version, success_trigger, artifact_kind, state, claimed_at_ms, last_heartbeat_ms, lease_expires_at_ms, completed_at_ms, last_error_text FROM tracker_runs ORDER BY claimed_at_ms DESC";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            if (limit) |l| _ = c.sqlite3_bind_int64(stmt, 1, l);
        }
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayListUnmanaged(types.TrackerRunRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, try readTrackerRunRow(allocator, stmt));
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn countTrackerRunsByState(self: *Self, state: []const u8) !i64 {
        const sql = "SELECT COUNT(*) FROM tracker_runs WHERE state = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, state.ptr, @intCast(state.len), SQLITE_STATIC);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return colInt(stmt, 0);
    }

    pub fn countTrackerRuns(self: *Self) !i64 {
        const sql = "SELECT COUNT(*) FROM tracker_runs";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return 0;
        return colInt(stmt, 0);
    }

    fn readTrackerRunRow(allocator: std.mem.Allocator, stmt: ?*c.sqlite3_stmt) !types.TrackerRunRow {
        return .{
            .task_id = try allocStr(allocator, stmt, 0),
            .tracker_run_id = try allocStr(allocator, stmt, 1),
            .boiler_run_id = try allocStr(allocator, stmt, 2),
            .lease_id = try allocStr(allocator, stmt, 3),
            .lease_token = try allocStr(allocator, stmt, 4),
            .pipeline_id = try allocStr(allocator, stmt, 5),
            .agent_role = try allocStr(allocator, stmt, 6),
            .task_title = try allocStr(allocator, stmt, 7),
            .task_stage = try allocStr(allocator, stmt, 8),
            .task_version = colInt(stmt, 9),
            .success_trigger = try allocStrOpt(allocator, stmt, 10),
            .artifact_kind = try allocStr(allocator, stmt, 11),
            .state = try allocStr(allocator, stmt, 12),
            .claimed_at_ms = colInt(stmt, 13),
            .last_heartbeat_ms = colIntOpt(stmt, 14),
            .lease_expires_at_ms = colIntOpt(stmt, 15),
            .completed_at_ms = colIntOpt(stmt, 16),
            .last_error_text = try allocStrOpt(allocator, stmt, 17),
        };
    }

    // ── Sub-workflow Helper ──────────────────────────────────────────

    pub fn updateStepInputJson(self: *Self, step_id: []const u8, input_json: []const u8) !void {
        const sql = "UPDATE steps SET input_json = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, input_json.ptr, @intCast(input_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn updateStepChildRunId(self: *Self, step_id: []const u8, child_run_id: []const u8) !void {
        const sql = "UPDATE steps SET child_run_id = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, child_run_id.ptr, @intCast(child_run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Workflow CRUD ─────────────────────────────────────────────────

    pub fn createWorkflow(self: *Self, id: []const u8, name: []const u8, definition_json: []const u8) !void {
        return self.createWorkflowWithVersion(id, name, definition_json, 1);
    }

    pub fn createWorkflowWithVersion(self: *Self, id: []const u8, name: []const u8, definition_json: []const u8, version: i64) !void {
        const sql = "INSERT INTO workflows (id, name, definition_json, version, created_at_ms, updated_at_ms) VALUES (?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, name.ptr, @intCast(name.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, definition_json.ptr, @intCast(definition_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 4, version);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        _ = c.sqlite3_bind_int64(stmt, 6, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getWorkflow(self: *Self, alloc: std.mem.Allocator, id: []const u8) !?types.WorkflowRow {
        const sql = "SELECT id, name, definition_json, version, created_at_ms, updated_at_ms FROM workflows WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return types.WorkflowRow{
            .id = try allocStr(alloc, stmt, 0),
            .name = try allocStr(alloc, stmt, 1),
            .definition_json = try allocStr(alloc, stmt, 2),
            .version = colInt(stmt, 3),
            .created_at_ms = colInt(stmt, 4),
            .updated_at_ms = colInt(stmt, 5),
        };
    }

    pub fn listWorkflows(self: *Self, alloc: std.mem.Allocator) ![]types.WorkflowRow {
        const sql = "SELECT id, name, definition_json, version, created_at_ms, updated_at_ms FROM workflows ORDER BY created_at_ms DESC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        var list: std.ArrayListUnmanaged(types.WorkflowRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(alloc, .{
                .id = try allocStr(alloc, stmt, 0),
                .name = try allocStr(alloc, stmt, 1),
                .definition_json = try allocStr(alloc, stmt, 2),
                .version = colInt(stmt, 3),
                .created_at_ms = colInt(stmt, 4),
                .updated_at_ms = colInt(stmt, 5),
            });
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn updateWorkflow(self: *Self, id: []const u8, name: []const u8, definition_json: []const u8) !void {
        return self.updateWorkflowWithVersion(id, name, definition_json, null);
    }

    pub fn updateWorkflowWithVersion(self: *Self, id: []const u8, name: []const u8, definition_json: []const u8, version: ?i64) !void {
        if (version) |v| {
            const sql = "UPDATE workflows SET name = ?, definition_json = ?, version = ?, updated_at_ms = ? WHERE id = ?";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, definition_json.ptr, @intCast(definition_json.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 3, v);
            _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
            _ = c.sqlite3_bind_text(stmt, 5, id.ptr, @intCast(id.len), SQLITE_STATIC);

            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
                return error.SqliteStepFailed;
            }
        } else {
            const sql = "UPDATE workflows SET name = ?, definition_json = ?, updated_at_ms = ? WHERE id = ?";
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            defer _ = c.sqlite3_finalize(stmt);

            _ = c.sqlite3_bind_text(stmt, 1, name.ptr, @intCast(name.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(stmt, 2, definition_json.ptr, @intCast(definition_json.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 3, ids.nowMs());
            _ = c.sqlite3_bind_text(stmt, 4, id.ptr, @intCast(id.len), SQLITE_STATIC);

            if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
                return error.SqliteStepFailed;
            }
        }
    }

    pub fn deleteWorkflow(self: *Self, id: []const u8) !void {
        const sql = "DELETE FROM workflows WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Token Accounting ──────────────────────────────────────────────

    pub fn updateStepTokens(self: *Self, step_id: []const u8, input_tokens: i64, output_tokens: i64) !void {
        const sql = "UPDATE steps SET input_tokens = ?, output_tokens = ?, total_tokens = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, input_tokens);
        _ = c.sqlite3_bind_int64(stmt, 2, output_tokens);
        _ = c.sqlite3_bind_int64(stmt, 3, input_tokens + output_tokens);
        _ = c.sqlite3_bind_text(stmt, 4, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn updateRunTokens(self: *Self, run_id: []const u8, input_delta: i64, output_delta: i64) !void {
        const sql = "UPDATE runs SET total_input_tokens = total_input_tokens + ?, total_output_tokens = total_output_tokens + ?, total_tokens = total_tokens + ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, input_delta);
        _ = c.sqlite3_bind_int64(stmt, 2, output_delta);
        _ = c.sqlite3_bind_int64(stmt, 3, input_delta + output_delta);
        _ = c.sqlite3_bind_text(stmt, 4, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getRunTokens(self: *Self, run_id: []const u8) !struct { input: i64, output: i64, total: i64 } {
        const sql = "SELECT COALESCE(total_input_tokens, 0), COALESCE(total_output_tokens, 0), COALESCE(total_tokens, 0) FROM runs WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) {
            return .{ .input = 0, .output = 0, .total = 0 };
        }

        return .{
            .input = colInt(stmt, 0),
            .output = colInt(stmt, 1),
            .total = colInt(stmt, 2),
        };
    }

    // ── Checkpoint CRUD ───────────────────────────────────────────────

    pub fn createCheckpoint(self: *Self, id: []const u8, run_id: []const u8, step_id: []const u8, parent_id: ?[]const u8, state_json: []const u8, completed_nodes_json: []const u8, version: i64, metadata_json: ?[]const u8) !void {
        const sql = "INSERT INTO checkpoints (id, run_id, step_id, parent_id, state_json, completed_nodes_json, version, metadata_json, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 4, parent_id);
        _ = c.sqlite3_bind_text(stmt, 5, state_json.ptr, @intCast(state_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 6, completed_nodes_json.ptr, @intCast(completed_nodes_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, version);
        bindTextOpt(stmt, 8, metadata_json);
        _ = c.sqlite3_bind_int64(stmt, 9, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getCheckpoint(self: *Self, alloc: std.mem.Allocator, id: []const u8) !?types.CheckpointRow {
        const sql = "SELECT id, run_id, step_id, parent_id, state_json, completed_nodes_json, version, metadata_json, created_at_ms FROM checkpoints WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return try readCheckpointRow(alloc, stmt);
    }

    pub fn listCheckpoints(self: *Self, alloc: std.mem.Allocator, run_id: []const u8) ![]types.CheckpointRow {
        const sql = "SELECT id, run_id, step_id, parent_id, state_json, completed_nodes_json, version, metadata_json, created_at_ms FROM checkpoints WHERE run_id = ? ORDER BY version ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.CheckpointRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(alloc, try readCheckpointRow(alloc, stmt));
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn getLatestCheckpoint(self: *Self, alloc: std.mem.Allocator, run_id: []const u8) !?types.CheckpointRow {
        const sql = "SELECT id, run_id, step_id, parent_id, state_json, completed_nodes_json, version, metadata_json, created_at_ms FROM checkpoints WHERE run_id = ? ORDER BY version DESC LIMIT 1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return try readCheckpointRow(alloc, stmt);
    }

    fn readCheckpointRow(alloc: std.mem.Allocator, stmt: ?*c.sqlite3_stmt) !types.CheckpointRow {
        return .{
            .id = try allocStr(alloc, stmt, 0),
            .run_id = try allocStr(alloc, stmt, 1),
            .step_id = try allocStr(alloc, stmt, 2),
            .parent_id = try allocStrOpt(alloc, stmt, 3),
            .state_json = try allocStr(alloc, stmt, 4),
            .completed_nodes_json = try allocStr(alloc, stmt, 5),
            .version = colInt(stmt, 6),
            .metadata_json = try allocStrOpt(alloc, stmt, 7),
            .created_at_ms = colInt(stmt, 8),
        };
    }

    // ── Agent Event CRUD ──────────────────────────────────────────────

    pub fn createAgentEvent(self: *Self, run_id: []const u8, step_id: []const u8, iteration: i64, tool: ?[]const u8, args_json: ?[]const u8, result_text: ?[]const u8, status: []const u8) !void {
        const sql = "INSERT INTO agent_events (run_id, step_id, iteration, tool, args_json, result_text, status, created_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 3, iteration);
        bindTextOpt(stmt, 4, tool);
        bindTextOpt(stmt, 5, args_json);
        bindTextOpt(stmt, 6, result_text);
        _ = c.sqlite3_bind_text(stmt, 7, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 8, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn listAgentEvents(self: *Self, alloc: std.mem.Allocator, run_id: []const u8, step_id: []const u8) ![]types.AgentEventRow {
        const sql = "SELECT id, run_id, step_id, iteration, tool, args_json, result_text, status, created_at_ms FROM agent_events WHERE run_id = ? AND step_id = ? ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.AgentEventRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(alloc, .{
                .id = colInt(stmt, 0),
                .run_id = try allocStr(alloc, stmt, 1),
                .step_id = try allocStr(alloc, stmt, 2),
                .iteration = colInt(stmt, 3),
                .tool = try allocStrOpt(alloc, stmt, 4),
                .args_json = try allocStrOpt(alloc, stmt, 5),
                .result_text = try allocStrOpt(alloc, stmt, 6),
                .status = try allocStr(alloc, stmt, 7),
                .created_at_ms = colInt(stmt, 8),
            });
        }
        return list.toOwnedSlice(alloc);
    }

    // ── Run State Management ──────────────────────────────────────────

    pub fn updateRunState(self: *Self, run_id: []const u8, state_json: []const u8) !void {
        const sql = "UPDATE runs SET state_json = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, state_json.ptr, @intCast(state_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 3, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn incrementCheckpointCount(self: *Self, run_id: []const u8) !void {
        const sql = "UPDATE runs SET checkpoint_count = COALESCE(checkpoint_count, 0) + 1, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn createRunWithState(self: *Self, id: []const u8, workflow_id: ?[]const u8, workflow_json: []const u8, input_json: []const u8, state_json: []const u8) !void {
        const sql = "INSERT INTO runs (id, status, workflow_id, workflow_json, input_json, callbacks_json, state_json, created_at_ms, updated_at_ms) VALUES (?, 'pending', ?, ?, ?, '[]', ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 2, workflow_id);
        _ = c.sqlite3_bind_text(stmt, 3, workflow_json.ptr, @intCast(workflow_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, input_json.ptr, @intCast(input_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, state_json.ptr, @intCast(state_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 6, now);
        _ = c.sqlite3_bind_int64(stmt, 7, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn setParentRunId(self: *Self, run_id: []const u8, parent_run_id: []const u8) !void {
        const sql = "UPDATE runs SET parent_run_id = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, parent_run_id.ptr, @intCast(parent_run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 3, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn setConfigJson(self: *Self, run_id: []const u8, config_json: []const u8) !void {
        const sql = "UPDATE runs SET config_json = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, config_json.ptr, @intCast(config_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 2, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 3, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn createForkedRun(self: *Self, id: []const u8, workflow_json: []const u8, state_json: []const u8, forked_from_run_id: []const u8, forked_from_checkpoint_id: []const u8) !void {
        const sql = "INSERT INTO runs (id, status, workflow_json, input_json, callbacks_json, state_json, forked_from_run_id, forked_from_checkpoint_id, created_at_ms, updated_at_ms) VALUES (?, 'pending', ?, '{}', '[]', ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        const now = ids.nowMs();
        _ = c.sqlite3_bind_text(stmt, 1, id.ptr, @intCast(id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, workflow_json.ptr, @intCast(workflow_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, state_json.ptr, @intCast(state_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, forked_from_run_id.ptr, @intCast(forked_from_run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 5, forked_from_checkpoint_id.ptr, @intCast(forked_from_checkpoint_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 6, now);
        _ = c.sqlite3_bind_int64(stmt, 7, now);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Pending State Injection CRUD ──────────────────────────────────

    pub fn createPendingInjection(self: *Self, run_id: []const u8, updates_json: []const u8, apply_after_step: ?[]const u8) !void {
        const sql = "INSERT INTO pending_state_injections (run_id, updates_json, apply_after_step, created_at_ms) VALUES (?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, updates_json.ptr, @intCast(updates_json.len), SQLITE_STATIC);
        bindTextOpt(stmt, 3, apply_after_step);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn consumePendingInjections(self: *Self, alloc: std.mem.Allocator, run_id: []const u8, completed_step: []const u8) ![]types.PendingInjectionRow {
        // Select injections where apply_after_step matches the completed step or is NULL
        const sql = "SELECT id, run_id, updates_json, apply_after_step, created_at_ms FROM pending_state_injections WHERE run_id = ? AND (apply_after_step IS NULL OR apply_after_step = ?) ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, completed_step.ptr, @intCast(completed_step.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.PendingInjectionRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(alloc, .{
                .id = colInt(stmt, 0),
                .run_id = try allocStr(alloc, stmt, 1),
                .updates_json = try allocStr(alloc, stmt, 2),
                .apply_after_step = try allocStrOpt(alloc, stmt, 3),
                .created_at_ms = colInt(stmt, 4),
            });
        }

        const result = try list.toOwnedSlice(alloc);

        // Delete consumed injections
        if (result.len > 0) {
            const del_sql = "DELETE FROM pending_state_injections WHERE run_id = ? AND (apply_after_step IS NULL OR apply_after_step = ?)";
            var del_stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(self.db, del_sql, -1, &del_stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            defer _ = c.sqlite3_finalize(del_stmt);

            _ = c.sqlite3_bind_text(del_stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_text(del_stmt, 2, completed_step.ptr, @intCast(completed_step.len), SQLITE_STATIC);

            if (c.sqlite3_step(del_stmt) != c.SQLITE_DONE) {
                return error.SqliteStepFailed;
            }
        }

        return result;
    }

    pub fn discardPendingInjections(self: *Self, run_id: []const u8) !void {
        const sql = "DELETE FROM pending_state_injections WHERE run_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Node Cache (Gap 3) ───────────────────────────────────────────

    pub fn getCachedResult(self: *Self, alloc: std.mem.Allocator, cache_key: []const u8) !?[]const u8 {
        const sql = "SELECT result_json, created_at_ms, ttl_ms FROM node_cache WHERE cache_key = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, cache_key.ptr, @intCast(cache_key.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        const result_json = try allocStr(alloc, stmt, 0);
        const created_at_ms = colInt(stmt, 1);
        const ttl_ms = colIntOpt(stmt, 2);

        // Check expiration
        if (ttl_ms) |ttl| {
            const now_ms = ids.nowMs();
            if (now_ms - created_at_ms > ttl) {
                // Expired — delete and return null
                const del_sql = "DELETE FROM node_cache WHERE cache_key = ?";
                var del_stmt: ?*c.sqlite3_stmt = null;
                if (c.sqlite3_prepare_v2(self.db, del_sql, -1, &del_stmt, null) == c.SQLITE_OK) {
                    _ = c.sqlite3_bind_text(del_stmt, 1, cache_key.ptr, @intCast(cache_key.len), SQLITE_STATIC);
                    _ = c.sqlite3_step(del_stmt);
                    _ = c.sqlite3_finalize(del_stmt);
                }
                alloc.free(result_json);
                return null;
            }
        }

        return result_json;
    }

    pub fn setCachedResult(self: *Self, cache_key: []const u8, node_name: []const u8, result_json: []const u8, ttl_ms: ?i64) !void {
        const sql = "INSERT OR REPLACE INTO node_cache (cache_key, node_name, result_json, created_at_ms, ttl_ms) VALUES (?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, cache_key.ptr, @intCast(cache_key.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, node_name.ptr, @intCast(node_name.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, result_json.ptr, @intCast(result_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 4, ids.nowMs());
        bindIntOpt(stmt, 5, ttl_ms);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Pending Writes (Gap 4) ───────────────────────────────────────

    pub fn savePendingWrite(self: *Self, run_id: []const u8, step_id: []const u8, channel: []const u8, value_json: []const u8) !void {
        const sql = "INSERT INTO pending_writes (run_id, step_id, channel, value_json, created_at_ms) VALUES (?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, channel.ptr, @intCast(channel.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, value_json.ptr, @intCast(value_json.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 5, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getPendingWrites(self: *Self, alloc: std.mem.Allocator, run_id: []const u8) ![]types.PendingWriteRow {
        const sql = "SELECT id, run_id, step_id, channel, value_json, created_at_ms FROM pending_writes WHERE run_id = ? ORDER BY id ASC";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.PendingWriteRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(alloc, .{
                .id = colInt(stmt, 0),
                .run_id = try allocStr(alloc, stmt, 1),
                .step_id = try allocStr(alloc, stmt, 2),
                .channel = try allocStr(alloc, stmt, 3),
                .value_json = try allocStr(alloc, stmt, 4),
                .created_at_ms = colInt(stmt, 5),
            });
        }
        return list.toOwnedSlice(alloc);
    }

    pub fn clearPendingWrites(self: *Self, run_id: []const u8) !void {
        const sql = "DELETE FROM pending_writes WHERE run_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────

test "Store: init and deinit" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
}

test "Store: insert and get worker" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[\"coder\"]", 3, "config");
    const w = (try s.getWorker(allocator, "w1")).?;
    defer allocator.free(w.id);
    defer allocator.free(w.url);
    defer allocator.free(w.token);
    defer allocator.free(w.protocol);
    if (w.model) |m| allocator.free(m);
    defer allocator.free(w.tags_json);
    defer allocator.free(w.source);
    defer allocator.free(w.status);
    try std.testing.expectEqualStrings("w1", w.id);
    try std.testing.expectEqualStrings("http://localhost:3001", w.url);
    try std.testing.expectEqualStrings("webhook", w.protocol);
    try std.testing.expect(w.model == null);
    try std.testing.expectEqual(@as(i64, 3), w.max_concurrent);
}

test "Store: insert and list workers" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[]", 1, "config");
    try s.insertWorker("w2", "http://localhost:3002", "tok", "webhook", null, "[]", 2, "registered");
    const workers = try s.listWorkers(allocator);
    defer {
        for (workers) |w| {
            allocator.free(w.id);
            allocator.free(w.url);
            allocator.free(w.token);
            allocator.free(w.protocol);
            if (w.model) |m| allocator.free(m);
            allocator.free(w.tags_json);
            allocator.free(w.source);
            allocator.free(w.status);
        }
        allocator.free(workers);
    }
    try std.testing.expectEqual(@as(usize, 2), workers.len);
}

test "Store: delete worker" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[]", 1, "config");
    try s.deleteWorker("w1");
    const w = try s.getWorker(allocator, "w1");
    try std.testing.expect(w == null);
}

test "Store: update worker status" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[]", 1, "config");
    try s.updateWorkerStatus("w1", "draining", 12345);
    const w = (try s.getWorker(allocator, "w1")).?;
    defer allocator.free(w.id);
    defer allocator.free(w.url);
    defer allocator.free(w.token);
    defer allocator.free(w.protocol);
    if (w.model) |m| allocator.free(m);
    defer allocator.free(w.tags_json);
    defer allocator.free(w.source);
    defer allocator.free(w.status);
    try std.testing.expectEqualStrings("draining", w.status);
    try std.testing.expectEqual(@as(i64, 12345), w.last_health_ms.?);
}

test "Store: delete workers by source" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[]", 1, "config");
    try s.insertWorker("w2", "http://localhost:3002", "tok", "webhook", null, "[]", 1, "config");
    try s.insertWorker("w3", "http://localhost:3003", "tok", "webhook", null, "[]", 1, "registered");
    try s.deleteWorkersBySource("config");
    const workers = try s.listWorkers(allocator);
    defer {
        for (workers) |w| {
            allocator.free(w.id);
            allocator.free(w.url);
            allocator.free(w.token);
            allocator.free(w.protocol);
            if (w.model) |m| allocator.free(m);
            allocator.free(w.tags_json);
            allocator.free(w.source);
            allocator.free(w.status);
        }
        allocator.free(workers);
    }
    try std.testing.expectEqual(@as(usize, 1), workers.len);
    try std.testing.expectEqualStrings("w3", workers[0].id);
}

test "Store: insert and get run" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    const run = (try s.getRun(allocator, "r1")).?;
    defer {
        allocator.free(run.id);
        if (run.idempotency_key) |ik| allocator.free(ik);
        allocator.free(run.status);
        allocator.free(run.workflow_json);
        allocator.free(run.input_json);
        allocator.free(run.callbacks_json);
    }
    try std.testing.expectEqualStrings("r1", run.id);
    try std.testing.expectEqualStrings("running", run.status);
}

test "Store: transaction rollback discards inserted run" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.beginTransaction();
    try s.insertRun("tx_rollback", null, "running", "{}", "{}", "[]");
    try s.rollbackTransaction();

    const run = try s.getRun(allocator, "tx_rollback");
    try std.testing.expect(run == null);
}

test "Store: transaction commit persists inserted run" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.beginTransaction();
    try s.insertRun("tx_commit", null, "running", "{}", "{}", "[]");
    try s.commitTransaction();

    const run = (try s.getRun(allocator, "tx_commit")).?;
    defer {
        allocator.free(run.id);
        if (run.idempotency_key) |ik| allocator.free(ik);
        allocator.free(run.status);
        allocator.free(run.workflow_json);
        allocator.free(run.input_json);
        allocator.free(run.callbacks_json);
    }
    try std.testing.expectEqualStrings("tx_commit", run.id);
}

test "Store: list runs with filter" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertRun("r2", null, "pending", "{}", "{}", "[]");
    try s.insertRun("r3", null, "running", "{}", "{}", "[]");

    const running = try s.listRuns(allocator, "running", 100, 0);
    defer {
        for (running) |r| {
            allocator.free(r.id);
            if (r.idempotency_key) |ik| allocator.free(ik);
            allocator.free(r.status);
            allocator.free(r.workflow_json);
            allocator.free(r.input_json);
            allocator.free(r.callbacks_json);
        }
        allocator.free(running);
    }
    try std.testing.expectEqual(@as(usize, 2), running.len);

    const all = try s.listRuns(allocator, null, 100, 0);
    defer {
        for (all) |r| {
            allocator.free(r.id);
            if (r.idempotency_key) |ik| allocator.free(ik);
            allocator.free(r.status);
            allocator.free(r.workflow_json);
            allocator.free(r.input_json);
            allocator.free(r.callbacks_json);
        }
        allocator.free(all);
    }
    try std.testing.expectEqual(@as(usize, 3), all.len);
}

test "Store: update run status" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.updateRunStatus("r1", "failed", "something broke");
    const run = (try s.getRun(allocator, "r1")).?;
    defer {
        allocator.free(run.id);
        if (run.idempotency_key) |ik| allocator.free(ik);
        allocator.free(run.status);
        allocator.free(run.workflow_json);
        allocator.free(run.input_json);
        allocator.free(run.callbacks_json);
        if (run.error_text) |et| allocator.free(et);
    }
    try std.testing.expectEqualStrings("failed", run.status);
    try std.testing.expectEqualStrings("something broke", run.error_text.?);
}

test "Store: get active runs" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertRun("r2", null, "pending", "{}", "{}", "[]");
    try s.insertRun("r3", null, "paused", "{}", "{}", "[]");
    try s.insertRun("r4", null, "completed", "{}", "{}", "[]");

    const active = try s.getActiveRuns(allocator);
    defer {
        for (active) |r| {
            allocator.free(r.id);
            if (r.idempotency_key) |ik| allocator.free(ik);
            allocator.free(r.status);
            allocator.free(r.workflow_json);
            allocator.free(r.input_json);
            allocator.free(r.callbacks_json);
        }
        allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 2), active.len);
}

test "Store: count steps by status" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("s1", "r1", "step1", "task", "ready", "{}", 1, null, null, null);
    try s.insertStep("s2", "r1", "step2", "task", "ready", "{}", 1, null, null, null);
    try s.insertStep("s3", "r1", "step3", "task", "completed", "{}", 1, null, null, null);

    const ready_count = try s.countStepsByStatus("r1", "ready");
    try std.testing.expectEqual(@as(i64, 2), ready_count);

    const completed_count = try s.countStepsByStatus("r1", "completed");
    try std.testing.expectEqual(@as(i64, 1), completed_count);
}

test "Store: get child steps" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("parent", "r1", "fan_out_1", "fan_out", "running", "{}", 1, null, null, null);
    try s.insertStep("child0", "r1", "task_1", "task", "ready", "{}", 1, null, "parent", 0);
    try s.insertStep("child1", "r1", "task_1", "task", "ready", "{}", 1, null, "parent", 1);

    const children = try s.getChildSteps(allocator, "parent");
    defer {
        for (children) |step| {
            allocator.free(step.id);
            allocator.free(step.run_id);
            allocator.free(step.def_step_id);
            allocator.free(step.type);
            allocator.free(step.status);
            allocator.free(step.input_json);
            if (step.parent_step_id) |pid| allocator.free(pid);
        }
        allocator.free(children);
    }
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("child0", children[0].id);
    try std.testing.expectEqual(@as(i64, 0), children[0].item_index.?);
    try std.testing.expectEqualStrings("child1", children[1].id);
    try std.testing.expectEqual(@as(i64, 1), children[1].item_index.?);
}

test "Store: update step status" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertWorker("w1", "http://localhost:3001", "tok", "webhook", null, "[]", 1, "config");
    try s.insertStep("s1", "r1", "step1", "task", "ready", "{}", 3, null, null, null);
    try s.updateStepStatus("s1", "completed", "w1", "{\"result\":42}", null, 1);

    const step = (try s.getStep(allocator, "s1")).?;
    defer {
        allocator.free(step.id);
        allocator.free(step.run_id);
        allocator.free(step.def_step_id);
        allocator.free(step.type);
        allocator.free(step.status);
        allocator.free(step.input_json);
        if (step.worker_id) |wid| allocator.free(wid);
        if (step.output_json) |oj| allocator.free(oj);
    }
    try std.testing.expectEqualStrings("completed", step.status);
    try std.testing.expectEqualStrings("w1", step.worker_id.?);
    try std.testing.expectEqualStrings("{\"result\":42}", step.output_json.?);
    try std.testing.expectEqual(@as(i64, 1), step.attempt);
}

test "Store: insert and get events" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertEvent("r1", null, "run.started", "{}");
    try s.insertEvent("r1", null, "step.completed", "{\"step\":\"s1\"}");
    const events = try s.getEventsByRun(allocator, "r1");
    defer {
        for (events) |ev| {
            allocator.free(ev.run_id);
            allocator.free(ev.kind);
            allocator.free(ev.data_json);
        }
        allocator.free(events);
    }
    try std.testing.expectEqual(@as(usize, 2), events.len);
}

test "Store: insert and get artifacts" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertArtifact("a1", "r1", null, "log", "file:///tmp/log.txt", "{}");
    try s.insertArtifact("a2", "r1", null, "report", "s3://bucket/report.pdf", "{\"pages\":10}");

    const artifacts = try s.getArtifactsByRun(allocator, "r1");
    defer {
        for (artifacts) |a| {
            allocator.free(a.id);
            allocator.free(a.run_id);
            allocator.free(a.kind);
            allocator.free(a.uri);
            allocator.free(a.meta_json);
        }
        allocator.free(artifacts);
    }
    try std.testing.expectEqual(@as(usize, 2), artifacts.len);
    try std.testing.expectEqualStrings("a1", artifacts[0].id);
    try std.testing.expectEqualStrings("log", artifacts[0].kind);
    try std.testing.expectEqualStrings("a2", artifacts[1].id);
    try std.testing.expectEqualStrings("s3://bucket/report.pdf", artifacts[1].uri);
}

test "Store: get nonexistent worker returns null" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    const w = try s.getWorker(allocator, "nonexistent");
    try std.testing.expect(w == null);
}

test "Store: get nonexistent run returns null" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    const r = try s.getRun(allocator, "nonexistent");
    try std.testing.expect(r == null);
}

test "Store: get nonexistent step returns null" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();
    const step = try s.getStep(allocator, "nonexistent");
    try std.testing.expect(step == null);
}

test "updateStepChildRunId: sets child_run_id on step" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create a run and step
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertRun("child_r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("s1", "r1", "sub_wf", "sub_workflow", "running", "{}", 1, null, null, null);

    // Update child_run_id
    try s.updateStepChildRunId("s1", "child_r1");

    // Get step and verify child_run_id is set
    const step = (try s.getStep(allocator, "s1")).?;
    defer {
        allocator.free(step.id);
        allocator.free(step.run_id);
        allocator.free(step.def_step_id);
        allocator.free(step.type);
        allocator.free(step.status);
        allocator.free(step.input_json);
        if (step.child_run_id) |crid| allocator.free(crid);
    }
    try std.testing.expectEqualStrings("child_r1", step.child_run_id.?);
}

test "workflow CRUD" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create
    try s.createWorkflow("wf1", "My Workflow", "{\"steps\":[]}");

    // Get
    const wf = (try s.getWorkflow(allocator, "wf1")).?;
    defer {
        allocator.free(wf.id);
        allocator.free(wf.name);
        allocator.free(wf.definition_json);
    }
    try std.testing.expectEqualStrings("wf1", wf.id);
    try std.testing.expectEqualStrings("My Workflow", wf.name);
    try std.testing.expectEqualStrings("{\"steps\":[]}", wf.definition_json);
    try std.testing.expect(wf.created_at_ms > 0);
    try std.testing.expect(wf.updated_at_ms > 0);

    // Update
    try s.updateWorkflow("wf1", "Updated Workflow", "{\"steps\":[{\"id\":\"s1\"}]}");
    const wf2 = (try s.getWorkflow(allocator, "wf1")).?;
    defer {
        allocator.free(wf2.id);
        allocator.free(wf2.name);
        allocator.free(wf2.definition_json);
    }
    try std.testing.expectEqualStrings("Updated Workflow", wf2.name);
    try std.testing.expectEqualStrings("{\"steps\":[{\"id\":\"s1\"}]}", wf2.definition_json);

    // List
    try s.createWorkflow("wf2", "Second Workflow", "{}");
    const workflows = try s.listWorkflows(allocator);
    defer {
        for (workflows) |w| {
            allocator.free(w.id);
            allocator.free(w.name);
            allocator.free(w.definition_json);
        }
        allocator.free(workflows);
    }
    try std.testing.expectEqual(@as(usize, 2), workflows.len);

    // Delete
    try s.deleteWorkflow("wf1");
    const deleted = try s.getWorkflow(allocator, "wf1");
    try std.testing.expect(deleted == null);

    // Remaining list
    const remaining = try s.listWorkflows(allocator);
    defer {
        for (remaining) |w| {
            allocator.free(w.id);
            allocator.free(w.name);
            allocator.free(w.definition_json);
        }
        allocator.free(remaining);
    }
    try std.testing.expectEqual(@as(usize, 1), remaining.len);
    try std.testing.expectEqualStrings("wf2", remaining[0].id);
}

test "checkpoint lifecycle" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create a run
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");

    // Create checkpoints with parent chain
    try s.createCheckpoint("cp1", "r1", "step_a", null, "{\"x\":1}", "[\"step_a\"]", 1, null);
    try s.createCheckpoint("cp2", "r1", "step_b", "cp1", "{\"x\":2}", "[\"step_a\",\"step_b\"]", 2, "{\"note\":\"test\"}");
    try s.createCheckpoint("cp3", "r1", "step_c", "cp2", "{\"x\":3}", "[\"step_a\",\"step_b\",\"step_c\"]", 3, null);

    // Get single checkpoint
    const cp1 = (try s.getCheckpoint(allocator, "cp1")).?;
    defer {
        allocator.free(cp1.id);
        allocator.free(cp1.run_id);
        allocator.free(cp1.step_id);
        if (cp1.parent_id) |pid| allocator.free(pid);
        allocator.free(cp1.state_json);
        allocator.free(cp1.completed_nodes_json);
        if (cp1.metadata_json) |mj| allocator.free(mj);
    }
    try std.testing.expectEqualStrings("cp1", cp1.id);
    try std.testing.expectEqualStrings("r1", cp1.run_id);
    try std.testing.expectEqualStrings("step_a", cp1.step_id);
    try std.testing.expect(cp1.parent_id == null);
    try std.testing.expectEqualStrings("{\"x\":1}", cp1.state_json);
    try std.testing.expectEqual(@as(i64, 1), cp1.version);
    try std.testing.expect(cp1.metadata_json == null);

    // Get checkpoint with parent and metadata
    const cp2 = (try s.getCheckpoint(allocator, "cp2")).?;
    defer {
        allocator.free(cp2.id);
        allocator.free(cp2.run_id);
        allocator.free(cp2.step_id);
        if (cp2.parent_id) |pid| allocator.free(pid);
        allocator.free(cp2.state_json);
        allocator.free(cp2.completed_nodes_json);
        if (cp2.metadata_json) |mj| allocator.free(mj);
    }
    try std.testing.expectEqualStrings("cp1", cp2.parent_id.?);
    try std.testing.expectEqualStrings("{\"note\":\"test\"}", cp2.metadata_json.?);

    // List checkpoints (ordered by version ASC)
    const cps = try s.listCheckpoints(allocator, "r1");
    defer {
        for (cps) |cp| {
            allocator.free(cp.id);
            allocator.free(cp.run_id);
            allocator.free(cp.step_id);
            if (cp.parent_id) |pid| allocator.free(pid);
            allocator.free(cp.state_json);
            allocator.free(cp.completed_nodes_json);
            if (cp.metadata_json) |mj| allocator.free(mj);
        }
        allocator.free(cps);
    }
    try std.testing.expectEqual(@as(usize, 3), cps.len);
    try std.testing.expectEqualStrings("cp1", cps[0].id);
    try std.testing.expectEqualStrings("cp3", cps[2].id);

    // Get latest checkpoint
    const latest = (try s.getLatestCheckpoint(allocator, "r1")).?;
    defer {
        allocator.free(latest.id);
        allocator.free(latest.run_id);
        allocator.free(latest.step_id);
        if (latest.parent_id) |pid| allocator.free(pid);
        allocator.free(latest.state_json);
        allocator.free(latest.completed_nodes_json);
        if (latest.metadata_json) |mj| allocator.free(mj);
    }
    try std.testing.expectEqualStrings("cp3", latest.id);
    try std.testing.expectEqual(@as(i64, 3), latest.version);

    // Get nonexistent checkpoint
    const none = try s.getCheckpoint(allocator, "nonexistent");
    try std.testing.expect(none == null);

    // Get latest for run with no checkpoints
    const no_latest = try s.getLatestCheckpoint(allocator, "no_run");
    try std.testing.expect(no_latest == null);
}

test "agent events" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create a run
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");

    // Create agent events
    try s.createAgentEvent("r1", "step_a", 1, "read_file", "{\"path\":\"foo.txt\"}", "contents here", "completed");
    try s.createAgentEvent("r1", "step_a", 2, "write_file", "{\"path\":\"bar.txt\"}", null, "completed");
    try s.createAgentEvent("r1", "step_a", 3, null, null, null, "thinking");
    try s.createAgentEvent("r1", "step_b", 1, "search", "{}", "results", "completed");

    // List by run+step
    const events_a = try s.listAgentEvents(allocator, "r1", "step_a");
    defer {
        for (events_a) |ev| {
            allocator.free(ev.run_id);
            allocator.free(ev.step_id);
            if (ev.tool) |t| allocator.free(t);
            if (ev.args_json) |a| allocator.free(a);
            if (ev.result_text) |r| allocator.free(r);
            allocator.free(ev.status);
        }
        allocator.free(events_a);
    }
    try std.testing.expectEqual(@as(usize, 3), events_a.len);
    try std.testing.expectEqualStrings("read_file", events_a[0].tool.?);
    try std.testing.expectEqual(@as(i64, 1), events_a[0].iteration);
    try std.testing.expectEqualStrings("contents here", events_a[0].result_text.?);
    try std.testing.expect(events_a[2].tool == null);
    try std.testing.expectEqualStrings("thinking", events_a[2].status);

    // List different step
    const events_b = try s.listAgentEvents(allocator, "r1", "step_b");
    defer {
        for (events_b) |ev| {
            allocator.free(ev.run_id);
            allocator.free(ev.step_id);
            if (ev.tool) |t| allocator.free(t);
            if (ev.args_json) |a| allocator.free(a);
            if (ev.result_text) |r| allocator.free(r);
            allocator.free(ev.status);
        }
        allocator.free(events_b);
    }
    try std.testing.expectEqual(@as(usize, 1), events_b.len);
    try std.testing.expectEqualStrings("search", events_b[0].tool.?);

    // Empty list for nonexistent
    const empty = try s.listAgentEvents(allocator, "r1", "nonexistent");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "pending state injections" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create a run
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");

    // Create pending injections
    try s.createPendingInjection("r1", "{\"counter\":5}", "step_a");
    try s.createPendingInjection("r1", "{\"flag\":true}", "step_b");
    try s.createPendingInjection("r1", "{\"immediate\":1}", null); // apply immediately (NULL apply_after_step)

    // Consume by step_a -- should get the step_a injection and the NULL one
    const consumed_a = try s.consumePendingInjections(allocator, "r1", "step_a");
    defer {
        for (consumed_a) |inj| {
            allocator.free(inj.run_id);
            allocator.free(inj.updates_json);
            if (inj.apply_after_step) |s_a| allocator.free(s_a);
        }
        allocator.free(consumed_a);
    }
    try std.testing.expectEqual(@as(usize, 2), consumed_a.len);
    try std.testing.expectEqualStrings("{\"counter\":5}", consumed_a[0].updates_json);
    try std.testing.expectEqualStrings("{\"immediate\":1}", consumed_a[1].updates_json);

    // Consuming again for step_a should return empty (already consumed)
    const consumed_again = try s.consumePendingInjections(allocator, "r1", "step_a");
    defer allocator.free(consumed_again);
    try std.testing.expectEqual(@as(usize, 0), consumed_again.len);

    // step_b injection should still be pending
    const consumed_b = try s.consumePendingInjections(allocator, "r1", "step_b");
    defer {
        for (consumed_b) |inj| {
            allocator.free(inj.run_id);
            allocator.free(inj.updates_json);
            if (inj.apply_after_step) |s_a| allocator.free(s_a);
        }
        allocator.free(consumed_b);
    }
    try std.testing.expectEqual(@as(usize, 1), consumed_b.len);
    try std.testing.expectEqualStrings("{\"flag\":true}", consumed_b[0].updates_json);

    // Test discard
    try s.createPendingInjection("r1", "{\"discard_me\":true}", "step_c");
    try s.discardPendingInjections("r1");
    const after_discard = try s.consumePendingInjections(allocator, "r1", "step_c");
    defer allocator.free(after_discard);
    try std.testing.expectEqual(@as(usize, 0), after_discard.len);
}

test "run state management" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create run with state
    try s.createRunWithState("r1", null, "{\"steps\":[]}", "{\"input\":1}", "{\"counter\":0}");
    const run = (try s.getRun(allocator, "r1")).?;
    defer {
        allocator.free(run.id);
        if (run.idempotency_key) |ik| allocator.free(ik);
        allocator.free(run.status);
        allocator.free(run.workflow_json);
        allocator.free(run.input_json);
        allocator.free(run.callbacks_json);
        if (run.error_text) |et| allocator.free(et);
        if (run.state_json) |sj| allocator.free(sj);
    }
    try std.testing.expectEqualStrings("r1", run.id);
    try std.testing.expectEqualStrings("pending", run.status);
    try std.testing.expectEqualStrings("{\"steps\":[]}", run.workflow_json);

    // Create run with workflow_id
    try s.createWorkflow("wf1", "Test WF", "{\"steps\":[]}");
    try s.createRunWithState("r2", "wf1", "{\"steps\":[]}", "{}", "{}");
    const run2 = (try s.getRun(allocator, "r2")).?;
    defer {
        allocator.free(run2.id);
        if (run2.idempotency_key) |ik| allocator.free(ik);
        allocator.free(run2.status);
        allocator.free(run2.workflow_json);
        allocator.free(run2.input_json);
        allocator.free(run2.callbacks_json);
        if (run2.error_text) |et| allocator.free(et);
        if (run2.state_json) |sj| allocator.free(sj);
    }
    try std.testing.expectEqualStrings("r2", run2.id);

    // Update run state
    try s.updateRunState("r1", "{\"counter\":42}");

    // Increment checkpoint count
    try s.incrementCheckpointCount("r1");
    try s.incrementCheckpointCount("r1");

    // Create forked run
    try s.createCheckpoint("cp1", "r1", "step_a", null, "{}", "[]", 1, null);
    try s.createForkedRun("r3", "{\"steps\":[]}", "{\"counter\":42}", "r1", "cp1");
    const forked = (try s.getRun(allocator, "r3")).?;
    defer {
        allocator.free(forked.id);
        if (forked.idempotency_key) |ik| allocator.free(ik);
        allocator.free(forked.status);
        allocator.free(forked.workflow_json);
        allocator.free(forked.input_json);
        allocator.free(forked.callbacks_json);
        if (forked.error_text) |et| allocator.free(et);
        if (forked.state_json) |sj| allocator.free(sj);
    }
    try std.testing.expectEqualStrings("r3", forked.id);
    try std.testing.expectEqualStrings("pending", forked.status);
}

test "token accounting: update step and run tokens" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.createRunWithState("r-tok", null, "{}", "{}", "{}");
    try s.updateRunStatus("r-tok", "running", null);
    try s.insertStep("s-tok", "r-tok", "task1", "task", "completed", "{}", 1, null, null, null);

    // Update step tokens
    try s.updateStepTokens("s-tok", 100, 200);

    // Update run tokens
    try s.updateRunTokens("r-tok", 100, 200);

    // Verify run tokens
    const tokens = try s.getRunTokens("r-tok");
    try std.testing.expectEqual(@as(i64, 100), tokens.input);
    try std.testing.expectEqual(@as(i64, 200), tokens.output);
    try std.testing.expectEqual(@as(i64, 300), tokens.total);

    // Accumulate more tokens
    try s.updateRunTokens("r-tok", 50, 75);
    const tokens2 = try s.getRunTokens("r-tok");
    try std.testing.expectEqual(@as(i64, 150), tokens2.input);
    try std.testing.expectEqual(@as(i64, 275), tokens2.output);
    try std.testing.expectEqual(@as(i64, 425), tokens2.total);
}

test "workflow version CRUD" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Create workflow with default version (1)
    try s.createWorkflow("wf1", "Test Workflow", "{\"nodes\":{}}");
    const wf1 = (try s.getWorkflow(allocator, "wf1")).?;
    defer {
        allocator.free(wf1.id);
        allocator.free(wf1.name);
        allocator.free(wf1.definition_json);
    }
    try std.testing.expectEqual(@as(i64, 1), wf1.version);

    // Create workflow with explicit version
    try s.createWorkflowWithVersion("wf2", "Versioned Workflow", "{\"nodes\":{}}", 5);
    const wf2 = (try s.getWorkflow(allocator, "wf2")).?;
    defer {
        allocator.free(wf2.id);
        allocator.free(wf2.name);
        allocator.free(wf2.definition_json);
    }
    try std.testing.expectEqual(@as(i64, 5), wf2.version);

    // Update workflow with new version
    try s.updateWorkflowWithVersion("wf2", "Updated", "{\"nodes\":{\"a\":{}}}", 6);
    const wf3 = (try s.getWorkflow(allocator, "wf2")).?;
    defer {
        allocator.free(wf3.id);
        allocator.free(wf3.name);
        allocator.free(wf3.definition_json);
    }
    try std.testing.expectEqual(@as(i64, 6), wf3.version);
    try std.testing.expectEqualStrings("Updated", wf3.name);

    // Update without changing version
    try s.updateWorkflow("wf1", "Still v1", "{\"nodes\":{\"b\":{}}}");
    const wf4 = (try s.getWorkflow(allocator, "wf1")).?;
    defer {
        allocator.free(wf4.id);
        allocator.free(wf4.name);
        allocator.free(wf4.definition_json);
    }
    try std.testing.expectEqual(@as(i64, 1), wf4.version);

    // List workflows should include version
    const workflows = try s.listWorkflows(allocator);
    defer {
        for (workflows) |w| {
            allocator.free(w.id);
            allocator.free(w.name);
            allocator.free(w.definition_json);
        }
        allocator.free(workflows);
    }
    try std.testing.expectEqual(@as(usize, 2), workflows.len);
}
