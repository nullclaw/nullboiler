/// DAG Engine — Scheduler Loop
///
/// The engine runs on its own thread, polling the database for active runs
/// and processing their steps according to the DAG dependencies.
///
/// Each tick:
///   1. Get active runs
///   2. For each run, promote pending steps to ready
///   3. Process ready steps by type (task, fan_out, map, reduce, condition, approval)
///   4. Check run completion

const std = @import("std");
const log = std.log.scoped(.engine);

const Store = @import("store.zig").Store;
const types = @import("types.zig");
const ids = @import("ids.zig");
const templates = @import("templates.zig");
const dispatch = @import("dispatch.zig");

// ── Engine ───────────────────────────────────────────────────────────

pub const Engine = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    poll_interval_ns: u64,
    running: std.atomic.Value(bool),

    pub fn init(store: *Store, allocator: std.mem.Allocator, poll_interval_ms: u64) Engine {
        return .{
            .store = store,
            .allocator = allocator,
            .poll_interval_ns = poll_interval_ms * std.time.ns_per_ms,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn stop(self: *Engine) void {
        self.running.store(false, .release);
    }

    pub fn run(self: *Engine) void {
        log.info("engine started", .{});
        while (self.running.load(.acquire)) {
            self.tick() catch |err| {
                log.err("engine tick error: {}", .{err});
            };
            std.Thread.sleep(self.poll_interval_ns);
        }
        log.info("engine stopped", .{});
    }

    // ── tick — single scheduler iteration ────────────────────────────

    fn tick(self: *Engine) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const active_runs = try self.store.getActiveRuns(alloc);
        for (active_runs) |run_row| {
            self.processRun(alloc, run_row) catch |err| {
                log.err("error processing run {s}: {}", .{ run_row.id, err });
            };
        }
    }

    // ── processRun ───────────────────────────────────────────────────

    fn processRun(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow) !void {
        // 1. Get all steps for this run
        const steps = try self.store.getStepsByRun(alloc, run_row.id);

        // 2. Promote pending -> ready: for each pending step, check if
        //    all its deps are completed/skipped.
        for (steps) |step| {
            if (!std.mem.eql(u8, step.status, "pending")) continue;

            const dep_ids = try self.store.getStepDeps(alloc, step.id);
            var all_deps_met = true;

            for (dep_ids) |dep_id| {
                // Find the dep step status from our already-fetched steps
                const dep_status = findStepStatus(steps, dep_id);
                if (dep_status) |ds| {
                    if (!std.mem.eql(u8, ds, "completed") and !std.mem.eql(u8, ds, "skipped")) {
                        all_deps_met = false;
                        break;
                    }
                } else {
                    // Dep step not found — treat as unmet
                    all_deps_met = false;
                    break;
                }
            }

            if (all_deps_met) {
                try self.store.updateStepStatus(step.id, "ready", null, null, null, step.attempt);
                log.info("promoted step {s} to ready", .{step.id});
            }
        }

        // 3. Re-fetch steps to get updated statuses
        const updated_steps = try self.store.getStepsByRun(alloc, run_row.id);

        // 4. Process ready steps based on their type
        for (updated_steps) |step| {
            if (!std.mem.eql(u8, step.status, "ready")) continue;

            if (std.mem.eql(u8, step.type, "task")) {
                self.executeTaskStep(alloc, run_row, step) catch |err| {
                    log.err("error executing task step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "fan_out")) {
                self.executeFanOutStep(alloc, run_row, step) catch |err| {
                    log.err("error executing fan_out step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "map")) {
                self.executeMapStep(alloc, run_row, step) catch |err| {
                    log.err("error executing map step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "reduce")) {
                self.executeReduceStep(alloc, run_row, step, updated_steps) catch |err| {
                    log.err("error executing reduce step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "condition")) {
                self.executeConditionStep(alloc, run_row, step, updated_steps) catch |err| {
                    log.err("error executing condition step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "approval")) {
                self.executeApprovalStep(alloc, run_row, step) catch |err| {
                    log.err("error executing approval step {s}: {}", .{ step.id, err });
                };
            } else {
                log.warn("unknown step type {s} for step {s}", .{ step.type, step.id });
            }
        }

        // 5. Check run completion
        try self.checkRunCompletion(run_row.id, alloc);
    }

    // ── executeTaskStep ──────────────────────────────────────────────

    fn executeTaskStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Get the step's prompt_template from workflow_json
        const prompt_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template") orelse {
            log.warn("no prompt_template for step {s}", .{step.def_step_id});
            return;
        };

        // 2. Build template context
        const ctx = try buildTemplateContext(alloc, run_row, step, self.store);

        // 3. Render prompt
        const rendered_prompt = templates.render(alloc, prompt_template, ctx) catch |err| {
            log.err("template render failed for step {s}: {}", .{ step.id, err });
            try self.store.updateStepStatus(step.id, "failed", null, null, "template render failed", step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            return;
        };

        // 4. Get all workers and build WorkerInfo list
        const workers = try self.store.listWorkers(alloc);
        var worker_infos: std.ArrayListUnmanaged(dispatch.WorkerInfo) = .empty;
        for (workers) |w| {
            const current_tasks = self.store.countRunningStepsByWorker(w.id) catch 0;
            try worker_infos.append(alloc, .{
                .id = w.id,
                .url = w.url,
                .token = w.token,
                .tags_json = w.tags_json,
                .max_concurrent = w.max_concurrent,
                .status = w.status,
                .current_tasks = current_tasks,
            });
        }

        // 5. Parse worker_tags from the step definition
        const required_tags = try getStepTags(alloc, run_row.workflow_json, step.def_step_id);

        // 6. Select an available worker
        const selected_worker = try dispatch.selectWorker(alloc, worker_infos.items, required_tags);
        if (selected_worker == null) {
            // No worker available — leave as "ready", will retry next tick
            log.debug("no worker available for step {s}, will retry", .{step.id});
            return;
        }
        const worker = selected_worker.?;

        // 7. Mark step as "running"
        try self.store.updateStepStatus(step.id, "running", worker.id, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");

        // 8. Dispatch to worker (synchronous/blocking for MVP)
        const result = try dispatch.dispatchStep(alloc, worker.url, worker.token, run_row.id, step.id, rendered_prompt);

        // 9. Handle result
        if (result.success) {
            // Mark step as completed, save output_json
            const output_json = try wrapOutput(alloc, result.output);
            try self.store.updateStepStatus(step.id, "completed", worker.id, output_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            log.info("step {s} completed", .{step.id});
        } else {
            // On failure: retry or fail
            const err_text = result.error_text orelse "dispatch failed";
            if (step.attempt < step.max_attempts) {
                // Increment attempt and set back to "ready"
                try self.store.updateStepStatus(step.id, "ready", null, null, err_text, step.attempt + 1);
                try self.store.insertEvent(run_row.id, step.id, "step.retry", "{}");
                log.info("step {s} will retry (attempt {d}/{d})", .{ step.id, step.attempt + 1, step.max_attempts });
            } else {
                try self.store.updateStepStatus(step.id, "failed", worker.id, null, err_text, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                log.err("step {s} failed: {s}", .{ step.id, err_text });
            }
        }
    }

    // ── executeFanOutStep ────────────────────────────────────────────

    fn executeFanOutStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Parse step definition from workflow_json, get "count"
        const count_val = try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "count") orelse {
            log.warn("no count for fan_out step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing count in fan_out definition", step.attempt);
            return;
        };
        const count: usize = @intCast(count_val);

        // 2. Create N child steps
        for (0..count) |i| {
            const child_id_buf = ids.generateId();
            const child_id = try alloc.dupe(u8, &child_id_buf);
            const child_def_id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ step.def_step_id, i });
            const idx: i64 = @intCast(i);

            try self.store.insertStep(
                child_id,
                run_row.id,
                child_def_id,
                "task",
                "ready",
                step.input_json,
                step.max_attempts,
                step.timeout_ms,
                step.id, // parent_step_id
                idx,
            );
            log.info("created fan_out child step {s} (index {d})", .{ child_id, i });
        }

        // 3. Mark fan_out step as "completed"
        try self.store.updateStepStatus(step.id, "completed", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
        log.info("fan_out step {s} completed, created {d} children", .{ step.id, count });
    }

    // ── executeMapStep ───────────────────────────────────────────────

    fn executeMapStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Parse step definition, get "items_from" (e.g. "$.topics")
        const items_from = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "items_from") orelse {
            log.warn("no items_from for map step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing items_from in map definition", step.attempt);
            return;
        };

        // 2. Resolve items_from against run.input_json — extract the array
        //    items_from format: "$.field_name"
        const field_name = if (std.mem.startsWith(u8, items_from, "$."))
            items_from[2..]
        else
            items_from;

        const items = try extractJsonArray(alloc, run_row.input_json, field_name) orelse {
            log.warn("items_from field '{s}' not found or not an array in input", .{field_name});
            try self.store.updateStepStatus(step.id, "failed", null, null, "items_from field not found or not an array", step.attempt);
            return;
        };

        // 3. For each item in the array, create a child step
        for (items, 0..) |item, i| {
            const child_id_buf = ids.generateId();
            const child_id = try alloc.dupe(u8, &child_id_buf);
            const child_def_id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ step.def_step_id, i });
            const idx: i64 = @intCast(i);

            // Store the item as input_json for the child
            const item_json = try wrapItemJson(alloc, item);

            try self.store.insertStep(
                child_id,
                run_row.id,
                child_def_id,
                "task",
                "ready",
                item_json,
                step.max_attempts,
                step.timeout_ms,
                step.id, // parent_step_id
                idx,
            );
            log.info("created map child step {s} for item {d}", .{ child_id, i });
        }

        // 4. Mark map step as "completed"
        try self.store.updateStepStatus(step.id, "completed", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
        log.info("map step {s} completed, created {d} children", .{ step.id, items.len });
    }

    // ── executeReduceStep ────────────────────────────────────────────

    fn executeReduceStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, all_steps: []const types.StepRow) !void {
        // 1. Find the dependency step (the fan_out or map step this depends on)
        const dep_ids = try self.store.getStepDeps(alloc, step.id);
        if (dep_ids.len == 0) {
            log.warn("reduce step {s} has no dependencies", .{step.id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "reduce step has no dependencies", step.attempt);
            return;
        }

        // The reduce depends on a fan_out/map step; find it
        const dep_step_id = dep_ids[0];

        // 2. Get all child steps of that dependency
        const children = try self.store.getChildSteps(alloc, dep_step_id);

        if (children.len == 0) {
            // If the dep is a fan_out/map that hasn't spawned children yet, wait
            // Check if dep step itself is completed
            const dep_status = findStepStatus(all_steps, dep_step_id);
            if (dep_status == null or !std.mem.eql(u8, dep_status.?, "completed")) {
                // Dep not completed yet, stay ready
                return;
            }
            // Dep completed but no children? Odd, proceed with empty outputs
        }

        // 3. Check if ALL children are completed
        var all_done = true;
        for (children) |child| {
            if (!std.mem.eql(u8, child.status, "completed") and !std.mem.eql(u8, child.status, "skipped")) {
                all_done = false;
                break;
            }
        }
        if (!all_done) {
            // Not all children done, leave reduce as "ready", try next tick
            return;
        }

        // 4. Collect all child outputs into an array
        var child_outputs: std.ArrayListUnmanaged([]const u8) = .empty;
        for (children) |child| {
            if (child.output_json) |oj| {
                // Extract "output" field from JSON, or use the raw JSON
                const extracted = extractOutputField(alloc, oj) catch oj;
                try child_outputs.append(alloc, extracted);
            } else {
                try child_outputs.append(alloc, "");
            }
        }

        // 5. Build template context with outputs array
        // Find the dep step's def_step_id for template referencing
        const dep_def_step_id = findStepDefId(all_steps, dep_step_id) orelse step.def_step_id;

        const step_output = templates.Context.StepOutput{
            .step_id = dep_def_step_id,
            .output = null,
            .outputs = child_outputs.items,
        };

        const prompt_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template") orelse {
            // No template — just collect outputs and mark completed
            const outputs_json = try serializeStringArray(alloc, child_outputs.items);
            try self.store.updateStepStatus(step.id, "completed", null, outputs_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            return;
        };

        const ctx = templates.Context{
            .input_json = run_row.input_json,
            .step_outputs = &.{step_output},
            .item = null,
        };

        // 6. Render template
        const rendered_prompt = templates.render(alloc, prompt_template, ctx) catch |err| {
            log.err("template render failed for reduce step {s}: {}", .{ step.id, err });
            try self.store.updateStepStatus(step.id, "failed", null, null, "template render failed", step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            return;
        };

        // 7. Get workers and dispatch
        const workers = try self.store.listWorkers(alloc);
        var worker_infos: std.ArrayListUnmanaged(dispatch.WorkerInfo) = .empty;
        for (workers) |w| {
            const current_tasks = self.store.countRunningStepsByWorker(w.id) catch 0;
            try worker_infos.append(alloc, .{
                .id = w.id,
                .url = w.url,
                .token = w.token,
                .tags_json = w.tags_json,
                .max_concurrent = w.max_concurrent,
                .status = w.status,
                .current_tasks = current_tasks,
            });
        }

        const required_tags = try getStepTags(alloc, run_row.workflow_json, step.def_step_id);
        const selected_worker = try dispatch.selectWorker(alloc, worker_infos.items, required_tags);
        if (selected_worker == null) {
            log.debug("no worker available for reduce step {s}, will retry", .{step.id});
            return;
        }
        const worker = selected_worker.?;

        try self.store.updateStepStatus(step.id, "running", worker.id, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");

        const result = try dispatch.dispatchStep(alloc, worker.url, worker.token, run_row.id, step.id, rendered_prompt);

        if (result.success) {
            const output_json = try wrapOutput(alloc, result.output);
            try self.store.updateStepStatus(step.id, "completed", worker.id, output_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            log.info("reduce step {s} completed", .{step.id});
        } else {
            const err_text = result.error_text orelse "dispatch failed";
            if (step.attempt < step.max_attempts) {
                try self.store.updateStepStatus(step.id, "ready", null, null, err_text, step.attempt + 1);
                try self.store.insertEvent(run_row.id, step.id, "step.retry", "{}");
            } else {
                try self.store.updateStepStatus(step.id, "failed", worker.id, null, err_text, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            }
        }
    }

    // ── executeConditionStep ─────────────────────────────────────────

    fn executeConditionStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, all_steps: []const types.StepRow) !void {
        // 1. Get the dependency step's output
        const dep_ids = try self.store.getStepDeps(alloc, step.id);
        if (dep_ids.len == 0) {
            log.warn("condition step {s} has no dependencies", .{step.id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "condition step has no dependencies", step.attempt);
            return;
        }

        const dep_step_id = dep_ids[0];
        const dep_output = findStepOutput(all_steps, dep_step_id) orelse "";

        // 2. Parse the "expression" from step definition
        const expression = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "expression") orelse "true";

        // 3. Evaluate: for MVP, support simple "contains" check
        //    Expression format: check if the dependency output contains a certain substring
        //    If expression is "true", always take true branch
        //    Otherwise, check if dep output contains the expression text
        const condition_met = if (std.mem.eql(u8, expression, "true"))
            true
        else if (std.mem.eql(u8, expression, "false"))
            false
        else
            std.mem.indexOf(u8, dep_output, expression) != null;

        // 4. Determine branch
        const true_target = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "true_target");
        const false_target = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "false_target");

        // 5. For the losing branch target: mark steps as "skipped"
        if (condition_met) {
            // Skip the false branch target
            if (false_target) |target_def_id| {
                try self.skipStepByDefId(alloc, all_steps, run_row.id, target_def_id);
            }
        } else {
            // Skip the true branch target
            if (true_target) |target_def_id| {
                try self.skipStepByDefId(alloc, all_steps, run_row.id, target_def_id);
            }
        }

        // 6. Mark condition step as "completed"
        const branch_result = if (condition_met) "true" else "false";
        const output_json = try std.fmt.allocPrint(alloc, "{{\"branch\":\"{s}\"}}", .{branch_result});
        try self.store.updateStepStatus(step.id, "completed", null, output_json, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
        log.info("condition step {s} evaluated to {s}", .{ step.id, branch_result });
    }

    // ── executeApprovalStep ──────────────────────────────────────────

    fn executeApprovalStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        _ = alloc;
        // 1. Mark step as "waiting_approval"
        try self.store.updateStepStatus(step.id, "waiting_approval", null, null, null, step.attempt);
        // 2. Insert event
        try self.store.insertEvent(run_row.id, step.id, "step.waiting_approval", "{}");
        log.info("approval step {s} waiting for approval", .{step.id});
    }

    // ── checkRunCompletion ───────────────────────────────────────────

    fn checkRunCompletion(self: *Engine, run_id: []const u8, alloc: std.mem.Allocator) !void {
        const steps = try self.store.getStepsByRun(alloc, run_id);
        var all_terminal = true;
        var any_failed = false;
        for (steps) |step| {
            if (std.mem.eql(u8, step.status, "completed") or std.mem.eql(u8, step.status, "skipped")) continue;
            if (std.mem.eql(u8, step.status, "failed")) {
                any_failed = true;
                continue;
            }
            if (std.mem.eql(u8, step.status, "waiting_approval")) {
                all_terminal = false;
                continue;
            }
            all_terminal = false; // pending, ready, running
        }
        if (all_terminal and !any_failed) {
            try self.store.updateRunStatus(run_id, "completed", null);
            try self.store.insertEvent(run_id, null, "run.completed", "{}");
            log.info("run {s} completed", .{run_id});
        } else if (all_terminal and any_failed) {
            try self.store.updateRunStatus(run_id, "failed", "one or more steps failed");
            try self.store.insertEvent(run_id, null, "run.failed", "{}");
            log.info("run {s} failed", .{run_id});
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────

    fn skipStepByDefId(self: *Engine, alloc: std.mem.Allocator, all_steps: []const types.StepRow, run_id: []const u8, target_def_id: []const u8) !void {
        for (all_steps) |s| {
            if (std.mem.eql(u8, s.def_step_id, target_def_id)) {
                try self.store.updateStepStatus(s.id, "skipped", null, null, null, s.attempt);
                try self.store.insertEvent(run_id, s.id, "step.skipped", "{}");
                log.info("skipped step {s} (def: {s})", .{ s.id, target_def_id });
                break;
            }
        }
        _ = alloc;
    }
};

// ── Free functions (workflow JSON helpers) ────────────────────────────

/// Parse workflow_json to find a step definition by def_step_id and return a string field.
fn getStepField(alloc: std.mem.Allocator, workflow_json: []const u8, def_step_id: []const u8, field: []const u8) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, workflow_json, .{}) catch {
        return null;
    };
    // Note: do not deinit here — the alloc is an arena

    const root = parsed.value;
    if (root != .object) return null;

    const steps_val = root.object.get("steps") orelse return null;
    if (steps_val != .array) return null;

    for (steps_val.array.items) |step_val| {
        if (step_val != .object) continue;
        const step_obj = step_val.object;

        const id_val = step_obj.get("id") orelse continue;
        if (id_val != .string) continue;
        if (!std.mem.eql(u8, id_val.string, def_step_id)) continue;

        const field_val = step_obj.get(field) orelse return null;
        if (field_val == .string) {
            return try alloc.dupe(u8, field_val.string);
        }
        return null;
    }
    return null;
}

/// Parse workflow_json to find a step definition by def_step_id and return an integer field.
fn getStepFieldInt(alloc: std.mem.Allocator, workflow_json: []const u8, def_step_id: []const u8, field: []const u8) !?i64 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, workflow_json, .{}) catch {
        return null;
    };

    const root = parsed.value;
    if (root != .object) return null;

    const steps_val = root.object.get("steps") orelse return null;
    if (steps_val != .array) return null;

    for (steps_val.array.items) |step_val| {
        if (step_val != .object) continue;
        const step_obj = step_val.object;

        const id_val = step_obj.get("id") orelse continue;
        if (id_val != .string) continue;
        if (!std.mem.eql(u8, id_val.string, def_step_id)) continue;

        const field_val = step_obj.get(field) orelse return null;
        if (field_val == .integer) return field_val.integer;
        return null;
    }
    return null;
}

/// Parse workflow_json to find a step definition and get its worker_tags.
fn getStepTags(alloc: std.mem.Allocator, workflow_json: []const u8, def_step_id: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, workflow_json, .{}) catch {
        return &.{};
    };

    const root = parsed.value;
    if (root != .object) return &.{};

    const steps_val = root.object.get("steps") orelse return &.{};
    if (steps_val != .array) return &.{};

    for (steps_val.array.items) |step_val| {
        if (step_val != .object) continue;
        const step_obj = step_val.object;

        const id_val = step_obj.get("id") orelse continue;
        if (id_val != .string) continue;
        if (!std.mem.eql(u8, id_val.string, def_step_id)) continue;

        const tags_val = step_obj.get("worker_tags") orelse return &.{};
        if (tags_val != .array) return &.{};

        var tags: std.ArrayListUnmanaged([]const u8) = .empty;
        for (tags_val.array.items) |tag_item| {
            if (tag_item == .string) {
                try tags.append(alloc, try alloc.dupe(u8, tag_item.string));
            }
        }
        return tags.toOwnedSlice(alloc);
    }
    return &.{};
}

/// Build a template Context from a run's input and completed step outputs.
fn buildTemplateContext(alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, store: *Store) !templates.Context {
    // Get all steps for this run to collect outputs
    const all_steps = try store.getStepsByRun(alloc, run_row.id);

    var step_outputs: std.ArrayListUnmanaged(templates.Context.StepOutput) = .empty;
    for (all_steps) |s| {
        if (std.mem.eql(u8, s.status, "completed")) {
            // Check if this step has children (fan_out/map)
            if (std.mem.eql(u8, s.type, "fan_out") or std.mem.eql(u8, s.type, "map")) {
                // Collect child outputs
                const children = try store.getChildSteps(alloc, s.id);
                var child_outputs: std.ArrayListUnmanaged([]const u8) = .empty;
                for (children) |child| {
                    if (child.output_json) |oj| {
                        const extracted = extractOutputField(alloc, oj) catch oj;
                        try child_outputs.append(alloc, extracted);
                    }
                }
                try step_outputs.append(alloc, .{
                    .step_id = s.def_step_id,
                    .output = null,
                    .outputs = child_outputs.items,
                });
            } else {
                // Regular step — single output
                const output = if (s.output_json) |oj|
                    (extractOutputField(alloc, oj) catch oj)
                else
                    null;
                try step_outputs.append(alloc, .{
                    .step_id = s.def_step_id,
                    .output = output,
                    .outputs = null,
                });
            }
        }
    }

    // Determine item context (for map child steps)
    const item: ?[]const u8 = if (step.parent_step_id != null) blk: {
        // This is a child step of a map/fan_out — extract item from input_json
        break :blk extractItemFromInput(alloc, step.input_json) catch null;
    } else null;

    return templates.Context{
        .input_json = run_row.input_json,
        .step_outputs = step_outputs.items,
        .item = item,
    };
}

/// Find a step's status by ID from a list of steps.
fn findStepStatus(steps: []const types.StepRow, step_id: []const u8) ?[]const u8 {
    for (steps) |s| {
        if (std.mem.eql(u8, s.id, step_id)) return s.status;
    }
    return null;
}

/// Find a step's def_step_id by step ID from a list of steps.
fn findStepDefId(steps: []const types.StepRow, step_id: []const u8) ?[]const u8 {
    for (steps) |s| {
        if (std.mem.eql(u8, s.id, step_id)) return s.def_step_id;
    }
    return null;
}

/// Find a step's output_json by step ID from a list of steps.
fn findStepOutput(steps: []const types.StepRow, step_id: []const u8) ?[]const u8 {
    for (steps) |s| {
        if (std.mem.eql(u8, s.id, step_id)) {
            if (s.output_json) |oj| {
                return oj;
            }
            return null;
        }
    }
    return null;
}

/// Wrap a raw output string in a JSON object: {"output": "..."}
fn wrapOutput(alloc: std.mem.Allocator, output: []const u8) ![]const u8 {
    // Use JSON serializer for proper escaping
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, "{\"output\":");

    // JSON-encode the output string
    try out.append(alloc, '"');
    for (output) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// Wrap an item value in a JSON object: {"item": "..."}
fn wrapItemJson(alloc: std.mem.Allocator, item: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(alloc, "{\"item\":");

    try out.append(alloc, '"');
    for (item) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    try out.append(alloc, '"');
    try out.append(alloc, '}');
    return try out.toOwnedSlice(alloc);
}

/// Extract the "output" field from a JSON string like {"output": "..."}.
fn extractOutputField(alloc: std.mem.Allocator, json_str: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_str, .{});
    const root = parsed.value;
    if (root != .object) return json_str;
    const output_val = root.object.get("output") orelse return json_str;
    if (output_val == .string) return try alloc.dupe(u8, output_val.string);
    return json_str;
}

/// Extract an array of strings from a JSON field.
fn extractJsonArray(alloc: std.mem.Allocator, json_str: []const u8, field_name: []const u8) !?[][]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, json_str, .{}) catch {
        return null;
    };
    const root = parsed.value;
    if (root != .object) return null;

    const arr_val = root.object.get(field_name) orelse return null;
    if (arr_val != .array) return null;

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    for (arr_val.array.items) |item| {
        switch (item) {
            .string => |s| try items.append(alloc, try alloc.dupe(u8, s)),
            else => {
                // Serialize non-string values as JSON
                var json_out: std.io.Writer.Allocating = .init(alloc);
                var jw: std.json.Stringify = .{ .writer = &json_out.writer };
                jw.write(item) catch continue;
                const slice = json_out.toOwnedSlice() catch continue;
                try items.append(alloc, slice);
            },
        }
    }
    const result = try items.toOwnedSlice(alloc);
    return result;
}

/// Serialize an array of strings to a JSON array string.
fn serializeStringArray(alloc: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(alloc, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(alloc, ',');
        try buf.append(alloc, '"');
        for (item) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice(alloc, "\\\""),
                '\\' => try buf.appendSlice(alloc, "\\\\"),
                '\n' => try buf.appendSlice(alloc, "\\n"),
                '\r' => try buf.appendSlice(alloc, "\\r"),
                '\t' => try buf.appendSlice(alloc, "\\t"),
                else => try buf.append(alloc, ch),
            }
        }
        try buf.append(alloc, '"');
    }
    try buf.append(alloc, ']');
    return try buf.toOwnedSlice(alloc);
}

/// Extract the "item" field from input_json, or return the whole input_json
/// as item text if it's a simple value.
fn extractItemFromInput(alloc: std.mem.Allocator, input_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, input_json, .{}) catch {
        return input_json;
    };
    const root = parsed.value;
    if (root != .object) return input_json;
    const item_val = root.object.get("item") orelse return input_json;
    if (item_val == .string) return try alloc.dupe(u8, item_val.string);
    return input_json;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "Engine: init and stop" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var engine = Engine.init(&store, allocator, 500);
    try std.testing.expect(engine.running.load(.acquire));
    engine.stop();
    try std.testing.expect(!engine.running.load(.acquire));
}

test "Engine: tick with no active runs" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var engine = Engine.init(&store, allocator, 500);
    // Should not error — no active runs
    try engine.tick();
}

test "Engine: checkRunCompletion marks run completed" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Insert a run
    try store.insertRun("r1", "running", "{\"steps\":[]}", "{}", "[]");

    // Insert a completed step
    try store.insertStep("s1", "r1", "step1", "task", "completed", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try engine.checkRunCompletion("r1", arena.allocator());

    // Verify run status is "completed"
    const run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("completed", run.status);
}

test "Engine: checkRunCompletion marks run failed" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("r1", "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertStep("s1", "r1", "step1", "task", "completed", "{}", 1, null, null, null);
    try store.insertStep("s2", "r1", "step2", "task", "failed", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try engine.checkRunCompletion("r1", arena.allocator());

    const run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("failed", run.status);
}

test "Engine: checkRunCompletion does not complete with pending steps" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("r1", "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertStep("s1", "r1", "step1", "task", "completed", "{}", 1, null, null, null);
    try store.insertStep("s2", "r1", "step2", "task", "pending", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try engine.checkRunCompletion("r1", arena.allocator());

    // Run should still be "running"
    const run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("running", run.status);
}

test "Engine: pending to ready promotion" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"hello"},{"id":"s2","type":"task","prompt_template":"world","depends_on":["s1"]}]}
    ;
    try store.insertRun("r1", "running", wf, "{}", "[]");

    // s1 is completed, s2 is pending and depends on s1
    try store.insertStep("step1", "r1", "s1", "task", "completed", "{}", 1, null, null, null);
    try store.insertStep("step2", "r1", "s2", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step2", "step1");

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Get run row
    const run_row = (try store.getRun(arena.allocator(), "r1")).?;

    // processRun should promote step2 from pending to ready
    try engine.processRun(arena.allocator(), run_row);

    // Re-fetch step2
    const step2 = (try store.getStep(arena.allocator(), "step2")).?;
    // It should be promoted to "ready" (not "pending")
    // Note: since there are no workers, the task step won't actually execute,
    // so it stays at "ready"
    try std.testing.expectEqualStrings("ready", step2.status);
}

test "Engine: approval step sets waiting_approval" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"approve1","type":"approval"}]}
    ;
    try store.insertRun("r1", "running", wf, "{}", "[]");
    try store.insertStep("step1", "r1", "approve1", "approval", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const step = (try store.getStep(arena.allocator(), "step1")).?;
    try std.testing.expectEqualStrings("waiting_approval", step.status);
}

test "Engine: fan_out creates child steps" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"fan1","type":"fan_out","count":3}]}
    ;
    try store.insertRun("r1", "running", wf, "{}", "[]");
    try store.insertStep("step1", "r1", "fan1", "fan_out", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // fan_out step should be completed
    const step = (try store.getStep(arena.allocator(), "step1")).?;
    try std.testing.expectEqualStrings("completed", step.status);

    // Should have created 3 child steps
    const children = try store.getChildSteps(arena.allocator(), "step1");
    try std.testing.expectEqual(@as(usize, 3), children.len);

    // Each child should be "ready" and type "task"
    for (children) |child| {
        try std.testing.expectEqualStrings("ready", child.status);
        try std.testing.expectEqualStrings("task", child.type);
    }
}

test "Engine: map creates child steps from input array" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"map1","type":"map","items_from":"$.topics"}]}
    ;
    const input =
        \\{"topics":["AI","ML","DL"]}
    ;
    try store.insertRun("r1", "running", wf, input, "[]");
    try store.insertStep("step1", "r1", "map1", "map", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // map step should be completed
    const step = (try store.getStep(arena.allocator(), "step1")).?;
    try std.testing.expectEqualStrings("completed", step.status);

    // Should have created 3 child steps
    const children = try store.getChildSteps(arena.allocator(), "step1");
    try std.testing.expectEqual(@as(usize, 3), children.len);
}

test "getStepField extracts prompt_template" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"steps":[{"id":"research","type":"task","prompt_template":"Research {{input.topic}}"}]}
    ;
    const result = try getStepField(arena.allocator(), wf, "research", "prompt_template");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("Research {{input.topic}}", result.?);
}

test "getStepField returns null for missing step" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"steps":[{"id":"research","type":"task"}]}
    ;
    const result = try getStepField(arena.allocator(), wf, "nonexistent", "prompt_template");
    try std.testing.expect(result == null);
}

test "getStepFieldInt extracts count" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"steps":[{"id":"fan1","type":"fan_out","count":5}]}
    ;
    const result = try getStepFieldInt(arena.allocator(), wf, "fan1", "count");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 5), result.?);
}

test "extractJsonArray extracts string array" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const json =
        \\{"topics":["AI","ML","DL"]}
    ;
    const result = try extractJsonArray(arena.allocator(), json, "topics");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(usize, 3), result.?.len);
    try std.testing.expectEqualStrings("AI", result.?[0]);
    try std.testing.expectEqualStrings("ML", result.?[1]);
    try std.testing.expectEqualStrings("DL", result.?[2]);
}

test "wrapOutput creates valid JSON" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try wrapOutput(arena.allocator(), "hello world");
    try std.testing.expectEqualStrings("{\"output\":\"hello world\"}", result);
}

test "wrapOutput escapes special characters" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try wrapOutput(arena.allocator(), "line1\nline2");
    try std.testing.expectEqualStrings("{\"output\":\"line1\\nline2\"}", result);
}

test "findStepStatus finds matching step" {
    const steps = [_]types.StepRow{
        makeTestStepRow("s1", "completed"),
        makeTestStepRow("s2", "pending"),
    };
    const status = findStepStatus(&steps, "s2");
    try std.testing.expect(status != null);
    try std.testing.expectEqualStrings("pending", status.?);
}

test "findStepStatus returns null for missing step" {
    const steps = [_]types.StepRow{
        makeTestStepRow("s1", "completed"),
    };
    const status = findStepStatus(&steps, "s999");
    try std.testing.expect(status == null);
}

fn makeTestStepRow(id: []const u8, status: []const u8) types.StepRow {
    return .{
        .id = id,
        .run_id = "r1",
        .def_step_id = id,
        .type = "task",
        .status = status,
        .worker_id = null,
        .input_json = "{}",
        .output_json = null,
        .error_text = null,
        .attempt = 1,
        .max_attempts = 1,
        .timeout_ms = null,
        .parent_step_id = null,
        .item_index = null,
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .started_at_ms = null,
        .ended_at_ms = null,
    };
}
