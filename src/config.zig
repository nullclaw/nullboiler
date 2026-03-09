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

pub const ConcurrencyConfig = struct {
    max_concurrent_tasks: u32 = 10,
    per_pipeline: ?std.json.Value = null,
    per_role: ?std.json.Value = null,
};

pub const WorkspaceHooksConfig = struct {
    after_create: ?[]const u8 = null,
    before_run: ?[]const u8 = null,
    after_run: ?[]const u8 = null,
    before_remove: ?[]const u8 = null,
};

pub const WorkspaceConfig = struct {
    root: []const u8 = "/tmp/nullboiler-workspaces",
    hooks: WorkspaceHooksConfig = .{},
    hook_timeout_ms: u32 = 30000,
};

pub const SubprocessDefaults = struct {
    command: []const u8 = "nullclaw",
    args: []const []const u8 = &.{},
    base_port: u16 = 9200,
    health_check_retries: u32 = 10,
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
    continuation_prompt: []const u8 = "Continue working on this task. Your previous context is preserved.",
};

pub const TrackerConfig = struct {
    url: ?[]const u8 = null,
    api_token: ?[]const u8 = null,
    poll_interval_ms: u32 = 10000,
    agent_id: []const u8 = "nullboiler",
    agent_role: []const u8 = "coder",
    workflow_path: ?[]const u8 = null,
    success_trigger: ?[]const u8 = null,
    artifact_kind: []const u8 = "nullboiler_run",
    max_concurrent_tasks: ?u32 = null,
    concurrency: ConcurrencyConfig = .{},
    workspace: WorkspaceConfig = .{},
    subprocess: SubprocessDefaults = .{},
    stall_timeout_ms: u32 = 300000,
    lease_ttl_ms: u32 = 60000,
    heartbeat_interval_ms: u32 = 30000,
    workflows_dir: []const u8 = "workflows",
};

pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    db: []const u8 = "nullboiler.db",
    api_token: ?[]const u8 = null,
    strategies_dir: []const u8 = "strategies",
    workers: []const WorkerConfig = &.{},
    engine: EngineConfig = .{},
    tracker: ?TrackerConfig = null,
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
    const parsed = try std.json.parseFromSlice(Config, allocator, contents, .{ .ignore_unknown_fields = true });

    return parsed.value;
}

pub fn resolveRelativePaths(allocator: std.mem.Allocator, config_path: []const u8, cfg: *Config) !void {
    cfg.db = try resolveRelativePath(allocator, config_path, cfg.db);
    cfg.strategies_dir = try resolveRelativePath(allocator, config_path, cfg.strategies_dir);

    if (cfg.tracker) |*tracker| {
        if (tracker.max_concurrent_tasks) |limit| {
            tracker.concurrency.max_concurrent_tasks = limit;
        }
        tracker.workflows_dir = try resolveRelativePath(allocator, config_path, tracker.workflows_dir);
        tracker.workspace.root = try resolveRelativePath(allocator, config_path, tracker.workspace.root);
        if (tracker.workflow_path) |path| {
            tracker.workflow_path = try resolveRelativePath(allocator, config_path, path);
        }
    }
}

fn resolveRelativePath(allocator: std.mem.Allocator, config_path: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return value;

    const base_dir = std.fs.path.dirname(config_path) orelse ".";
    return std.fs.path.resolve(allocator, &.{ base_dir, value });
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
        \\  "tracker": {
        \\    "url": "http://127.0.0.1:7700",
        \\    "agent_id": "boiler-1",
        \\    "agent_role": "reviewer",
        \\    "workflow_path": "tracker-workflow.json",
        \\    "max_concurrent_tasks": 3
        \\  },
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
    try std.testing.expect(cfg.tracker != null);
    try std.testing.expectEqualStrings("http://127.0.0.1:7700", cfg.tracker.?.url.?);
    try std.testing.expectEqualStrings("boiler-1", cfg.tracker.?.agent_id);
    try std.testing.expectEqualStrings("reviewer", cfg.tracker.?.agent_role);
    try std.testing.expectEqual(@as(?u32, 3), cfg.tracker.?.max_concurrent_tasks);
}

test "TrackerConfig defaults" {
    const tc = TrackerConfig{};
    try std.testing.expectEqual(@as(?[]const u8, null), tc.url);
    try std.testing.expectEqual(@as(u32, 10000), tc.poll_interval_ms);
    try std.testing.expectEqualStrings("coder", tc.agent_role);
    try std.testing.expectEqual(@as(u32, 10), tc.concurrency.max_concurrent_tasks);
    try std.testing.expectEqual(@as(u32, 300000), tc.stall_timeout_ms);
    try std.testing.expectEqual(@as(u32, 60000), tc.lease_ttl_ms);
    try std.testing.expectEqual(@as(u32, 30000), tc.heartbeat_interval_ms);
    try std.testing.expectEqualStrings("workflows", tc.workflows_dir);
    try std.testing.expectEqual(@as(?[]const u8, null), tc.workflow_path);
    try std.testing.expectEqualStrings("nullboiler_run", tc.artifact_kind);
}

test "Config with tracker null by default" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(?TrackerConfig, null), cfg.tracker);
}

test "SubprocessDefaults has base_port and health_check_retries" {
    const sd = SubprocessDefaults{};
    try std.testing.expectEqual(@as(u16, 9200), sd.base_port);
    try std.testing.expectEqual(@as(u32, 10), sd.health_check_retries);
    try std.testing.expectEqualStrings("nullclaw", sd.command);
    try std.testing.expectEqual(@as(usize, 0), sd.args.len);
    try std.testing.expectEqualStrings("Continue working on this task. Your previous context is preserved.", sd.continuation_prompt);
}

test "resolveRelativePaths anchors tracker compat and advanced paths to config directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("configs");
    const cfg_json =
        \\{
        \\  "db": "data/nullboiler.db",
        \\  "strategies_dir": "strategies",
        \\  "tracker": {
        \\    "url": "http://127.0.0.1:7700",
        \\    "workflow_path": "tracker-workflow.json",
        \\    "workflows_dir": "workflows",
        \\    "workspace": {
        \\      "root": "workspaces"
        \\    },
        \\    "max_concurrent_tasks": 4
        \\  }
        \\}
    ;

    try tmp.dir.writeFile(.{
        .sub_path = "configs/config.json",
        .data = cfg_json,
    });

    const cfg_path = try tmp.dir.realpathAlloc(std.testing.allocator, "configs/config.json");
    defer std.testing.allocator.free(cfg_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cfg = try loadFromFile(arena.allocator(), cfg_path);
    try resolveRelativePaths(arena.allocator(), cfg_path, &cfg);

    const tracker = cfg.tracker.?;
    const config_dir = std.fs.path.dirname(cfg_path).?;
    const expected_db = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "data/nullboiler.db" });
    const expected_strategies = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "strategies" });
    const expected_workflow = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "tracker-workflow.json" });
    const expected_workflows = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "workflows" });
    const expected_workspace = try std.fs.path.resolve(arena.allocator(), &.{ config_dir, "workspaces" });

    try std.testing.expectEqualStrings(expected_db, cfg.db);
    try std.testing.expectEqualStrings(expected_strategies, cfg.strategies_dir);
    try std.testing.expectEqualStrings(expected_workflow, tracker.workflow_path.?);
    try std.testing.expectEqualStrings(expected_workflows, tracker.workflows_dir);
    try std.testing.expectEqualStrings(expected_workspace, tracker.workspace.root);
    try std.testing.expectEqual(@as(u32, 4), tracker.concurrency.max_concurrent_tasks);
}
