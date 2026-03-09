const std = @import("std");

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
    const tracker_agent_role = getString(obj, "tracker_agent_role") orelse "coder";
    const tracker_agent_id = getString(obj, "tracker_agent_id") orelse getString(obj, "instance_name") orelse "nullboiler";
    const tracker_success_trigger = getString(obj, "tracker_success_trigger");
    const tracker_max_concurrent_tasks = getU32(obj, "tracker_max_concurrent_tasks") orelse 1;
    const workflow_path = "tracker-workflow.json";

    const config_json = if (tracker_enabled and tracker_url != null)
        try std.json.Stringify.valueAlloc(allocator, .{
            .port = port,
            .db = db_path,
            .api_token = api_token,
            .tracker = .{
                .url = tracker_url.?,
                .api_token = tracker_api_token,
                .agent_id = tracker_agent_id,
                .agent_role = tracker_agent_role,
                .workflow_path = workflow_path,
                .success_trigger = tracker_success_trigger,
                .artifact_kind = "nullboiler_run",
                .max_concurrent_tasks = tracker_max_concurrent_tasks,
                .poll_interval_ms = 5000,
                .lease_ttl_ms = 120000,
                .heartbeat_interval_ms = 30000,
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
        const workflow_json = try buildDefaultWorkflow(allocator, tracker_success_trigger);
        defer allocator.free(workflow_json);
        try writeFileAtHome(allocator, home, workflow_path, workflow_json);
    }

    const stdout = std.fs.File.stdout();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}

fn buildDefaultWorkflow(allocator: std.mem.Allocator, success_trigger: ?[]const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    if (success_trigger) |trigger| {
        const trigger_json = try std.json.Stringify.valueAlloc(allocator, trigger, .{});
        defer allocator.free(trigger_json);
        try buf.appendSlice(allocator, "  \"success_trigger\": ");
        try buf.appendSlice(allocator, trigger_json);
        try buf.appendSlice(allocator, ",\n");
    }
    try buf.appendSlice(allocator,
        "  \"artifact_kind\": \"nullboiler_run\",\n" ++
            "  \"steps\": [\n" ++
            "    {\n" ++
            "      \"id\": \"task\",\n" ++
            "      \"type\": \"task\",\n" ++
            "      \"prompt_template\": \"Task {{input.task.id}}: {{input.task.title}}\\n\\n{{input.task.description}}\\n\\nMetadata:\\n{{input.task.metadata}}\"\n" ++
            "    }\n" ++
            "  ]\n" ++
            "}",
    );
    return buf.toOwnedSlice(allocator);
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
