/// NullClaw subprocess manager — spawns, health-checks, and kills agent child processes.
/// Used in pull-mode execution where NullBoiler spawns NullClaw as a child process per task.
const std = @import("std");
const ids = @import("ids.zig");

// ── Types ─────────────────────────────────────────────────────────────

pub const SubprocessState = enum {
    starting,
    running,
    done,
    failed,
    stalled,

    pub fn toString(self: SubprocessState) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?SubprocessState {
        inline for (@typeInfo(SubprocessState).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const SubprocessInfo = struct {
    task_id: []const u8,
    lease_id: []const u8,
    lease_token: []const u8,
    workspace_path: []const u8,
    pipeline_id: []const u8,
    agent_role: []const u8,
    port: u16,
    child: ?std.process.Child,
    current_turn: u32,
    max_turns: u32,
    started_at_ms: i64,
    last_activity_ms: i64,
    state: SubprocessState,
    last_output: ?[]const u8,
    run_id: []const u8,
    task_title: []const u8,
    task_identifier: []const u8,
    execution_mode: []const u8,
};

// ── Spawn ─────────────────────────────────────────────────────────────

/// Spawn a NullClaw child process with the given command, args, port, and workspace path.
/// Builds argv: [command] ++ args ++ ["--port", port_str, "--workdir", workspace_path].
/// Returns the spawned child process with stdout/stderr piped.
pub fn spawnNullClaw(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
    port: u16,
    workspace_path: []const u8,
) !std.process.Child {
    // Build full argv: command + args + --port + port_str + --workdir + workspace_path
    const total_len = 1 + args.len + 4;
    const argv = try allocator.alloc([]const u8, total_len);
    defer allocator.free(argv);

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    argv[0] = command;
    for (args, 0..) |arg, i| {
        argv[1 + i] = arg;
    }
    argv[1 + args.len] = "--port";
    argv[1 + args.len + 1] = port_str;
    argv[1 + args.len + 2] = "--workdir";
    argv[1 + args.len + 3] = workspace_path;

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = workspace_path;

    try child.spawn();
    return child;
}

// ── Health Check ──────────────────────────────────────────────────────

/// Wait for a NullClaw child process to become healthy by polling its /health endpoint.
/// Returns true if a 2xx response is received within max_retries attempts (500ms between retries).
pub fn waitForHealth(
    allocator: std.mem.Allocator,
    port: u16,
    max_retries: u32,
) bool {
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/health", .{port}) catch return false;
    defer allocator.free(url);

    var attempt: u32 = 0;
    while (attempt < max_retries) : (attempt += 1) {
        if (attempt > 0) {
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var response_body: std.io.Writer.Allocating = .init(allocator);
        defer response_body.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &response_body.writer,
        }) catch continue;

        const status_code = @intFromEnum(result.status);
        if (status_code >= 200 and status_code < 300) {
            return true;
        }
    }
    return false;
}

// ── Prompt Sending ────────────────────────────────────────────────────

/// Send a prompt to a NullClaw child process via POST /webhook with {"message": prompt}.
/// Returns the response body on success, or null on failure.
pub fn sendPrompt(
    allocator: std.mem.Allocator,
    port: u16,
    prompt: []const u8,
) !?[]const u8 {
    const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/webhook", .{port});
    defer allocator.free(url);

    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .message = prompt,
    }, .{});
    defer allocator.free(body);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return null;

    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        return null;
    }

    const written = response_body.written();
    if (written.len == 0) return null;
    return try allocator.dupe(u8, written);
}

// ── Kill ──────────────────────────────────────────────────────────────

/// Kill a subprocess and wait for it to exit. Errors are silently ignored.
pub fn killSubprocess(child: *std.process.Child) void {
    _ = child.kill() catch null;
    _ = child.wait() catch null;
}

// ── Stall Detection ──────────────────────────────────────────────────

/// Check if a subprocess has stalled (no activity within the timeout period).
pub fn isStalled(info: *const SubprocessInfo, stall_timeout_ms: i64) bool {
    const now = ids.nowMs();
    return (now - info.last_activity_ms) > stall_timeout_ms;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "SubprocessState round-trip" {
    const s = SubprocessState.running;
    const name = s.toString();
    try std.testing.expectEqualStrings("running", name);
    const parsed = SubprocessState.fromString(name);
    try std.testing.expectEqual(SubprocessState.running, parsed.?);
}

test "SubprocessState fromString returns null for unknown" {
    try std.testing.expectEqual(@as(?SubprocessState, null), SubprocessState.fromString("bogus"));
}

test "SubprocessInfo can be constructed with all fields" {
    const info = SubprocessInfo{
        .task_id = "task-001",
        .lease_id = "lease-001",
        .lease_token = "token-abc",
        .workspace_path = "/tmp/workspace",
        .pipeline_id = "pipeline-001",
        .agent_role = "coder",
        .port = 9100,
        .child = null,
        .current_turn = 0,
        .max_turns = 10,
        .started_at_ms = 1000,
        .last_activity_ms = 2000,
        .state = .starting,
        .last_output = null,
        .run_id = "run-001",
        .task_title = "Fix bug #42",
        .task_identifier = "BUG-42",
        .execution_mode = "pull",
    };
    try std.testing.expectEqualStrings("task-001", info.task_id);
    try std.testing.expectEqualStrings("lease-001", info.lease_id);
    try std.testing.expectEqualStrings("token-abc", info.lease_token);
    try std.testing.expectEqualStrings("/tmp/workspace", info.workspace_path);
    try std.testing.expectEqualStrings("pipeline-001", info.pipeline_id);
    try std.testing.expectEqualStrings("coder", info.agent_role);
    try std.testing.expectEqual(@as(u16, 9100), info.port);
    try std.testing.expect(info.child == null);
    try std.testing.expectEqual(@as(u32, 0), info.current_turn);
    try std.testing.expectEqual(@as(u32, 10), info.max_turns);
    try std.testing.expectEqual(@as(i64, 1000), info.started_at_ms);
    try std.testing.expectEqual(@as(i64, 2000), info.last_activity_ms);
    try std.testing.expectEqual(SubprocessState.starting, info.state);
    try std.testing.expect(info.last_output == null);
    try std.testing.expectEqualStrings("run-001", info.run_id);
    try std.testing.expectEqualStrings("Fix bug #42", info.task_title);
    try std.testing.expectEqualStrings("BUG-42", info.task_identifier);
    try std.testing.expectEqualStrings("pull", info.execution_mode);
}

test "isStalled detects timeout" {
    const info = SubprocessInfo{
        .task_id = "task-001",
        .lease_id = "lease-001",
        .lease_token = "token-abc",
        .workspace_path = "/tmp/workspace",
        .pipeline_id = "pipeline-001",
        .agent_role = "coder",
        .port = 9100,
        .child = null,
        .current_turn = 0,
        .max_turns = 10,
        .started_at_ms = 0,
        .last_activity_ms = 0,
        .state = .running,
        .last_output = null,
        .run_id = "run-001",
        .task_title = "Fix bug",
        .task_identifier = "BUG-1",
        .execution_mode = "pull",
    };
    // last_activity_ms=0 means epoch, nowMs() is far in the future, so any timeout should trigger
    try std.testing.expect(isStalled(&info, 1000));
    try std.testing.expect(isStalled(&info, 0));
}

test "isStalled returns false for recent activity" {
    const now = ids.nowMs();
    const info = SubprocessInfo{
        .task_id = "task-001",
        .lease_id = "lease-001",
        .lease_token = "token-abc",
        .workspace_path = "/tmp/workspace",
        .pipeline_id = "pipeline-001",
        .agent_role = "coder",
        .port = 9100,
        .child = null,
        .current_turn = 0,
        .max_turns = 10,
        .started_at_ms = now,
        .last_activity_ms = now,
        .state = .running,
        .last_output = null,
        .run_id = "run-001",
        .task_title = "Fix bug",
        .task_identifier = "BUG-1",
        .execution_mode = "pull",
    };
    // With a large timeout and recent activity, should not be stalled
    try std.testing.expect(!isStalled(&info, 60_000));
}
