const std = @import("std");
const log = std.log.scoped(.store);
const ids = @import("ids.zig");
const types = @import("types.zig");

pub const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SQLITE_STATIC: c.sqlite3_destructor_type = null;

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
        const sql = @embedFile("migrations/001_init.sql");
        var err_msg: [*c]u8 = null;
        const prc = c.sqlite3_exec(self.db, sql.ptr, null, null, &err_msg);
        if (prc != c.SQLITE_OK) {
            if (err_msg) |msg| {
                log.err("migration failed (rc={d}): {s}", .{ prc, std.mem.span(msg) });
                c.sqlite3_free(msg);
            }
            return error.MigrationFailed;
        }
    }
};
