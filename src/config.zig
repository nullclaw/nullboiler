const std = @import("std");

pub const WorkerConfig = struct {
    id: []const u8,
    url: []const u8,
    token: []const u8,
    protocol: []const u8 = "webhook",
    model: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    max_concurrent: u32 = 1,
};

pub const EngineConfig = struct {
    poll_interval_ms: u32 = 500,
    default_timeout_ms: u32 = 300000,
    default_max_attempts: u32 = 1,
    health_check_interval_ms: u32 = 30000,
    worker_failure_threshold: u32 = 3,
    worker_circuit_breaker_ms: u32 = 60000,
    retry_base_delay_ms: u32 = 1000,
    retry_max_delay_ms: u32 = 30000,
    retry_jitter_ms: u32 = 250,
    retry_max_elapsed_ms: u32 = 900000,
    shutdown_grace_ms: u32 = 30000,
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    db: []const u8 = "nullboiler.db",
    api_token: ?[]const u8 = null,
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

    // Do NOT free `contents` or deinit `parsed` here.
    // `Config` fields may point into these allocations.
    // The caller should provide an arena allocator and clean it up once on shutdown.
    const parsed = try std.json.parseFromSlice(Config, allocator, contents, .{});

    return parsed.value;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "default config" {
    const cfg = Config{};
    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("nullboiler.db", cfg.db);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.api_token);
    try std.testing.expectEqual(@as(usize, 0), cfg.workers.len);
}

test "loadFromFile returns default when file not found" {
    const allocator = std.testing.allocator;
    const cfg = try loadFromFile(allocator, "nonexistent_config_file_12345.json");
    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 8080), cfg.port);
    try std.testing.expectEqualStrings("nullboiler.db", cfg.db);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.api_token);
}

test "loadFromFile reads configured host and worker URL from JSON file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg_json =
        \\{
        \\  "host": "127.0.0.1",
        \\  "port": 8099,
        \\  "db": "cfg.db",
        \\  "workers": [
        \\    {
        \\      "id": "w1",
        \\      "url": "http://localhost:3000/webhook",
        \\      "token": "tok",
        \\      "protocol": "webhook",
        \\      "tags": ["coder"],
        \\      "max_concurrent": 1
        \\    }
        \\  ]
        \\}
    ;

    try tmp.dir.writeFile(.{
        .sub_path = "config.json",
        .data = cfg_json,
    });

    const cfg_path = try tmp.dir.realpathAlloc(std.testing.allocator, "config.json");
    defer std.testing.allocator.free(cfg_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try loadFromFile(arena.allocator(), cfg_path);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 8099), cfg.port);
    try std.testing.expectEqualStrings("cfg.db", cfg.db);
    try std.testing.expectEqual(@as(usize, 1), cfg.workers.len);
    try std.testing.expectEqualStrings("http://localhost:3000/webhook", cfg.workers[0].url);
}
