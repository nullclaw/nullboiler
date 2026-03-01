const std = @import("std");

pub const WorkerConfig = struct {
    id: []const u8,
    url: []const u8,
    token: []const u8,
    tags: []const []const u8 = &.{},
    max_concurrent: u32 = 1,
};

pub const EngineConfig = struct {
    poll_interval_ms: u32 = 500,
    default_timeout_ms: u32 = 300000,
    default_max_attempts: u32 = 1,
    health_check_interval_ms: u32 = 30000,
};

pub const Config = struct {
    port: u16 = 8080,
    db: []const u8 = "nullboiler.db",
    workers: []const WorkerConfig = &.{},
    engine: EngineConfig = .{},
};

/// Load configuration from a JSON file. If the file does not exist,
/// return a default Config.
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return Config{};
        }
        return err;
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(contents);

    // Do NOT deinit parsed — Config contains slices that point into parsed
    // memory. The caller's arena allocator will clean up everything.
    const parsed = try std.json.parseFromSlice(Config, allocator, contents, .{
        .ignore_unknown_fields = true,
    });

    return parsed.value;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "default config" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("nullboiler.db", cfg.db);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers.len);
}

test "loadFromFile returns default when file not found" {
    const allocator = std.testing.allocator;
    const cfg = try loadFromFile(allocator, "nonexistent_config_file_12345.json");
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("nullboiler.db", cfg.db);
}
