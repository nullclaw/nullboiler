const std = @import("std");
const config_mod = @import("config.zig");
const ids = @import("ids.zig");
const Store = @import("store.zig").Store;
const tracker_client = @import("tracker_compat_client.zig");
const workflow_validation = @import("workflow_validation.zig");
const types = @import("types.zig");

pub const State = struct {
    allocator: std.mem.Allocator,
    store: *Store,
    cfg: config_mod.TrackerConfig,
    drain_mode: *std.atomic.Value(bool),
    shutdown_requested: *std.atomic.Value(bool),
    mutex: std.Thread.Mutex = .{},
    snapshot: Snapshot = .{},

    pub const Snapshot = struct {
        enabled: bool = true,
        last_poll_ms: ?i64 = null,
        last_heartbeat_ms: ?i64 = null,
        last_error_buf: [256]u8 = [_]u8{0} ** 256,
        last_error_len: usize = 0,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        store: *Store,
        cfg: config_mod.TrackerConfig,
        drain_mode: *std.atomic.Value(bool),
        shutdown_requested: *std.atomic.Value(bool),
    ) State {
        return .{
            .allocator = allocator,
            .store = store,
            .cfg = cfg,
            .drain_mode = drain_mode,
            .shutdown_requested = shutdown_requested,
        };
    }

    pub fn run(self: *State) void {
        while (!self.shutdown_requested.load(.acquire)) {
            self.tick();
            sleepInterruptible(self.cfg.poll_interval_ms, self.shutdown_requested);
        }
    }

    pub fn renderStatusJson(self: *State, allocator: std.mem.Allocator) ![]const u8 {
        const snapshot = self.snapshotCopy();
        const running = try self.store.listTrackerRuns(allocator, "running", null);
        const completed = self.store.countTrackerRunsByState("completed") catch 0;
        const failed = self.store.countTrackerRunsByState("failed") catch 0;
        const total = self.store.countTrackerRuns() catch 0;

        var views: std.ArrayListUnmanaged(TaskView) = .empty;
        defer views.deinit(allocator);
        for (running) |row| {
            try views.append(allocator, taskView(row));
        }

        return std.json.Stringify.valueAlloc(allocator, .{
            .enabled = true,
            .tracker_url = self.cfg.url,
            .agent_id = self.cfg.agent_id,
            .agent_role = self.cfg.agent_role,
            .workflow_path = self.cfg.workflow_path,
            .max_concurrent_tasks = effectiveMaxConcurrentTasks(self.cfg),
            .running_count = running.len,
            .completed_count = completed,
            .failed_count = failed,
            .total_claimed = total,
            .last_poll_ms = snapshot.last_poll_ms,
            .last_heartbeat_ms = snapshot.last_heartbeat_ms,
            .last_error = snapshot.last_error,
            .running = views.items,
        }, .{ .emit_null_optional_fields = false });
    }

    pub fn renderTasksJson(self: *State, allocator: std.mem.Allocator) ![]const u8 {
        const rows = try self.store.listTrackerRuns(allocator, null, 100);
        var views: std.ArrayListUnmanaged(TaskView) = .empty;
        defer views.deinit(allocator);
        for (rows) |row| {
            try views.append(allocator, taskView(row));
        }
        return std.json.Stringify.valueAlloc(allocator, views.items, .{ .emit_null_optional_fields = false });
    }

    pub fn renderTaskJson(self: *State, allocator: std.mem.Allocator, task_id: []const u8) !?[]const u8 {
        const row = try self.store.getTrackerRunByTaskId(allocator, task_id) orelse return null;
        const boiler_run = try self.store.getRun(allocator, row.boiler_run_id);
        const steps = try self.store.getStepsByRun(allocator, row.boiler_run_id);
        const final_output = extractFinalOutput(steps);

        const body = try std.json.Stringify.valueAlloc(allocator, .{
            .task = taskView(row),
            .run = if (boiler_run) |r| .{
                .id = r.id,
                .status = r.status,
                .error_text = r.error_text,
                .started_at_ms = r.started_at_ms,
                .ended_at_ms = r.ended_at_ms,
            } else null,
            .final_output = final_output,
        }, .{ .emit_null_optional_fields = false });
        return body;
    }

    pub fn renderStatsJson(self: *State, allocator: std.mem.Allocator) ![]const u8 {
        const running = self.store.countTrackerRunsByState("running") catch 0;
        const completed = self.store.countTrackerRunsByState("completed") catch 0;
        const failed = self.store.countTrackerRunsByState("failed") catch 0;
        const total = self.store.countTrackerRuns() catch 0;
        const success_rate = if (completed + failed > 0)
            @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(completed + failed))
        else
            0.0;

        return std.json.Stringify.valueAlloc(allocator, .{
            .running = running,
            .completed = completed,
            .failed = failed,
            .total = total,
            .success_rate = success_rate,
        }, .{ .emit_null_optional_fields = false });
    }

    fn tick(self: *State) void {
        self.setLastPoll(ids.nowMs());

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        self.processRunning(allocator) catch |err| {
            self.setLastError(@errorName(err));
        };

        if (self.drain_mode.load(.acquire)) return;

        var capacity = self.availableCapacity() catch {
            self.setLastError("tracker_capacity_check_failed");
            return;
        };

        while (capacity > 0 and !self.shutdown_requested.load(.acquire) and !self.drain_mode.load(.acquire)) {
            var claim_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer claim_arena.deinit();
            const claim_allocator = claim_arena.allocator();

            const has_work = tracker_client.hasClaimableWork(claim_allocator, self.cfg) catch |err| {
                self.setLastError(@errorName(err));
                break;
            };
            if (!has_work) break;

            const claim = tracker_client.claim(claim_allocator, self.cfg) catch |err| {
                self.setLastError(@errorName(err));
                break;
            } orelse break;

            self.handleClaim(claim_allocator, claim) catch |err| {
                const msg = @errorName(err);
                self.setLastError(msg);
                tracker_client.failRun(claim_allocator, self.cfg, claim.run.id, claim.lease_token, msg) catch {};
            };

            capacity -= 1;
        }
    }

    fn availableCapacity(self: *State) !i64 {
        const running = try self.store.countTrackerRunsByState("running");
        const max: i64 = @intCast(effectiveMaxConcurrentTasks(self.cfg));
        return if (running >= max) 0 else max - running;
    }

    fn processRunning(self: *State, allocator: std.mem.Allocator) !void {
        const rows = try self.store.listTrackerRuns(allocator, "running", null);
        const now_ms = ids.nowMs();

        for (rows) |row| {
            const boiler_run = try self.store.getRun(allocator, row.boiler_run_id) orelse {
                try self.store.upsertTrackerRun(
                    row.task_id,
                    row.tracker_run_id,
                    row.boiler_run_id,
                    row.lease_id,
                    row.lease_token,
                    row.pipeline_id,
                    row.agent_role,
                    row.task_title,
                    row.task_stage,
                    row.task_version,
                    row.success_trigger,
                    row.artifact_kind,
                    "failed",
                    row.claimed_at_ms,
                    row.last_heartbeat_ms,
                    row.lease_expires_at_ms,
                    now_ms,
                    "boiler_run_missing",
                );
                continue;
            };

            if (std.mem.eql(u8, boiler_run.status, "completed")) {
                try self.finalizeSuccess(allocator, row);
                continue;
            }
            if (std.mem.eql(u8, boiler_run.status, "failed") or std.mem.eql(u8, boiler_run.status, "cancelled")) {
                try self.finalizeFailure(allocator, row, boiler_run.error_text orelse boiler_run.status);
                continue;
            }

            const last_heartbeat = row.last_heartbeat_ms orelse row.claimed_at_ms;
            if (now_ms - last_heartbeat >= @as(i64, @intCast(self.cfg.heartbeat_interval_ms))) {
                const hb = tracker_client.heartbeat(allocator, self.cfg, row.lease_id, row.lease_token) catch |err| {
                    const err_text = @errorName(err);
                    try self.store.upsertTrackerRun(
                        row.task_id,
                        row.tracker_run_id,
                        row.boiler_run_id,
                        row.lease_id,
                        row.lease_token,
                        row.pipeline_id,
                        row.agent_role,
                        row.task_title,
                        row.task_stage,
                        row.task_version,
                        row.success_trigger,
                        row.artifact_kind,
                        "failed",
                        row.claimed_at_ms,
                        row.last_heartbeat_ms,
                        row.lease_expires_at_ms,
                        now_ms,
                        err_text,
                    );
                    try self.store.updateRunStatus(row.boiler_run_id, "failed", "tracker_heartbeat_failed");
                    return err;
                };

                try self.store.upsertTrackerRun(
                    row.task_id,
                    row.tracker_run_id,
                    row.boiler_run_id,
                    row.lease_id,
                    row.lease_token,
                    row.pipeline_id,
                    row.agent_role,
                    row.task_title,
                    row.task_stage,
                    row.task_version,
                    row.success_trigger,
                    row.artifact_kind,
                    row.state,
                    row.claimed_at_ms,
                    now_ms,
                    hb.expires_at_ms,
                    row.completed_at_ms,
                    row.last_error_text,
                );
                self.setLastHeartbeat(now_ms);
            }
        }
    }

    fn handleClaim(self: *State, allocator: std.mem.Allocator, claim: tracker_client.ClaimResponse) !void {
        const workflow_path = self.cfg.workflow_path orelse return error.WorkflowTemplateMissing;
        const now_ms = ids.nowMs();
        const workflow = try loadWorkflowTemplate(allocator, workflow_path);
        const build = try buildWorkflowBody(allocator, workflow, claim, self.cfg);
        const boiler_run_id = try self.createBoilerRun(allocator, build.run_body);

        try self.store.upsertTrackerRun(
            claim.task.id,
            claim.run.id,
            boiler_run_id,
            claim.lease_id,
            claim.lease_token,
            claim.task.pipeline_id,
            self.cfg.agent_role,
            claim.task.title,
            claim.task.stage,
            claim.task.task_version,
            build.success_trigger,
            build.artifact_kind,
            "running",
            now_ms,
            now_ms,
            claim.expires_at_ms,
            null,
            null,
        );
    }

    fn finalizeSuccess(self: *State, allocator: std.mem.Allocator, row: types.TrackerRunRow) !void {
        const success_trigger = try self.resolveSuccessTrigger(allocator, row);
        errdefer tracker_client.failRun(allocator, self.cfg, row.tracker_run_id, row.lease_token, "missing_success_trigger") catch {};

        try tracker_client.transitionRun(
            allocator,
            self.cfg,
            row.tracker_run_id,
            row.lease_token,
            success_trigger,
            row.task_stage,
            row.task_version,
        );

        const steps = try self.store.getStepsByRun(allocator, row.boiler_run_id);
        const final_output = extractFinalOutput(steps) orelse "";
        const meta_json = try std.fmt.allocPrint(allocator,
            "{{\"boiler_run_id\":{f},\"task_id\":{f},\"final_output\":{f}}}",
            .{
                std.json.fmt(row.boiler_run_id, .{}),
                std.json.fmt(row.task_id, .{}),
                std.json.fmt(final_output, .{}),
            },
        );
        defer allocator.free(meta_json);

        const artifact_uri = try std.fmt.allocPrint(allocator, "nullboiler://runs/{s}", .{row.boiler_run_id});
        defer allocator.free(artifact_uri);
        tracker_client.addArtifact(allocator, self.cfg, row.task_id, row.tracker_run_id, row.artifact_kind, artifact_uri, meta_json) catch {};

        try self.store.upsertTrackerRun(
            row.task_id,
            row.tracker_run_id,
            row.boiler_run_id,
            row.lease_id,
            row.lease_token,
            row.pipeline_id,
            row.agent_role,
            row.task_title,
            row.task_stage,
            row.task_version,
            row.success_trigger,
            row.artifact_kind,
            "completed",
            row.claimed_at_ms,
            row.last_heartbeat_ms,
            row.lease_expires_at_ms,
            ids.nowMs(),
            null,
        );
    }

    fn finalizeFailure(self: *State, allocator: std.mem.Allocator, row: types.TrackerRunRow, error_text: []const u8) !void {
        try tracker_client.failRun(allocator, self.cfg, row.tracker_run_id, row.lease_token, error_text);
        try self.store.upsertTrackerRun(
            row.task_id,
            row.tracker_run_id,
            row.boiler_run_id,
            row.lease_id,
            row.lease_token,
            row.pipeline_id,
            row.agent_role,
            row.task_title,
            row.task_stage,
            row.task_version,
            row.success_trigger,
            row.artifact_kind,
            "failed",
            row.claimed_at_ms,
            row.last_heartbeat_ms,
            row.lease_expires_at_ms,
            ids.nowMs(),
            error_text,
        );
    }

    fn resolveSuccessTrigger(self: *State, allocator: std.mem.Allocator, row: types.TrackerRunRow) ![]const u8 {
        if (row.success_trigger) |trigger| {
            if (trigger.len > 0) return trigger;
        }

        const task = try tracker_client.getTask(allocator, self.cfg, row.task_id);
        if (task.available_transitions.len == 1) {
            return task.available_transitions[0].trigger;
        }
        return error.MissingSuccessTrigger;
    }

    fn createBoilerRun(self: *State, allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidWorkflow;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidWorkflow;
        const obj = parsed.value.object;
        const steps_val = obj.get("steps") orelse return error.InvalidWorkflow;
        if (steps_val != .array or steps_val.array.items.len == 0) return error.InvalidWorkflow;

        try workflow_validation.validateStepsForCreateRun(allocator, steps_val.array.items);

        const input_json = serializeJsonValue(allocator, obj.get("input")) catch return error.InvalidWorkflow;
        const callbacks_json = serializeJsonValue(allocator, obj.get("callbacks")) catch return error.InvalidWorkflow;

        try self.store.beginTransaction();
        errdefer self.store.rollbackTransaction() catch {};

        const run_id_buf = ids.generateId();
        const run_id = try allocator.dupe(u8, &run_id_buf);
        try self.store.insertRun(run_id, null, "running", body, input_json, callbacks_json);

        var def_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer def_ids.deinit(allocator);
        var gen_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer gen_ids.deinit(allocator);

        for (steps_val.array.items) |step_val| {
            if (step_val != .object) return error.InvalidWorkflow;
            const step_obj = step_val.object;
            const def_step_id = getJsonString(step_obj, "id") orelse return error.InvalidWorkflow;
            const step_type = getJsonString(step_obj, "type") orelse "task";
            const has_deps = if (step_obj.get("depends_on")) |deps| deps == .array and deps.array.items.len > 0 else false;
            const initial_status: []const u8 = if (has_deps) "pending" else "ready";
            const max_attempts: i64 = if (step_obj.get("retry")) |retry_val| blk: {
                if (retry_val == .object) {
                    if (retry_val.object.get("max_attempts")) |ma| {
                        if (ma == .integer) break :blk ma.integer;
                    }
                }
                break :blk 1;
            } else 1;
            const timeout_ms: ?i64 = if (step_obj.get("timeout_ms")) |timeout_val|
                if (timeout_val == .integer) timeout_val.integer else null
            else
                null;

            const step_id_buf = ids.generateId();
            const step_id = try allocator.dupe(u8, &step_id_buf);
            try self.store.insertStep(step_id, run_id, def_step_id, step_type, initial_status, "{}", max_attempts, timeout_ms, null, null);
            try def_ids.append(allocator, def_step_id);
            try gen_ids.append(allocator, step_id);
        }

        for (steps_val.array.items) |step_val| {
            if (step_val != .object) continue;
            const step_obj = step_val.object;
            const def_step_id = getJsonString(step_obj, "id") orelse continue;
            const step_id = lookupGenId(def_ids.items, gen_ids.items, def_step_id) orelse continue;

            const deps_val = step_obj.get("depends_on") orelse continue;
            if (deps_val != .array) return error.InvalidWorkflow;
            for (deps_val.array.items) |dep_item| {
                if (dep_item != .string) return error.InvalidWorkflow;
                const dep_step_id = lookupGenId(def_ids.items, gen_ids.items, dep_item.string) orelse return error.InvalidWorkflow;
                try self.store.insertStepDep(step_id, dep_step_id);
            }
        }

        try self.store.commitTransaction();
        return run_id;
    }

    fn snapshotCopy(self: *State) struct {
        last_poll_ms: ?i64,
        last_heartbeat_ms: ?i64,
        last_error: ?[]const u8,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .last_poll_ms = self.snapshot.last_poll_ms,
            .last_heartbeat_ms = self.snapshot.last_heartbeat_ms,
            .last_error = if (self.snapshot.last_error_len > 0) self.snapshot.last_error_buf[0..self.snapshot.last_error_len] else null,
        };
    }

    fn setLastPoll(self: *State, ts_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot.last_poll_ms = ts_ms;
    }

    fn setLastHeartbeat(self: *State, ts_ms: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.snapshot.last_heartbeat_ms = ts_ms;
    }

    fn setLastError(self: *State, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const trimmed = message[0..@min(message.len, self.snapshot.last_error_buf.len)];
        @memcpy(self.snapshot.last_error_buf[0..trimmed.len], trimmed);
        self.snapshot.last_error_len = trimmed.len;
    }
};

const WorkflowTemplate = struct {
    success_trigger: ?[]const u8,
    artifact_kind: []const u8,
    root: std.json.Value,
};

const BuiltWorkflow = struct {
    run_body: []const u8,
    success_trigger: ?[]const u8,
    artifact_kind: []const u8,
};

const TaskView = struct {
    task_id: []const u8,
    tracker_run_id: []const u8,
    boiler_run_id: []const u8,
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
};

fn effectiveMaxConcurrentTasks(cfg: config_mod.TrackerConfig) u32 {
    return cfg.max_concurrent_tasks orelse cfg.concurrency.max_concurrent_tasks;
}

fn taskView(row: types.TrackerRunRow) TaskView {
    return .{
        .task_id = row.task_id,
        .tracker_run_id = row.tracker_run_id,
        .boiler_run_id = row.boiler_run_id,
        .pipeline_id = row.pipeline_id,
        .agent_role = row.agent_role,
        .task_title = row.task_title,
        .task_stage = row.task_stage,
        .task_version = row.task_version,
        .success_trigger = row.success_trigger,
        .artifact_kind = row.artifact_kind,
        .state = row.state,
        .claimed_at_ms = row.claimed_at_ms,
        .last_heartbeat_ms = row.last_heartbeat_ms,
        .lease_expires_at_ms = row.lease_expires_at_ms,
        .completed_at_ms = row.completed_at_ms,
        .last_error_text = row.last_error_text,
    };
}

fn loadWorkflowTemplate(allocator: std.mem.Allocator, path: []const u8) !WorkflowTemplate {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.WorkflowTemplateMissing;
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch return error.InvalidWorkflow;
    if (parsed.value != .object) return error.InvalidWorkflow;

    const obj = parsed.value.object;
    return .{
        .success_trigger = if (obj.get("success_trigger")) |val|
            if (val == .string) val.string else null
        else
            null,
        .artifact_kind = if (obj.get("artifact_kind")) |val|
            if (val == .string) val.string else "nullboiler_run"
        else
            "nullboiler_run",
        .root = parsed.value,
    };
}

fn buildWorkflowBody(
    allocator: std.mem.Allocator,
    workflow: WorkflowTemplate,
    claim: tracker_client.ClaimResponse,
    cfg: config_mod.TrackerConfig,
) !BuiltWorkflow {
    if (workflow.root != .object) return error.InvalidWorkflow;

    const input_json = try std.json.Stringify.valueAlloc(allocator, .{
        .task = .{
            .id = claim.task.id,
            .pipeline_id = claim.task.pipeline_id,
            .stage = claim.task.stage,
            .title = claim.task.title,
            .description = claim.task.description,
            .priority = claim.task.priority,
            .task_version = claim.task.task_version,
            .metadata = claim.task.metadata,
        },
        .tracker = .{
            .run_id = claim.run.id,
            .agent_id = cfg.agent_id,
            .agent_role = cfg.agent_role,
            .lease_id = claim.lease_id,
        },
    }, .{});
    defer allocator.free(input_json);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.append(allocator, '{');

    var first = true;
    var iter = workflow.root.object.iterator();
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "success_trigger") or
            std.mem.eql(u8, entry.key_ptr.*, "artifact_kind") or
            std.mem.eql(u8, entry.key_ptr.*, "input"))
        {
            continue;
        }

        if (!first) try buf.append(allocator, ',');
        first = false;
        const key_json = try std.json.Stringify.valueAlloc(allocator, entry.key_ptr.*, .{});
        defer allocator.free(key_json);
        const value_json = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
        defer allocator.free(value_json);
        try buf.appendSlice(allocator, key_json);
        try buf.append(allocator, ':');
        try buf.appendSlice(allocator, value_json);
    }

    if (!first) try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"input\":");
    try buf.appendSlice(allocator, input_json);
    try buf.append(allocator, '}');

    return .{
        .run_body = try buf.toOwnedSlice(allocator),
        .success_trigger = workflow.success_trigger orelse cfg.success_trigger,
        .artifact_kind = workflow.artifact_kind,
    };
}

fn extractFinalOutput(steps: []types.StepRow) ?[]const u8 {
    var idx = steps.len;
    while (idx > 0) {
        idx -= 1;
        if (steps[idx].output_json) |output| {
            return output;
        }
    }
    return null;
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return if (val == .string) val.string else null;
}

fn serializeJsonValue(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const u8 {
    if (value) |v| {
        return std.json.Stringify.valueAlloc(allocator, v, .{});
    }
    return allocator.dupe(u8, "{}");
}

fn lookupGenId(def_ids: []const []const u8, gen_ids: []const []const u8, def_step_id: []const u8) ?[]const u8 {
    for (def_ids, 0..) |id, idx| {
        if (std.mem.eql(u8, id, def_step_id)) return gen_ids[idx];
    }
    return null;
}

fn sleepInterruptible(ms: u32, shutdown_requested: *std.atomic.Value(bool)) void {
    var remaining = ms;
    while (remaining > 0 and !shutdown_requested.load(.acquire)) {
        const chunk = @min(remaining, 250);
        std.Thread.sleep(@as(u64, chunk) * std.time.ns_per_ms);
        remaining -= chunk;
    }
}
