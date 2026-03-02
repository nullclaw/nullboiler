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
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms FROM runs WHERE id = ?";
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
        };
    }

    pub fn getRunByIdempotencyKey(self: *Self, allocator: std.mem.Allocator, key: []const u8) !?types.RunRow {
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms FROM runs WHERE idempotency_key = ? ORDER BY created_at_ms DESC LIMIT 1";
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
        };
    }

    pub fn listRuns(self: *Self, allocator: std.mem.Allocator, status_filter: ?[]const u8, limit: i64, offset: i64) ![]types.RunRow {
        var stmt: ?*c.sqlite3_stmt = null;
        if (status_filter != null) {
            const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms FROM runs WHERE status = ? ORDER BY created_at_ms DESC LIMIT ? OFFSET ?";
            if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
                return error.SqlitePrepareFailed;
            }
            _ = c.sqlite3_bind_text(stmt, 1, status_filter.?.ptr, @intCast(status_filter.?.len), SQLITE_STATIC);
            _ = c.sqlite3_bind_int64(stmt, 2, limit);
            _ = c.sqlite3_bind_int64(stmt, 3, offset);
        } else {
            const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms FROM runs ORDER BY created_at_ms DESC LIMIT ? OFFSET ?";
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
        const sql = "SELECT id, idempotency_key, status, workflow_json, input_json, callbacks_json, error_text, created_at_ms, updated_at_ms, started_at_ms, ended_at_ms FROM runs WHERE status IN ('running', 'paused') ORDER BY created_at_ms DESC";
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

    pub fn getReadySteps(self: *Self, allocator: std.mem.Allocator, run_id: []const u8) ![]types.StepRow {
        const sql =
            "SELECT s.id, s.run_id, s.def_step_id, s.type, s.status, s.worker_id, s.input_json, s.output_json, s.error_text, s.attempt, s.max_attempts, s.timeout_ms, s.next_attempt_at_ms, s.parent_step_id, s.item_index, s.created_at_ms, s.updated_at_ms, s.started_at_ms, s.ended_at_ms, s.child_run_id, s.iteration_index " ++
            "FROM steps s WHERE s.run_id = ? AND s.status = 'ready' " ++
            "AND NOT EXISTS (" ++
            "SELECT 1 FROM step_deps d JOIN steps dep ON dep.id = d.depends_on " ++
            "WHERE d.step_id = s.id AND dep.status NOT IN ('completed', 'skipped'))";
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

    /// Get the IDs of steps that a given step depends on.
    pub fn getStepDeps(self: *Self, allocator: std.mem.Allocator, step_id: []const u8) ![][]const u8 {
        const sql = "SELECT depends_on FROM step_deps WHERE step_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged([]const u8) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, try allocStr(allocator, stmt, 0));
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

    /// Set started_at_ms for a step (used by wait steps to track timer start).
    pub fn setStepStartedAt(self: *Self, step_id: []const u8, ts_ms: i64) !void {
        const sql = "UPDATE steps SET started_at_ms = ?, updated_at_ms = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int64(stmt, 1, ts_ms);
        _ = c.sqlite3_bind_int64(stmt, 2, ids.nowMs());
        _ = c.sqlite3_bind_text(stmt, 3, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
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

    // ── Cycle State CRUD ─────────────────────────────────────────────

    pub fn getCycleState(self: *Self, run_id: []const u8, cycle_key: []const u8) !?struct { iteration_count: i64, max_iterations: i64 } {
        const sql = "SELECT iteration_count, max_iterations FROM cycle_state WHERE run_id = ? AND cycle_key = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, cycle_key.ptr, @intCast(cycle_key.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;

        return .{
            .iteration_count = colInt(stmt, 0),
            .max_iterations = colInt(stmt, 1),
        };
    }

    pub fn upsertCycleState(self: *Self, run_id: []const u8, cycle_key: []const u8, iteration_count: i64, max_iterations: i64) !void {
        const sql = "INSERT OR REPLACE INTO cycle_state (run_id, cycle_key, iteration_count, max_iterations) VALUES (?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, cycle_key.ptr, @intCast(cycle_key.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 3, iteration_count);
        _ = c.sqlite3_bind_int64(stmt, 4, max_iterations);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    // ── Chat Message CRUD ────────────────────────────────────────────

    pub fn insertChatMessage(self: *Self, run_id: []const u8, step_id: []const u8, round: i64, role: []const u8, worker_id: ?[]const u8, message: []const u8) !void {
        const sql = "INSERT INTO chat_messages (run_id, step_id, round, role, worker_id, message, ts_ms) VALUES (?, ?, ?, ?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 3, round);
        _ = c.sqlite3_bind_text(stmt, 4, role.ptr, @intCast(role.len), SQLITE_STATIC);
        bindTextOpt(stmt, 5, worker_id);
        _ = c.sqlite3_bind_text(stmt, 6, message.ptr, @intCast(message.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_int64(stmt, 7, ids.nowMs());

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getChatMessages(self: *Self, allocator: std.mem.Allocator, step_id: []const u8) ![]types.ChatMessageRow {
        const sql = "SELECT id, run_id, step_id, round, role, worker_id, message, ts_ms FROM chat_messages WHERE step_id = ? ORDER BY round, id";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, step_id.ptr, @intCast(step_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.ChatMessageRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .id = colInt(stmt, 0),
                .run_id = try allocStr(allocator, stmt, 1),
                .step_id = try allocStr(allocator, stmt, 2),
                .round = colInt(stmt, 3),
                .role = try allocStr(allocator, stmt, 4),
                .worker_id = try allocStrOpt(allocator, stmt, 5),
                .message = try allocStr(allocator, stmt, 6),
                .ts_ms = colInt(stmt, 7),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ── Saga State CRUD ──────────────────────────────────────────────

    pub fn insertSagaState(self: *Self, run_id: []const u8, saga_step_id: []const u8, body_step_id: []const u8, compensation_step_id: ?[]const u8) !void {
        const sql = "INSERT INTO saga_state (run_id, saga_step_id, body_step_id, compensation_step_id, status) VALUES (?, ?, ?, ?, 'pending')";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, saga_step_id.ptr, @intCast(saga_step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, body_step_id.ptr, @intCast(body_step_id.len), SQLITE_STATIC);
        bindTextOpt(stmt, 4, compensation_step_id);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn updateSagaState(self: *Self, run_id: []const u8, saga_step_id: []const u8, body_step_id: []const u8, status: []const u8) !void {
        const sql = "UPDATE saga_state SET status = ? WHERE run_id = ? AND saga_step_id = ? AND body_step_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, status.ptr, @intCast(status.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 3, saga_step_id.ptr, @intCast(saga_step_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 4, body_step_id.ptr, @intCast(body_step_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) {
            return error.SqliteStepFailed;
        }
    }

    pub fn getSagaStates(self: *Self, allocator: std.mem.Allocator, run_id: []const u8, saga_step_id: []const u8) ![]types.SagaStateRow {
        const sql = "SELECT run_id, saga_step_id, body_step_id, compensation_step_id, status FROM saga_state WHERE run_id = ? AND saga_step_id = ? ORDER BY rowid";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, run_id.ptr, @intCast(run_id.len), SQLITE_STATIC);
        _ = c.sqlite3_bind_text(stmt, 2, saga_step_id.ptr, @intCast(saga_step_id.len), SQLITE_STATIC);

        var list: std.ArrayListUnmanaged(types.SagaStateRow) = .empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try list.append(allocator, .{
                .run_id = try allocStr(allocator, stmt, 0),
                .saga_step_id = try allocStr(allocator, stmt, 1),
                .body_step_id = try allocStr(allocator, stmt, 2),
                .compensation_step_id = try allocStrOpt(allocator, stmt, 3),
                .status = try allocStr(allocator, stmt, 4),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    // ── Sub-workflow Helper ──────────────────────────────────────────

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

test "Store: step deps and ready steps" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("s1", "r1", "step1", "task", "ready", "{}", 1, null, null, null);
    try s.insertStep("s2", "r1", "step2", "task", "ready", "{}", 1, null, null, null);
    try s.insertStepDep("s2", "s1");

    // s1 should be ready (no unsatisfied deps), s2 should NOT (depends on s1 which is 'ready' not 'completed')
    const ready = try s.getReadySteps(allocator, "r1");
    defer {
        for (ready) |step| {
            allocator.free(step.id);
            allocator.free(step.run_id);
            allocator.free(step.def_step_id);
            allocator.free(step.type);
            allocator.free(step.status);
            allocator.free(step.input_json);
        }
        allocator.free(ready);
    }
    try std.testing.expectEqual(@as(usize, 1), ready.len);
    try std.testing.expectEqualStrings("s1", ready[0].id);
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

test "cycle state: upsert and get" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    // Insert a run first (cycle_state references runs(id))
    try s.insertRun("r1", null, "running", "{}", "{}", "[]");

    // Upsert cycle state
    try s.upsertCycleState("r1", "loop_A", 1, 10);

    // Get and verify values
    const cs = (try s.getCycleState("r1", "loop_A")).?;
    try std.testing.expectEqual(@as(i64, 1), cs.iteration_count);
    try std.testing.expectEqual(@as(i64, 10), cs.max_iterations);

    // Upsert again with new iteration_count
    try s.upsertCycleState("r1", "loop_A", 5, 10);

    // Verify updated value
    const cs2 = (try s.getCycleState("r1", "loop_A")).?;
    try std.testing.expectEqual(@as(i64, 5), cs2.iteration_count);
    try std.testing.expectEqual(@as(i64, 10), cs2.max_iterations);
}

test "cycle state: get returns null for nonexistent" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    const cs = try s.getCycleState("no_run", "no_key");
    try std.testing.expect(cs == null);
}

test "chat messages: insert and get ordered by round" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("s1", "r1", "chat_step", "group_chat", "running", "{}", 1, null, null, null);

    // Insert messages with different rounds (out of order)
    try s.insertChatMessage("r1", "s1", 2, "assistant", "w1", "round 2 message");
    try s.insertChatMessage("r1", "s1", 1, "user", null, "round 1 message");
    try s.insertChatMessage("r1", "s1", 1, "assistant", "w1", "round 1 reply");

    // Verify getChatMessages returns them ordered by round, id
    const msgs = try s.getChatMessages(allocator, "s1");
    defer {
        for (msgs) |m| {
            allocator.free(m.run_id);
            allocator.free(m.step_id);
            allocator.free(m.role);
            if (m.worker_id) |wid| allocator.free(wid);
            allocator.free(m.message);
        }
        allocator.free(msgs);
    }
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    // First two should be round 1 (ordered by id within round)
    try std.testing.expectEqual(@as(i64, 1), msgs[0].round);
    try std.testing.expectEqual(@as(i64, 1), msgs[1].round);
    try std.testing.expectEqual(@as(i64, 2), msgs[2].round);
    try std.testing.expectEqualStrings("round 1 message", msgs[0].message);
    try std.testing.expectEqualStrings("round 1 reply", msgs[1].message);
    try std.testing.expectEqualStrings("round 2 message", msgs[2].message);
}

test "saga state: insert, update status, and get" {
    const allocator = std.testing.allocator;
    var s = try Store.init(allocator, ":memory:");
    defer s.deinit();

    try s.insertRun("r1", null, "running", "{}", "{}", "[]");
    try s.insertStep("saga1", "r1", "saga_def", "saga", "running", "{}", 1, null, null, null);
    try s.insertStep("body1", "r1", "body_def1", "task", "pending", "{}", 1, null, "saga1", null);
    try s.insertStep("body2", "r1", "body_def2", "task", "pending", "{}", 1, null, "saga1", null);
    try s.insertStep("comp1", "r1", "comp_def1", "task", "pending", "{}", 1, null, "saga1", null);

    // Insert saga states for body steps
    try s.insertSagaState("r1", "saga1", "body1", "comp1");
    try s.insertSagaState("r1", "saga1", "body2", null);

    // Update one to 'completed'
    try s.updateSagaState("r1", "saga1", "body1", "completed");

    // Verify getSagaStates returns correct statuses
    const states = try s.getSagaStates(allocator, "r1", "saga1");
    defer {
        for (states) |st| {
            allocator.free(st.run_id);
            allocator.free(st.saga_step_id);
            allocator.free(st.body_step_id);
            if (st.compensation_step_id) |cid| allocator.free(cid);
            allocator.free(st.status);
        }
        allocator.free(states);
    }
    try std.testing.expectEqual(@as(usize, 2), states.len);
    try std.testing.expectEqualStrings("body1", states[0].body_step_id);
    try std.testing.expectEqualStrings("completed", states[0].status);
    try std.testing.expectEqualStrings("comp1", states[0].compensation_step_id.?);
    try std.testing.expectEqualStrings("body2", states[1].body_step_id);
    try std.testing.expectEqualStrings("pending", states[1].status);
    try std.testing.expect(states[1].compensation_step_id == null);
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
