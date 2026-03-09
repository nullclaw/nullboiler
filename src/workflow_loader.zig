const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────

pub const ExecutionMode = enum {
    subprocess,
    dispatch,
};

pub const SubprocessConfig = struct {
    command: []const u8 = "nullclaw",
    args: []const []const u8 = &.{},
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
};

pub const DispatchConfig = struct {
    worker_tags: []const []const u8 = &.{},
    protocol: []const u8 = "webhook",
};

pub const TransitionConfig = struct {
    transition_to: []const u8 = "",
};

pub const WorkflowDef = struct {
    id: []const u8 = "",
    pipeline_id: []const u8 = "",
    claim_roles: []const []const u8 = &.{},
    execution: ExecutionMode = .subprocess,
    subprocess: SubprocessConfig = .{},
    dispatch: DispatchConfig = .{},
    prompt_template: ?[]const u8 = null,
    on_success: TransitionConfig = .{},
    on_failure: TransitionConfig = .{ .transition_to = "failed" },
};

pub const WorkflowMap = std.StringArrayHashMapUnmanaged(WorkflowDef);

// ── loadWorkflows ─────────────────────────────────────────────────────

pub fn loadWorkflows(allocator: std.mem.Allocator, dir_path: []const u8) WorkflowMap {
    var map = WorkflowMap{};
    var dir = if (std.fs.path.isAbsolute(dir_path))
        std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return map
    else
        std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return map;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const contents = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        const parsed = std.json.parseFromSlice(WorkflowDef, allocator, contents, .{}) catch continue;
        const def = parsed.value;

        if (def.pipeline_id.len == 0) continue;

        map.put(allocator, def.pipeline_id, def) catch continue;
    }

    return map;
}

test "loadWorkflows: supports absolute workflow directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "current.json",
        .data =
        \\{
        \\  "id": "wf-absolute",
        \\  "pipeline_id": "absolute",
        \\  "claim_roles": ["coder"],
        \\  "on_success": {"transition_to": "complete"}
        \\}
        ,
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expectEqualStrings("absolute", map.get("absolute").?.pipeline_id);
}

// ── getWorkflowForPipeline ────────────────────────────────────────────

pub fn getWorkflowForPipeline(map: *const WorkflowMap, pipeline_id: []const u8) ?*const WorkflowDef {
    return map.getPtr(pipeline_id);
}

// ── Tests ─────────────────────────────────────────────────────────────

test "WorkflowDef defaults" {
    const def = WorkflowDef{};
    try std.testing.expectEqualStrings("", def.id);
    try std.testing.expectEqualStrings("", def.pipeline_id);
    try std.testing.expectEqual(@as(usize, 0), def.claim_roles.len);
    try std.testing.expectEqual(ExecutionMode.subprocess, def.execution);
    try std.testing.expectEqualStrings("nullclaw", def.subprocess.command);
    try std.testing.expectEqual(@as(usize, 0), def.subprocess.args.len);
    try std.testing.expectEqual(@as(u32, 20), def.subprocess.max_turns);
    try std.testing.expectEqual(@as(u32, 600000), def.subprocess.turn_timeout_ms);
    try std.testing.expectEqual(@as(usize, 0), def.dispatch.worker_tags.len);
    try std.testing.expectEqualStrings("webhook", def.dispatch.protocol);
    try std.testing.expectEqual(@as(?[]const u8, null), def.prompt_template);
    try std.testing.expectEqualStrings("", def.on_success.transition_to);
    try std.testing.expectEqualStrings("failed", def.on_failure.transition_to);
}

test "SubprocessConfig defaults" {
    const cfg = SubprocessConfig{};
    try std.testing.expectEqualStrings("nullclaw", cfg.command);
    try std.testing.expectEqual(@as(u32, 20), cfg.max_turns);
    try std.testing.expectEqual(@as(u32, 600000), cfg.turn_timeout_ms);
}

test "loadWorkflows: returns empty map when directory missing" {
    const map = loadWorkflows(std.testing.allocator, "nonexistent_workflow_dir_xyz_999");
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "loadWorkflows: loads JSON files from directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "code_review.json",
        .data =
        \\{
        \\  "id": "wf-code-review",
        \\  "pipeline_id": "code-review",
        \\  "claim_roles": ["reviewer"],
        \\  "execution": "subprocess",
        \\  "subprocess": {
        \\    "command": "nullclaw",
        \\    "max_turns": 10,
        \\    "turn_timeout_ms": 300000
        \\  },
        \\  "prompt_template": "Review this code: {{input.code}}",
        \\  "on_success": {"transition_to": "done"},
        \\  "on_failure": {"transition_to": "needs_review"}
        \\}
        ,
    });

    try tmp.dir.writeFile(.{
        .sub_path = "deploy.json",
        .data =
        \\{
        \\  "id": "wf-deploy",
        \\  "pipeline_id": "deploy",
        \\  "claim_roles": ["deployer"],
        \\  "execution": "dispatch",
        \\  "dispatch": {
        \\    "worker_tags": ["deploy"],
        \\    "protocol": "webhook"
        \\  }
        \\}
        ,
    });

    // Non-json file should be ignored
    try tmp.dir.writeFile(.{
        .sub_path = "readme.txt",
        .data = "not json",
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 2), map.count());

    const cr = map.get("code-review").?;
    try std.testing.expectEqualStrings("wf-code-review", cr.id);
    try std.testing.expectEqual(ExecutionMode.subprocess, cr.execution);
    try std.testing.expectEqualStrings("nullclaw", cr.subprocess.command);
    try std.testing.expectEqual(@as(u32, 10), cr.subprocess.max_turns);
    try std.testing.expectEqualStrings("Review this code: {{input.code}}", cr.prompt_template.?);
    try std.testing.expectEqualStrings("done", cr.on_success.transition_to);
    try std.testing.expectEqualStrings("needs_review", cr.on_failure.transition_to);

    const dep = map.get("deploy").?;
    try std.testing.expectEqualStrings("wf-deploy", dep.id);
    try std.testing.expectEqual(ExecutionMode.dispatch, dep.execution);
    try std.testing.expectEqual(@as(usize, 1), dep.dispatch.worker_tags.len);
    try std.testing.expectEqualStrings("deploy", dep.dispatch.worker_tags[0]);
}

test "loadWorkflows: skips files with empty pipeline_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "no_pipeline.json",
        .data =
        \\{"id": "wf-nope", "pipeline_id": ""}
        ,
    });

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const map = loadWorkflows(arena.allocator(), dir_path);
    try std.testing.expectEqual(@as(usize, 0), map.count());
}

test "getWorkflowForPipeline: returns pointer when found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map = WorkflowMap{};
    map.put(alloc, "my-pipeline", WorkflowDef{
        .id = "wf-1",
        .pipeline_id = "my-pipeline",
    }) catch unreachable;

    const result = getWorkflowForPipeline(&map, "my-pipeline");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("wf-1", result.?.id);
}

test "getWorkflowForPipeline: returns null when not found" {
    var map = WorkflowMap{};
    const result = getWorkflowForPipeline(&map, "nonexistent");
    try std.testing.expectEqual(@as(?*const WorkflowDef, null), result);
}
