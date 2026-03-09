const std = @import("std");
const builtin = @import("builtin");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0], .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    }

    const obj = parsed.value.object;
    const port = getU16(obj, "port") orelse 8080;
    const api_token = getString(obj, "api_token");
    const db_path = getString(obj, "db_path") orelse "nullboiler.db";
    const home = getString(obj, "home") orelse ".";
    const tracker_enabled = getBoolish(obj, "tracker_enabled");
    const tracker_url = getString(obj, "tracker_url");
    const tracker_api_token = getString(obj, "tracker_api_token");
    const tracker_pipeline_id = getString(obj, "tracker_pipeline_id");
    const tracker_claim_role = getString(obj, "tracker_claim_role") orelse "coder";
    const tracker_agent_id = getString(obj, "tracker_agent_id") orelse getString(obj, "instance_name") orelse "nullboiler";
    const tracker_success_trigger = getString(obj, "tracker_success_trigger") orelse "complete";
    const tracker_max_concurrent_tasks = getU32(obj, "tracker_max_concurrent_tasks") orelse 1;
    const tracker_poll_interval_ms = getU32(obj, "tracker_poll_interval_ms") orelse 10000;
    const tracker_lease_ttl_ms = getU32(obj, "tracker_lease_ttl_ms") orelse 60000;
    const tracker_heartbeat_interval_ms = getU32(obj, "tracker_heartbeat_interval_ms") orelse 30000;
    const tracker_stall_timeout_ms = getU32(obj, "tracker_stall_timeout_ms") orelse 300000;
    const tracker_workspace_root = getString(obj, "tracker_workspace_root") orelse "workspaces";
    const tracker_subprocess_command = getString(obj, "tracker_subprocess_command") orelse "nullclaw";
    const tracker_subprocess_base_port = getU16(obj, "tracker_subprocess_base_port") orelse 9200;
    const tracker_subprocess_health_check_retries = getU32(obj, "tracker_subprocess_health_check_retries") orelse 10;
    const tracker_subprocess_max_turns = getU32(obj, "tracker_subprocess_max_turns") orelse 20;
    const tracker_subprocess_turn_timeout_ms = getU32(obj, "tracker_subprocess_turn_timeout_ms") orelse 600000;
    const tracker_subprocess_continuation_prompt = getString(obj, "tracker_subprocess_continuation_prompt") orelse "Continue working on this task. Your previous context is preserved.";
    const workflows_dir = "workflows";

    if (tracker_enabled and tracker_url != null and tracker_pipeline_id == null) {
        std.debug.print("error: tracker_pipeline_id is required when tracker_enabled=true\n", .{});
        std.process.exit(1);
    }

    const config_json = if (tracker_enabled and tracker_url != null)
        try std.json.Stringify.valueAlloc(allocator, .{
            .port = port,
            .db = db_path,
            .api_token = api_token,
            .tracker = .{
                .url = tracker_url.?,
                .api_token = tracker_api_token,
                .agent_id = tracker_agent_id,
                .concurrency = .{
                    .max_concurrent_tasks = tracker_max_concurrent_tasks,
                },
                .poll_interval_ms = tracker_poll_interval_ms,
                .stall_timeout_ms = tracker_stall_timeout_ms,
                .lease_ttl_ms = tracker_lease_ttl_ms,
                .heartbeat_interval_ms = tracker_heartbeat_interval_ms,
                .workflows_dir = workflows_dir,
                .workspace = .{
                    .root = tracker_workspace_root,
                },
                .subprocess = .{
                    .command = tracker_subprocess_command,
                    .base_port = tracker_subprocess_base_port,
                    .health_check_retries = tracker_subprocess_health_check_retries,
                    .max_turns = tracker_subprocess_max_turns,
                    .turn_timeout_ms = tracker_subprocess_turn_timeout_ms,
                    .continuation_prompt = tracker_subprocess_continuation_prompt,
                },
            },
        }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false })
    else
        try std.json.Stringify.valueAlloc(allocator, .{
            .port = port,
            .db = db_path,
            .api_token = api_token,
        }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(config_json);

    try ensureHome(home);
    try writeFileAtHome(allocator, home, "config.json", config_json);

    if (tracker_enabled and tracker_url != null) {
        const workflow_name = try defaultWorkflowFileName(allocator, tracker_pipeline_id.?);
        defer allocator.free(workflow_name);
        const workflow_json = try buildDefaultWorkflow(allocator, tracker_pipeline_id.?, tracker_claim_role, tracker_success_trigger);
        defer allocator.free(workflow_json);
        const workflow_rel_path = try std.fs.path.join(allocator, &.{ workflows_dir, workflow_name });
        defer allocator.free(workflow_rel_path);
        try writeFileAtHome(allocator, home, workflow_rel_path, workflow_json);
    }

    if (!builtin.is_test) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll("{\"status\":\"ok\"}\n");
    }
}

fn buildDefaultWorkflow(
    allocator: std.mem.Allocator,
    pipeline_id: []const u8,
    claim_role: []const u8,
    success_trigger: []const u8,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .id = try std.fmt.allocPrint(allocator, "wf-{s}-{s}", .{ pipeline_id, claim_role }),
        .pipeline_id = pipeline_id,
        .claim_roles = &.{claim_role},
        .execution = "subprocess",
        .prompt_template = "Task {{task.id}}: {{task.title}}\n\n{{task.description}}\n\nMetadata:\n{{task.metadata}}",
        .on_success = .{
            .transition_to = success_trigger,
        },
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn getBoolish(obj: std.json.ObjectMap, key: []const u8) bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .bool => |v| v,
        .string => |v| std.mem.eql(u8, v, "true"),
        else => false,
    };
}

fn getU16(obj: std.json.ObjectMap, key: []const u8) ?u16 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(u16)) @intCast(v) else null,
        .string => |v| std.fmt.parseInt(u16, v, 10) catch null,
        else => null,
    };
}

fn getU32(obj: std.json.ObjectMap, key: []const u8) ?u32 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| if (v >= 0 and v <= std.math.maxInt(u32)) @intCast(v) else null,
        .string => |v| std.fmt.parseInt(u32, v, 10) catch null,
        else => null,
    };
}

fn ensureHome(home: []const u8) !void {
    if (std.fs.path.isAbsolute(home)) {
        std.fs.makeDirAbsolute(home) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }

    std.fs.cwd().makePath(home) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn writeFileAtHome(allocator: std.mem.Allocator, home: []const u8, name: []const u8, contents: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ home, name });
    defer allocator.free(path);
    try ensureParentDir(home, name);

    if (std.fs.path.isAbsolute(home)) {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(contents);
        try file.writeAll("\n");
        return;
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(contents);
    try file.writeAll("\n");
}

fn ensureParentDir(home: []const u8, name: []const u8) !void {
    const parent = std.fs.path.dirname(name) orelse return;
    if (std.fs.path.isAbsolute(home)) {
        const full_parent = try std.fs.path.join(std.heap.page_allocator, &.{ home, parent });
        defer std.heap.page_allocator.free(full_parent);
        std.fs.makeDirAbsolute(full_parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return;
    }

    const full_parent = try std.fs.path.join(std.heap.page_allocator, &.{ home, parent });
    defer std.heap.page_allocator.free(full_parent);
    std.fs.cwd().makePath(full_parent) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn defaultWorkflowFileName(allocator: std.mem.Allocator, pipeline_id: []const u8) ![]const u8 {
    const safe = try sanitizeFileComponent(allocator, pipeline_id);
    defer allocator.free(safe);
    return std.fmt.allocPrint(allocator, "{s}.json", .{safe});
}

fn sanitizeFileComponent(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, value.len);
    for (out, value) |*dst, ch| {
        dst.* = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')
            ch
        else
            '_';
    }
    return out;
}

test "run writes tracker config and workflow with advanced settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try std.json.Stringify.valueAlloc(arena.allocator(), .{
        .home = home,
        .port = 9091,
        .db_path = "tracker.db",
        .api_token = "local-token",
        .instance_name = "boiler-a",
        .tracker_enabled = "true",
        .tracker_url = "http://127.0.0.1:7700",
        .tracker_api_token = "tracker-secret",
        .tracker_pipeline_id = "pipeline.dev",
        .tracker_claim_role = "reviewer",
        .tracker_success_trigger = "ship",
        .tracker_max_concurrent_tasks = "2",
        .tracker_poll_interval_ms = "15000",
        .tracker_lease_ttl_ms = "90000",
        .tracker_heartbeat_interval_ms = "45000",
        .tracker_stall_timeout_ms = "123000",
        .tracker_workspace_root = "workspaces",
        .tracker_subprocess_command = "nullclaw",
        .tracker_subprocess_base_port = "9300",
        .tracker_subprocess_health_check_retries = "7",
        .tracker_subprocess_max_turns = "11",
        .tracker_subprocess_turn_timeout_ms = "700000",
        .tracker_subprocess_continuation_prompt = "Keep going.",
    }, .{});

    try run(arena.allocator(), &.{input});

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ home, "config.json" });
    defer std.testing.allocator.free(config_path);
    const config_file = try std.fs.openFileAbsolute(config_path, .{});
    defer config_file.close();
    const config_bytes = try config_file.readToEndAlloc(arena.allocator(), 64 * 1024);

    const ConfigFile = struct {
        port: u16,
        db: []const u8,
        api_token: ?[]const u8 = null,
        tracker: struct {
            url: []const u8,
            api_token: ?[]const u8 = null,
            agent_id: []const u8,
            poll_interval_ms: u32,
            stall_timeout_ms: u32,
            lease_ttl_ms: u32,
            heartbeat_interval_ms: u32,
            workflows_dir: []const u8,
            concurrency: struct {
                max_concurrent_tasks: u32,
            },
            workspace: struct {
                root: []const u8,
            },
            subprocess: struct {
                command: []const u8,
                base_port: u16,
                health_check_retries: u32,
                max_turns: u32,
                turn_timeout_ms: u32,
                continuation_prompt: []const u8,
            },
        },
    };

    const parsed_cfg = try std.json.parseFromSlice(ConfigFile, arena.allocator(), config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed_cfg.deinit();

    try std.testing.expectEqual(@as(u16, 9091), parsed_cfg.value.port);
    try std.testing.expectEqualStrings("tracker.db", parsed_cfg.value.db);
    try std.testing.expectEqualStrings("local-token", parsed_cfg.value.api_token.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:7700", parsed_cfg.value.tracker.url);
    try std.testing.expectEqualStrings("tracker-secret", parsed_cfg.value.tracker.api_token.?);
    try std.testing.expectEqualStrings("boiler-a", parsed_cfg.value.tracker.agent_id);
    try std.testing.expectEqual(@as(u32, 2), parsed_cfg.value.tracker.concurrency.max_concurrent_tasks);
    try std.testing.expectEqual(@as(u32, 15000), parsed_cfg.value.tracker.poll_interval_ms);
    try std.testing.expectEqual(@as(u32, 123000), parsed_cfg.value.tracker.stall_timeout_ms);
    try std.testing.expectEqual(@as(u32, 90000), parsed_cfg.value.tracker.lease_ttl_ms);
    try std.testing.expectEqual(@as(u32, 45000), parsed_cfg.value.tracker.heartbeat_interval_ms);
    try std.testing.expectEqualStrings("workflows", parsed_cfg.value.tracker.workflows_dir);
    try std.testing.expectEqualStrings("workspaces", parsed_cfg.value.tracker.workspace.root);
    try std.testing.expectEqualStrings("nullclaw", parsed_cfg.value.tracker.subprocess.command);
    try std.testing.expectEqual(@as(u16, 9300), parsed_cfg.value.tracker.subprocess.base_port);
    try std.testing.expectEqual(@as(u32, 7), parsed_cfg.value.tracker.subprocess.health_check_retries);
    try std.testing.expectEqual(@as(u32, 11), parsed_cfg.value.tracker.subprocess.max_turns);
    try std.testing.expectEqual(@as(u32, 700000), parsed_cfg.value.tracker.subprocess.turn_timeout_ms);
    try std.testing.expectEqualStrings("Keep going.", parsed_cfg.value.tracker.subprocess.continuation_prompt);

    const workflow_path = try std.fs.path.join(std.testing.allocator, &.{ home, "workflows", "pipeline.dev.json" });
    defer std.testing.allocator.free(workflow_path);
    const workflow_file = try std.fs.openFileAbsolute(workflow_path, .{});
    defer workflow_file.close();
    const workflow_bytes = try workflow_file.readToEndAlloc(arena.allocator(), 16 * 1024);

    const WorkflowFile = struct {
        pipeline_id: []const u8,
        claim_roles: []const []const u8,
        execution: []const u8,
        on_success: struct {
            transition_to: []const u8,
        },
    };

    const parsed_workflow = try std.json.parseFromSlice(WorkflowFile, arena.allocator(), workflow_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed_workflow.deinit();

    try std.testing.expectEqualStrings("pipeline.dev", parsed_workflow.value.pipeline_id);
    try std.testing.expectEqual(@as(usize, 1), parsed_workflow.value.claim_roles.len);
    try std.testing.expectEqualStrings("reviewer", parsed_workflow.value.claim_roles[0]);
    try std.testing.expectEqualStrings("subprocess", parsed_workflow.value.execution);
    try std.testing.expectEqualStrings("ship", parsed_workflow.value.on_success.transition_to);
}
