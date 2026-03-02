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
const callbacks = @import("callbacks.zig");
const metrics_mod = @import("metrics.zig");

// ── Engine ───────────────────────────────────────────────────────────

pub const RuntimeConfig = struct {
    health_check_interval_ms: i64 = 30_000,
    worker_failure_threshold: i64 = 3,
    worker_circuit_breaker_ms: i64 = 60_000,
    retry_base_delay_ms: i64 = 1_000,
    retry_max_delay_ms: i64 = 30_000,
    retry_jitter_ms: i64 = 250,
    retry_max_elapsed_ms: i64 = 900_000,
};

pub const Engine = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    poll_interval_ns: u64,
    running: std.atomic.Value(bool),
    runtime_cfg: RuntimeConfig,
    next_health_check_at_ms: i64,
    metrics: ?*metrics_mod.Metrics,

    const TaskPromptSource = union(enum) {
        rendered: []const u8,
        template: []const u8,
    };

    pub fn init(store: *Store, allocator: std.mem.Allocator, poll_interval_ms: u64) Engine {
        return .{
            .store = store,
            .allocator = allocator,
            .poll_interval_ns = poll_interval_ms * std.time.ns_per_ms,
            .running = std.atomic.Value(bool).init(true),
            .runtime_cfg = .{},
            .next_health_check_at_ms = 0,
            .metrics = null,
        };
    }

    pub fn configure(self: *Engine, runtime_cfg: RuntimeConfig, metrics: ?*metrics_mod.Metrics) void {
        self.runtime_cfg = runtime_cfg;
        self.metrics = metrics;
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

        const now_ms = ids.nowMs();
        if (now_ms >= self.next_health_check_at_ms) {
            self.runWorkerHealthChecks(alloc, now_ms) catch |err| {
                log.warn("worker health check failed: {}", .{err});
            };
            self.next_health_check_at_ms = now_ms + self.runtime_cfg.health_check_interval_ms;
        }

        const active_runs = try self.store.getActiveRuns(alloc);
        for (active_runs) |run_row| {
            self.processRun(alloc, run_row) catch |err| {
                log.err("error processing run {s}: {}", .{ run_row.id, err });
            };
        }
    }

    fn runWorkerHealthChecks(self: *Engine, alloc: std.mem.Allocator, now_ms: i64) !void {
        const workers = try self.store.listWorkers(alloc);
        for (workers) |worker| {
            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_health_checks_total);
            }

            if (std.mem.eql(u8, worker.status, "draining")) continue;
            if (std.mem.eql(u8, worker.status, "dead")) {
                if (worker.circuit_open_until_ms) |until| {
                    if (until > now_ms) continue;
                }
            }

            const healthy = dispatch.probeWorker(alloc, worker.url, worker.protocol);
            if (healthy) {
                self.store.markWorkerSuccess(worker.id, now_ms) catch {};
                continue;
            }

            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_health_failures_total);
            }
            const circuit_until = now_ms + self.runtime_cfg.worker_circuit_breaker_ms;
            self.store.markWorkerFailure(
                worker.id,
                "health check failed",
                now_ms,
                self.runtime_cfg.worker_failure_threshold,
                circuit_until,
            ) catch {};
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
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeFanOutStep(alloc, run_row, step) catch |err| {
                    log.err("error executing fan_out step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "map")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeMapStep(alloc, run_row, step) catch |err| {
                    log.err("error executing map step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "reduce")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeReduceStep(alloc, run_row, step, updated_steps) catch |err| {
                    log.err("error executing reduce step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "condition")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeConditionStep(alloc, run_row, step, updated_steps) catch |err| {
                    log.err("error executing condition step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "approval")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeApprovalStep(alloc, run_row, step) catch |err| {
                    log.err("error executing approval step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "transform")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeTransformStep(alloc, run_row, step) catch |err| {
                    log.err("error executing transform step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "wait")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeWaitStep(alloc, run_row, step) catch |err| {
                    log.err("error executing wait step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "router")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeRouterStep(alloc, run_row, step, updated_steps) catch |err| {
                    log.err("error executing router step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "loop")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeLoopStep(alloc, run_row, step) catch |err| {
                    log.err("error executing loop step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "sub_workflow")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeSubWorkflowStep(alloc, run_row, step) catch |err| {
                    log.err("error executing sub_workflow step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "debate")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeDebateStep(alloc, run_row, step) catch |err| {
                    log.err("error executing debate step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "group_chat")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeGroupChatStep(alloc, run_row, step) catch |err| {
                    log.err("error executing group_chat step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "saga")) {
                const claimed = self.store.claimReadyStep(step.id, null, ids.nowMs()) catch false;
                if (!claimed) continue;
                self.executeSagaStep(alloc, run_row, step) catch |err| {
                    log.err("error executing saga step {s}: {}", .{ step.id, err });
                };
            } else {
                log.warn("unknown step type {s} for step {s}", .{ step.type, step.id });
            }
        }

        // 4b. Check running steps that need tick-based polling
        for (updated_steps) |step| {
            if (!std.mem.eql(u8, step.status, "running")) continue;
            if (std.mem.eql(u8, step.type, "wait")) {
                self.executeWaitStep(alloc, run_row, step) catch |err| {
                    log.err("error polling wait step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "loop")) {
                self.pollRunningLoopStep(alloc, run_row, step) catch |err| {
                    log.err("error polling loop step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "sub_workflow")) {
                self.pollRunningSubWorkflowStep(alloc, run_row, step) catch |err| {
                    log.err("error polling sub_workflow step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "debate")) {
                self.pollRunningDebateStep(alloc, run_row, step) catch |err| {
                    log.err("error polling debate step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "group_chat")) {
                self.pollRunningGroupChatStep(alloc, run_row, step) catch |err| {
                    log.err("error polling group_chat step {s}: {}", .{ step.id, err });
                };
            } else if (std.mem.eql(u8, step.type, "saga")) {
                self.pollRunningSagaStep(alloc, run_row, step) catch |err| {
                    log.err("error polling saga step {s}: {}", .{ step.id, err });
                };
            }
        }

        // 5. Check run completion
        try self.checkRunCompletion(run_row.id, alloc);
    }

    // ── executeTaskStep ──────────────────────────────────────────────

    fn executeTaskStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        if (step.next_attempt_at_ms) |next_attempt| {
            if (ids.nowMs() < next_attempt) return;
        }

        // 1. Resolve prompt source for this task step.
        const prompt_source = try self.resolveTaskPromptSource(alloc, run_row, step) orelse {
            log.warn("no prompt_template for step {s}", .{step.def_step_id});
            return;
        };

        // 2. Build final prompt.
        const rendered_prompt = switch (prompt_source) {
            .rendered => |prompt| prompt,
            .template => |prompt_template| blk: {
                const ctx = try buildTemplateContext(alloc, run_row, step, self.store);
                break :blk templates.render(alloc, prompt_template, ctx) catch |err| {
                    log.err("template render failed for step {s}: {}", .{ step.id, err });
                    try self.store.updateStepStatus(step.id, "failed", null, null, "template render failed", step.attempt);
                    try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                    return;
                };
            },
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
                .protocol = w.protocol,
                .model = w.model,
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

        // 7. Atomically claim the step to avoid duplicate dispatch across instances.
        const claim_ts = ids.nowMs();
        const claimed = try self.store.claimReadyStep(step.id, worker.id, claim_ts);
        if (!claimed) {
            return;
        }
        if (self.metrics) |m| {
            metrics_mod.Metrics.incr(&m.steps_claimed_total);
        }
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");

        // 8. Dispatch to worker with handoff support
        var current_worker = worker;
        var current_prompt = rendered_prompt;
        var handoff_count: u32 = 0;
        const max_handoffs: u32 = 5;

        var final_result: dispatch.DispatchResult = undefined;

        while (true) {
            final_result = try dispatch.dispatchStep(
                alloc,
                current_worker.url,
                current_worker.token,
                current_worker.protocol,
                current_worker.model,
                run_row.id,
                step.id,
                current_prompt,
            );

            if (!final_result.success) break;

            // Check for handoff_to in the output
            const handoff_target = extractHandoffTarget(alloc, final_result.output);
            if (handoff_target == null) break; // Normal completion

            handoff_count += 1;
            if (handoff_count >= max_handoffs) {
                final_result = .{
                    .output = "",
                    .success = false,
                    .error_text = "handoff chain limit exceeded (max 5)",
                };
                break;
            }

            // Log the handoff event
            const handoff_event = try std.fmt.allocPrint(alloc, "{{\"handoff_from\":\"{s}\",\"handoff_to_tags\":\"{s}\"}}", .{ current_worker.id, handoff_target.?.tags_str });
            try self.store.insertEvent(run_row.id, step.id, "step.handoff", handoff_event);
            log.info("step {s} handoff #{d} from worker {s}", .{ step.id, handoff_count, current_worker.id });

            // Select new worker by handoff tags
            const new_worker = try dispatch.selectWorker(alloc, worker_infos.items, handoff_target.?.tags);
            if (new_worker == null) {
                final_result = .{
                    .output = "",
                    .success = false,
                    .error_text = "no worker available for handoff",
                };
                break;
            }
            current_worker = new_worker.?;

            // Build handoff prompt with message
            if (handoff_target.?.message) |msg| {
                current_prompt = msg;
            }
            // Otherwise reuse current_prompt
        }

        // 9. Handle result
        if (final_result.success) {
            // Mark step as completed, save output_json
            const output_json = try wrapOutput(alloc, final_result.output);
            try self.store.updateStepStatus(step.id, "completed", current_worker.id, output_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            try self.store.markWorkerSuccess(current_worker.id, ids.nowMs());
            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_success_total);
            }
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output_json, self.metrics);
            log.info("step {s} completed", .{step.id});
        } else {
            // On failure: retry or fail
            const err_text = final_result.error_text orelse "dispatch failed";
            const now_ms = ids.nowMs();
            const circuit_until = now_ms + self.runtime_cfg.worker_circuit_breaker_ms;
            try self.store.markWorkerFailure(
                current_worker.id,
                err_text,
                now_ms,
                self.runtime_cfg.worker_failure_threshold,
                circuit_until,
            );
            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_failure_total);
            }

            if (step.attempt < step.max_attempts) {
                const elapsed_ms = now_ms - step.created_at_ms;
                if (elapsed_ms > self.runtime_cfg.retry_max_elapsed_ms) {
                    const elapsed_err = try std.fmt.allocPrint(alloc, "retry max elapsed exceeded ({d}ms)", .{self.runtime_cfg.retry_max_elapsed_ms});
                    try self.store.updateStepStatus(step.id, "failed", current_worker.id, null, elapsed_err, step.attempt);
                    try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
                    log.err("step {s} failed: {s}", .{ step.id, elapsed_err });
                    return;
                }

                const delay_ms = computeRetryDelayMs(self.runtime_cfg, step, now_ms);
                const next_attempt_ms = now_ms + delay_ms;
                try self.store.scheduleStepRetry(step.id, next_attempt_ms, step.attempt + 1, err_text);
                const retry_event = try std.fmt.allocPrint(alloc, "{{\"next_attempt_at_ms\":{d},\"delay_ms\":{d}}}", .{ next_attempt_ms, delay_ms });
                try self.store.insertEvent(run_row.id, step.id, "step.retry", retry_event);
                if (self.metrics) |m| {
                    metrics_mod.Metrics.incr(&m.steps_retry_scheduled_total);
                }
                log.info("step {s} will retry (attempt {d}/{d}, delay={d}ms)", .{ step.id, step.attempt + 1, step.max_attempts, delay_ms });
            } else {
                try self.store.updateStepStatus(step.id, "failed", current_worker.id, null, err_text, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
                log.err("step {s} failed: {s}", .{ step.id, err_text });
            }
        }
    }

    fn resolveTaskPromptSource(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !?TaskPromptSource {
        // Explicit rendered_prompt is highest priority for generated children
        // (for example debate judge prompts).
        if (extractRenderedPromptFromInput(alloc, step.input_json)) |rendered_prompt| {
            return .{ .rendered = rendered_prompt };
        }

        // Normal task step definition prompt.
        if (try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template")) |tpl| {
            return .{ .template = tpl };
        }

        // Fallback for generated child tasks that should reuse parent prompt template.
        if (step.parent_step_id) |parent_id| {
            if (try self.store.getStep(alloc, parent_id)) |parent_step| {
                if (try getStepField(alloc, run_row.workflow_json, parent_step.def_step_id, "prompt_template")) |parent_tpl| {
                    return .{ .template = parent_tpl };
                }
            }
        }

        return null;
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
                .protocol = w.protocol,
                .model = w.model,
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

        const result = try dispatch.dispatchStep(
            alloc,
            worker.url,
            worker.token,
            worker.protocol,
            worker.model,
            run_row.id,
            step.id,
            rendered_prompt,
        );

        if (result.success) {
            const output_json = try wrapOutput(alloc, result.output);
            try self.store.updateStepStatus(step.id, "completed", worker.id, output_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output_json, self.metrics);
            log.info("reduce step {s} completed", .{step.id});
        } else {
            const err_text = result.error_text orelse "dispatch failed";
            if (step.attempt < step.max_attempts) {
                try self.store.updateStepStatus(step.id, "ready", null, null, err_text, step.attempt + 1);
                try self.store.insertEvent(run_row.id, step.id, "step.retry", "{}");
            } else {
                try self.store.updateStepStatus(step.id, "failed", worker.id, null, err_text, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
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

        // 5. Determine the winning target and check for graph cycles
        const winning_target: ?[]const u8 = if (condition_met) true_target else false_target;

        // Check if the winning target is a backward edge (cycle)
        if (winning_target) |target| {
            const cycle_handled = try self.handleCycleBack(alloc, run_row, step, target, all_steps);
            if (cycle_handled) return; // Cycle was handled, step is already completed
        }

        // 6. For the losing branch target: mark steps as "skipped"
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

        // 7. Mark condition step as "completed"
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

    // ── executeTransformStep ────────────────────────────────────────

    fn executeTransformStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Get output_template from workflow_json
        const output_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "output_template") orelse {
            log.warn("no output_template for transform step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing output_template", step.attempt);
            return;
        };

        // 2. Build template context (same as task step)
        const ctx = try buildTemplateContext(alloc, run_row, step, self.store);

        // 3. Render template
        const rendered = templates.render(alloc, output_template, ctx) catch |err| {
            const err_msg = std.fmt.allocPrint(alloc, "template render error: {}", .{err}) catch "template render error";
            try self.store.updateStepStatus(step.id, "failed", null, null, err_msg, step.attempt);
            return;
        };

        // 4. Wrap as output and mark completed
        const output = try wrapOutput(alloc, rendered);
        try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);

        // 5. Fire callback + event
        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
        try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
        log.info("transform step {s} completed", .{step.id});
    }

    // ── executeWaitStep ──────────────────────────────────────────────

    fn executeWaitStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        const now = ids.nowMs();

        // Check signal mode first
        if (try getStepField(alloc, run_row.workflow_json, step.def_step_id, "signal")) |_| {
            // Signal mode: set to waiting_approval and wait for external POST /signal
            try self.store.updateStepStatus(step.id, "waiting_approval", null, null, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.waiting_signal", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.waiting_signal", run_row.id, step.id, "{}", self.metrics);
            log.info("wait step {s} waiting for signal", .{step.id});
            return;
        }

        // Duration mode
        const duration_opt: ?i64 = blk: {
            const duration_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "duration_ms");
            if (duration_raw != null) {
                const dur_int = (try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "duration_ms")) orelse {
                    try self.failStepWithError(alloc, run_row, step, "duration_ms must be an integer");
                    return;
                };
                if (dur_int < 0) {
                    try self.failStepWithError(alloc, run_row, step, "duration_ms must be >= 0");
                    return;
                }
                break :blk dur_int;
            }
            break :blk null;
        };
        if (duration_opt) |duration| {
            if (step.started_at_ms) |started| {
                // Already running -- check if duration elapsed
                if (now - started >= duration) {
                    const waited = now - started;
                    const output = try std.fmt.allocPrint(alloc, "{{\"output\":\"waited\",\"waited_ms\":{d}}}", .{waited});
                    try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
                    try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
                    log.info("wait step {s} completed after {d}ms", .{ step.id, waited });
                    return;
                }
                // Not yet -- stay running (do nothing, will be checked next tick)
                return;
            }
            // First time -- mark running and set started_at_ms
            try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
            try self.store.setStepStartedAt(step.id, now);
            return;
        }

        // Until_ms mode (check integer field)
        if (try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "until_ms")) |until| {
            if (until < 0) {
                try self.failStepWithError(alloc, run_row, step, "until_ms must be >= 0");
                return;
            }
            if (now >= until) {
                const output = try std.fmt.allocPrint(alloc, "{{\"output\":\"waited\",\"waited_ms\":{d}}}", .{now - (step.started_at_ms orelse now)});
                try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
                log.info("wait step {s} completed (until_ms reached)", .{step.id});
                return;
            }
            if (step.started_at_ms == null) {
                try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
                try self.store.setStepStartedAt(step.id, now);
            }
            return;
        }

        // No wait configuration -- fail
        try self.failStepWithError(alloc, run_row, step, "wait step missing duration_ms, until_ms, or signal");
    }

    // ── executeRouterStep ────────────────────────────────────────────

    fn executeRouterStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, all_steps: []const types.StepRow) !void {
        // 1. Get dependency output
        const deps = try self.store.getStepDeps(alloc, step.id);
        if (deps.len == 0) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "router has no dependencies", step.attempt);
            return;
        }

        const dep_step = (try self.store.getStep(alloc, deps[0])) orelse {
            try self.store.updateStepStatus(step.id, "failed", null, null, "dependency step not found", step.attempt);
            return;
        };
        const dep_output = extractOutputField(alloc, dep_step.output_json orelse "") catch "";

        // 2. Parse routes from workflow definition (routes is a JSON object, not a string)
        const routes_str = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "routes") orelse {
            try self.store.updateStepStatus(step.id, "failed", null, null, "router missing routes", step.attempt);
            return;
        };

        const default_target = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "default");

        // 3. Parse routes JSON object and find match
        var matched_target: ?[]const u8 = null;
        var all_targets: std.ArrayListUnmanaged([]const u8) = .empty;

        const parsed = std.json.parseFromSlice(std.json.Value, alloc, routes_str, .{}) catch {
            try self.store.updateStepStatus(step.id, "failed", null, null, "invalid routes JSON", step.attempt);
            return;
        };

        if (parsed.value == .object) {
            var it = parsed.value.object.iterator();
            while (it.next()) |entry| {
                const target = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => continue,
                };
                try all_targets.append(alloc, target);

                if (matched_target == null) {
                    // Check if dep_output contains the route key
                    if (std.mem.indexOf(u8, dep_output, entry.key_ptr.*) != null) {
                        matched_target = target;
                    }
                }
            }
        }

        // 4. Use default if no match
        if (matched_target == null) {
            matched_target = default_target;
        }

        if (matched_target == null) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "no matching route and no default", step.attempt);
            return;
        }

        // 5. Check if matched target is a backward edge (cycle)
        const cycle_handled = try self.handleCycleBack(alloc, run_row, step, matched_target.?, all_steps);
        if (cycle_handled) return; // Cycle was handled, step is already completed

        // 6. Skip all non-matched targets
        for (all_targets.items) |target| {
            if (!std.mem.eql(u8, target, matched_target.?)) {
                self.skipStepByDefId(alloc, all_steps, run_row.id, target) catch {};
            }
        }

        // 7. Mark router completed
        const output = try std.fmt.allocPrint(alloc, "{{\"output\":\"routed\",\"routed_to\":\"{s}\"}}", .{matched_target.?});
        try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
        log.info("router step {s} routed to {s}", .{ step.id, matched_target.? });
    }

    // ── executeLoopStep ─────────────────────────────────────────────
    //
    // First tick (step is "ready", no children exist):
    //   - Parse body array from workflow definition
    //   - Create child step instances for iteration 0
    //   - Chain body steps sequentially within the iteration
    //   - Mark loop step as "running"

    fn executeLoopStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // Parse body array from step definition
        const body_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "body") orelse {
            log.warn("no body for loop step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing body in loop definition", step.attempt);
            return;
        };

        const body_parsed = std.json.parseFromSlice(std.json.Value, alloc, body_raw, .{}) catch {
            try self.store.updateStepStatus(step.id, "failed", null, null, "invalid body JSON in loop definition", step.attempt);
            return;
        };

        if (body_parsed.value != .array or body_parsed.value.array.items.len == 0) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "body must be a non-empty array", step.attempt);
            return;
        }

        const body_items = body_parsed.value.array.items;

        // Create child steps for iteration 0
        try self.createLoopIterationChildren(alloc, run_row, step, body_items, 0);

        // Mark loop step as "running"
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");
        log.info("loop step {s} started iteration 0", .{step.id});
    }

    // ── pollRunningLoopStep ─────────────────────────────────────────
    //
    // Checks progress of a running loop step each tick:
    //   - Find current iteration (max iteration_index)
    //   - Check if all children in current iteration are done
    //   - If any failed -> loop fails
    //   - If all done: evaluate exit_condition
    //   - If met -> loop completes
    //   - If max_iterations reached -> loop completes
    //   - Else -> create next iteration

    fn pollRunningLoopStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // Get all children of this loop step
        const children = try self.store.getChildSteps(alloc, step.id);
        if (children.len == 0) return; // No children yet, wait

        // Find the current (max) iteration_index
        var max_iter: i64 = 0;
        for (children) |child| {
            if (child.iteration_index > max_iter) {
                max_iter = child.iteration_index;
            }
        }

        // Check if all children in the current iteration are in terminal states
        var all_done = true;
        var any_failed = false;
        var last_child_output: ?[]const u8 = null;

        for (children) |child| {
            if (child.iteration_index != max_iter) continue;

            if (std.mem.eql(u8, child.status, "failed")) {
                any_failed = true;
                continue;
            }
            if (std.mem.eql(u8, child.status, "completed") or std.mem.eql(u8, child.status, "skipped")) {
                // Track the last completed child's output (by item_index order)
                if (child.output_json != null) {
                    last_child_output = child.output_json;
                }
                continue;
            }
            // Still pending/ready/running
            all_done = false;
        }

        if (!all_done) return; // Not done yet, wait

        if (any_failed) {
            // Loop fails if any child fails
            try self.store.updateStepStatus(step.id, "failed", null, null, "loop child step failed", step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
            log.info("loop step {s} failed (child failed)", .{step.id});
            return;
        }

        // All children in current iteration are done. Evaluate exit_condition.
        const exit_condition = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "exit_condition");
        const max_iterations = try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "max_iterations") orelse 10;

        // Extract output text from last child for condition matching
        const last_output_text = if (last_child_output) |oj|
            (extractOutputField(alloc, oj) catch oj)
        else
            "";

        // Check exit condition (substring match, same as condition step)
        const condition_met = if (exit_condition) |cond|
            std.mem.indexOf(u8, last_output_text, cond) != null
        else
            false;

        if (condition_met) {
            // Exit condition met -- loop completes with last child's output
            const output = last_child_output orelse try wrapOutput(alloc, "loop completed");
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("loop step {s} completed (exit condition met at iteration {d})", .{ step.id, max_iter });
            return;
        }

        // Check if max_iterations reached
        if (max_iter + 1 >= max_iterations) {
            // Max iterations reached -- loop completes with last child's output
            const output = last_child_output orelse try wrapOutput(alloc, "loop completed (max iterations)");
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("loop step {s} completed (max iterations {d} reached)", .{ step.id, max_iterations });
            return;
        }

        // Create next iteration
        const next_iter = max_iter + 1;

        // Re-parse body to get the body step def IDs
        const body_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "body") orelse return;
        const body_parsed = std.json.parseFromSlice(std.json.Value, alloc, body_raw, .{}) catch return;
        if (body_parsed.value != .array) return;
        const body_items = body_parsed.value.array.items;

        try self.createLoopIterationChildren(alloc, run_row, step, body_items, next_iter);
        log.info("loop step {s} started iteration {d}", .{ step.id, next_iter });
    }

    /// Create child steps for one iteration of a loop.
    fn createLoopIterationChildren(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, loop_step: types.StepRow, body_items: []const std.json.Value, iteration: i64) !void {
        var prev_child_id: ?[]const u8 = null;

        for (body_items, 0..) |body_item, i| {
            // Each body_item should be a string (step def ID)
            const body_def_id = switch (body_item) {
                .string => |s| s,
                else => continue,
            };

            // Look up the body step's type from the workflow definition
            const body_step_type = try getStepField(alloc, run_row.workflow_json, body_def_id, "type") orelse "task";

            // Generate unique child step ID
            const child_id_buf = ids.generateId();
            const child_id = try alloc.dupe(u8, &child_id_buf);

            // First step in chain is "ready", rest are "pending"
            const initial_status: []const u8 = if (i == 0) "ready" else "pending";
            const idx: i64 = @intCast(i);

            try self.store.insertStepWithIteration(
                child_id,
                run_row.id,
                body_def_id, // original def_step_id for template/tag lookup
                body_step_type,
                initial_status,
                "{}", // input_json
                1, // max_attempts
                null, // timeout_ms
                loop_step.id, // parent_step_id
                idx, // item_index (position in body)
                iteration, // iteration_index
            );

            // Chain: this step depends on previous step in the body
            if (prev_child_id) |prev_id| {
                try self.store.insertStepDep(child_id, prev_id);
            }

            prev_child_id = child_id;
        }
    }

    // ── executeSubWorkflowStep ──────────────────────────────────────
    //
    // First tick (step is "ready", child_run_id is null):
    //   - Get nested workflow definition
    //   - Create a child run with the nested workflow
    //   - Create child run's steps
    //   - Store child_run_id on the parent step
    //   - Mark step as "running"

    fn executeSubWorkflowStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Get nested workflow definition from the step def
        const workflow_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "workflow") orelse {
            log.warn("no workflow for sub_workflow step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing workflow in sub_workflow definition", step.attempt);
            return;
        };

        // 2. Parse the nested workflow to extract steps
        const nested_parsed = std.json.parseFromSlice(std.json.Value, alloc, workflow_raw, .{}) catch {
            try self.store.updateStepStatus(step.id, "failed", null, null, "invalid workflow JSON in sub_workflow definition", step.attempt);
            return;
        };

        if (nested_parsed.value != .object) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "workflow must be a JSON object", step.attempt);
            return;
        }

        const nested_steps_val = nested_parsed.value.object.get("steps") orelse {
            try self.store.updateStepStatus(step.id, "failed", null, null, "workflow missing steps array", step.attempt);
            return;
        };
        if (nested_steps_val != .array or nested_steps_val.array.items.len == 0) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "workflow steps must be a non-empty array", step.attempt);
            return;
        }

        // 3. Build input for child run from input_mapping (optional)
        var child_input_json: []const u8 = run_row.input_json;
        if (try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "input_mapping")) |mapping_raw| {
            const mapping_parsed = std.json.parseFromSlice(std.json.Value, alloc, mapping_raw, .{}) catch null;
            if (mapping_parsed) |mp| {
                if (mp.value == .object) {
                    // Render each value in the mapping using template context
                    const ctx = try buildTemplateContext(alloc, run_row, step, self.store);
                    var result_buf: std.ArrayListUnmanaged(u8) = .empty;
                    try result_buf.append(alloc, '{');
                    var first = true;
                    var it = mp.value.object.iterator();
                    while (it.next()) |entry| {
                        if (!first) try result_buf.append(alloc, ',');
                        first = false;
                        // Write key
                        try result_buf.append(alloc, '"');
                        try result_buf.appendSlice(alloc, entry.key_ptr.*);
                        try result_buf.appendSlice(alloc, "\":");
                        // Render value as template if it's a string
                        if (entry.value_ptr.* == .string) {
                            const rendered = templates.render(alloc, entry.value_ptr.string, ctx) catch entry.value_ptr.string;
                            try result_buf.append(alloc, '"');
                            for (rendered) |ch| {
                                switch (ch) {
                                    '"' => try result_buf.appendSlice(alloc, "\\\""),
                                    '\\' => try result_buf.appendSlice(alloc, "\\\\"),
                                    '\n' => try result_buf.appendSlice(alloc, "\\n"),
                                    '\r' => try result_buf.appendSlice(alloc, "\\r"),
                                    '\t' => try result_buf.appendSlice(alloc, "\\t"),
                                    else => try result_buf.append(alloc, ch),
                                }
                            }
                            try result_buf.append(alloc, '"');
                        } else {
                            // Non-string values: serialize as-is
                            var out: std.io.Writer.Allocating = .init(alloc);
                            var jw: std.json.Stringify = .{ .writer = &out.writer };
                            jw.write(entry.value_ptr.*) catch {};
                            const serialized = out.toOwnedSlice() catch "null";
                            try result_buf.appendSlice(alloc, serialized);
                        }
                    }
                    try result_buf.append(alloc, '}');
                    child_input_json = try result_buf.toOwnedSlice(alloc);
                }
            }
        }

        // 4. Create child run
        const child_run_id_buf = ids.generateId();
        const child_run_id = try alloc.dupe(u8, &child_run_id_buf);

        // Build the child workflow_json: wrap the nested workflow with its steps
        // The child run's workflow_json should be the workflow_raw itself
        try self.store.insertRun(child_run_id, null, "running", workflow_raw, child_input_json, run_row.callbacks_json);

        // 5. Create child run's steps from the nested workflow definition
        const nested_steps = nested_steps_val.array.items;

        // Build mapping from def_step_id -> generated step_id
        var def_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        var gen_ids: std.ArrayListUnmanaged([]const u8) = .empty;

        // First pass: create all steps
        for (nested_steps) |step_val| {
            if (step_val != .object) continue;
            const step_obj = step_val.object;

            const def_step_id = if (step_obj.get("id")) |id_val| blk: {
                if (id_val == .string) break :blk id_val.string;
                break :blk null;
            } else null;
            if (def_step_id == null) continue;

            const step_type_str = if (step_obj.get("type")) |t| blk: {
                if (t == .string) break :blk t.string;
                break :blk "task";
            } else "task";

            const child_step_id_buf = ids.generateId();
            const child_step_id = try alloc.dupe(u8, &child_step_id_buf);

            // Determine initial status
            const has_deps = if (step_obj.get("depends_on")) |deps| blk: {
                if (deps == .array and deps.array.items.len > 0) break :blk true;
                break :blk false;
            } else false;
            const initial_status: []const u8 = if (has_deps) "pending" else "ready";

            try self.store.insertStep(
                child_step_id,
                child_run_id,
                def_step_id.?,
                step_type_str,
                initial_status,
                "{}",
                1, // max_attempts
                null, // timeout_ms
                null, // parent_step_id
                null, // item_index
            );

            try def_ids.append(alloc, def_step_id.?);
            try gen_ids.append(alloc, child_step_id);
        }

        // Second pass: insert step dependencies
        for (nested_steps) |step_val| {
            if (step_val != .object) continue;
            const step_obj = step_val.object;

            const def_step_id = if (step_obj.get("id")) |id_val| blk: {
                if (id_val == .string) break :blk id_val.string;
                break :blk null;
            } else null;
            if (def_step_id == null) continue;

            // Find generated step_id
            const gen_step_id = lookupId(def_ids.items, gen_ids.items, def_step_id.?) orelse continue;

            const deps_val = step_obj.get("depends_on") orelse continue;
            if (deps_val != .array) continue;

            for (deps_val.array.items) |dep_item| {
                if (dep_item != .string) continue;
                const dep_gen_id = lookupId(def_ids.items, gen_ids.items, dep_item.string) orelse continue;
                try self.store.insertStepDep(gen_step_id, dep_gen_id);
            }
        }

        // 6. Store child_run_id on the parent step
        try self.store.updateStepChildRunId(step.id, child_run_id);

        // 7. Mark sub_workflow step as "running"
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");
        log.info("sub_workflow step {s} created child run {s}", .{ step.id, child_run_id });
    }

    // ── pollRunningSubWorkflowStep ──────────────────────────────────
    //
    // Checks the child run's status each tick:
    //   - If completed -> mark parent step completed with child's output
    //   - If failed -> mark parent step failed
    //   - Otherwise -> wait

    fn pollRunningSubWorkflowStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        const child_run_id = step.child_run_id orelse return; // No child run yet

        // Get child run
        const child_run = (try self.store.getRun(alloc, child_run_id)) orelse {
            try self.store.updateStepStatus(step.id, "failed", null, null, "child run not found", step.attempt);
            return;
        };

        if (std.mem.eql(u8, child_run.status, "completed")) {
            // Get the child run's last completed step output
            const child_steps = try self.store.getStepsByRun(alloc, child_run_id);
            var last_output: ?[]const u8 = null;
            for (child_steps) |cs| {
                if (std.mem.eql(u8, cs.status, "completed") and cs.output_json != null) {
                    last_output = cs.output_json;
                }
            }
            const output = last_output orelse try wrapOutput(alloc, "sub_workflow completed");
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("sub_workflow step {s} completed (child run {s})", .{ step.id, child_run_id });
        } else if (std.mem.eql(u8, child_run.status, "failed")) {
            const err_text = child_run.error_text orelse "child run failed";
            try self.store.updateStepStatus(step.id, "failed", null, null, err_text, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
            log.info("sub_workflow step {s} failed (child run {s})", .{ step.id, child_run_id });
        }
        // Otherwise: child run still in progress, wait
    }

    // ── executeDebateStep ──────────────────────────────────────────
    //
    // Phase 1 (step is "ready"): Create N participant child steps
    // Phase 2 (step is "running"): polled by pollRunningDebateStep

    fn executeDebateStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Parse count from workflow_json
        const count_val = try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "count") orelse {
            log.warn("no count for debate step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing count in debate definition", step.attempt);
            return;
        };
        const count: usize = @intCast(count_val);

        // 2. Get prompt_template and render it
        const prompt_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template") orelse {
            log.warn("no prompt_template for debate step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing prompt_template in debate definition", step.attempt);
            return;
        };

        const ctx = try buildTemplateContext(alloc, run_row, step, self.store);
        const rendered_prompt = templates.render(alloc, prompt_template, ctx) catch |err| {
            log.err("template render failed for debate step {s}: {}", .{ step.id, err });
            try self.store.updateStepStatus(step.id, "failed", null, null, "template render failed", step.attempt);
            return;
        };

        // 3. Create N participant child steps
        for (0..count) |i| {
            const child_id_buf = ids.generateId();
            const child_id = try alloc.dupe(u8, &child_id_buf);
            const child_def_id = try std.fmt.allocPrint(alloc, "{s}_participant_{d}", .{ step.def_step_id, i });
            const idx: i64 = @intCast(i);

            // Store rendered prompt in input_json so participant children can be dispatched.
            const input_json = try buildRenderedPromptInputJson(alloc, rendered_prompt);

            try self.store.insertStep(
                child_id,
                run_row.id,
                child_def_id,
                "task",
                "ready",
                input_json,
                step.max_attempts,
                step.timeout_ms,
                step.id, // parent_step_id
                idx,
            );
            log.info("created debate participant child step {s} (index {d})", .{ child_id, i });
        }

        // 4. Mark debate step as "running"
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");
        log.info("debate step {s} started with {d} participants", .{ step.id, count });
    }

    // ── pollRunningDebateStep ────────────────────────────────────────
    //
    // Checks if all participant children are done, then dispatches judge.

    fn pollRunningDebateStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        const children = try self.store.getChildSteps(alloc, step.id);
        if (children.len == 0) return;

        // Separate participants from judge child
        var participants: std.ArrayListUnmanaged(types.StepRow) = .empty;
        var judge_child: ?types.StepRow = null;

        for (children) |child| {
            if (std.mem.indexOf(u8, child.def_step_id, "_judge") != null) {
                judge_child = child;
            } else {
                try participants.append(alloc, child);
            }
        }

        // Check if judge child exists and is terminal
        if (judge_child) |judge| {
            if (std.mem.eql(u8, judge.status, "completed")) {
                // Debate completes with judge output
                const output = judge.output_json orelse try wrapOutput(alloc, "debate completed");
                try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
                log.info("debate step {s} completed (judge decided)", .{step.id});
                return;
            } else if (std.mem.eql(u8, judge.status, "failed")) {
                const err_text = judge.error_text orelse "judge failed";
                try self.store.updateStepStatus(step.id, "failed", null, null, err_text, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
                log.info("debate step {s} failed (judge failed)", .{step.id});
                return;
            }
            // Judge still in progress, wait
            return;
        }

        // No judge child yet — check if all participants are done
        var all_done = true;
        var any_failed = false;
        for (participants.items) |child| {
            if (std.mem.eql(u8, child.status, "failed")) {
                any_failed = true;
                continue;
            }
            if (!std.mem.eql(u8, child.status, "completed") and !std.mem.eql(u8, child.status, "skipped")) {
                all_done = false;
            }
        }

        if (!all_done) return; // Still waiting for participants

        if (any_failed) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "debate participant failed", step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
            return;
        }

        // All participants done — collect outputs and create judge child
        var response_items: std.ArrayListUnmanaged([]const u8) = .empty;
        for (participants.items) |child| {
            if (child.output_json) |oj| {
                const extracted = extractOutputField(alloc, oj) catch oj;
                try response_items.append(alloc, extracted);
            } else {
                try response_items.append(alloc, "");
            }
        }

        // Build debate_responses as JSON array
        const debate_responses = try serializeStringArray(alloc, response_items.items);

        // Get judge_template
        const judge_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "judge_template") orelse {
            // No judge template — complete with collected responses
            const output = try wrapOutput(alloc, debate_responses);
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("debate step {s} completed (no judge template, returning responses)", .{step.id});
            return;
        };

        // Render judge_template: replace {{debate_responses}} with actual responses
        // Simple string replacement since it's a special variable
        var rendered_judge_prompt: []const u8 = judge_template;
        if (std.mem.indexOf(u8, judge_template, "{{debate_responses}}")) |_| {
            rendered_judge_prompt = try std.mem.replaceOwned(u8, alloc, judge_template, "{{debate_responses}}", debate_responses);
        }

        // Create judge child step with rendered prompt in input_json
        const judge_id_buf = ids.generateId();
        const judge_id = try alloc.dupe(u8, &judge_id_buf);
        const judge_def_id = try std.fmt.allocPrint(alloc, "{s}_judge", .{step.def_step_id});

        const judge_input = try buildRenderedPromptInputJson(alloc, rendered_judge_prompt);
        const judge_idx: i64 = @intCast(participants.items.len);

        try self.store.insertStep(
            judge_id,
            run_row.id,
            judge_def_id,
            "task",
            "ready",
            judge_input,
            step.max_attempts,
            step.timeout_ms,
            step.id, // parent_step_id
            judge_idx,
        );

        log.info("debate step {s} created judge child {s}", .{ step.id, judge_id });
    }

    // ── executeGroupChatStep ─────────────────────────────────────────
    //
    // First tick: parse participants, mark as running, start round 1.
    // Dispatch is attempted but may fail (no workers in test).

    fn executeGroupChatStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Parse participants from workflow_json
        const participants_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "participants") orelse {
            log.warn("no participants for group_chat step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing participants in group_chat definition", step.attempt);
            return;
        };

        const parsed_participants = std.json.parseFromSlice(std.json.Value, alloc, participants_raw, .{}) catch {
            try self.store.updateStepStatus(step.id, "failed", null, null, "invalid participants JSON", step.attempt);
            return;
        };

        if (parsed_participants.value != .array or parsed_participants.value.array.items.len == 0) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "participants must be a non-empty array", step.attempt);
            return;
        }

        // 2. Get prompt_template for round 1
        const prompt_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template") orelse {
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing prompt_template in group_chat definition", step.attempt);
            return;
        };

        // 3. Render prompt template
        const ctx = try buildTemplateContext(alloc, run_row, step, self.store);
        const rendered_prompt = templates.render(alloc, prompt_template, ctx) catch |err| {
            log.err("template render failed for group_chat step {s}: {}", .{ step.id, err });
            try self.store.updateStepStatus(step.id, "failed", null, null, "template render failed", step.attempt);
            return;
        };

        // 4. Mark step as "running"
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");

        // 5. Dispatch round 1 to each participant (best-effort, failures logged)
        const participant_items = parsed_participants.value.array.items;
        for (participant_items) |p_val| {
            if (p_val != .object) continue;
            const p_obj = p_val.object;

            const role = if (p_obj.get("role")) |r| blk: {
                if (r == .string) break :blk r.string;
                break :blk "participant";
            } else "participant";

            // Try to dispatch to a worker matching participant tags
            const tags_val = p_obj.get("tags");
            var tag_list: std.ArrayListUnmanaged([]const u8) = .empty;
            if (tags_val) |tv| {
                if (tv == .array) {
                    for (tv.array.items) |tag_item| {
                        if (tag_item == .string) {
                            try tag_list.append(alloc, tag_item.string);
                        }
                    }
                }
            }

            // Get workers
            const workers = try self.store.listWorkers(alloc);
            var worker_infos: std.ArrayListUnmanaged(dispatch.WorkerInfo) = .empty;
            for (workers) |w| {
                const current_tasks = self.store.countRunningStepsByWorker(w.id) catch 0;
                try worker_infos.append(alloc, .{
                    .id = w.id,
                    .url = w.url,
                    .token = w.token,
                    .protocol = w.protocol,
                    .model = w.model,
                    .tags_json = w.tags_json,
                    .max_concurrent = w.max_concurrent,
                    .status = w.status,
                    .current_tasks = current_tasks,
                });
            }

            const selected = try dispatch.selectWorker(alloc, worker_infos.items, tag_list.items);
            if (selected) |worker| {
                const result = try dispatch.dispatchStep(
                    alloc,
                    worker.url,
                    worker.token,
                    worker.protocol,
                    worker.model,
                    run_row.id,
                    step.id,
                    rendered_prompt,
                );
                if (result.success) {
                    try self.store.insertChatMessage(run_row.id, step.id, 1, role, worker.id, result.output);
                } else {
                    log.warn("group_chat dispatch failed for role {s}: {s}", .{ role, result.error_text orelse "unknown" });
                }
            } else {
                log.debug("no worker available for group_chat participant role {s}", .{role});
            }
        }

        log.info("group_chat step {s} started round 1 with {d} participants", .{ step.id, participant_items.len });
    }

    // ── pollRunningGroupChatStep ─────────────────────────────────────
    //
    // Each tick: check current round, dispatch next round or complete.

    fn pollRunningGroupChatStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Get all chat messages for this step
        const messages = try self.store.getChatMessages(alloc, step.id);

        // 2. Parse configuration
        const max_rounds = try getStepFieldInt(alloc, run_row.workflow_json, step.def_step_id, "max_rounds") orelse 5;
        const exit_condition = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "exit_condition");

        // 3. Parse participants to know expected count per round
        const participants_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "participants") orelse return;
        const parsed_participants = std.json.parseFromSlice(std.json.Value, alloc, participants_raw, .{}) catch return;
        if (parsed_participants.value != .array) return;
        const num_participants: i64 = @intCast(parsed_participants.value.array.items.len);

        // 4. Determine current round from messages
        var current_round: i64 = 0;
        var current_round_count: i64 = 0;
        for (messages) |msg| {
            if (msg.round > current_round) {
                current_round = msg.round;
                current_round_count = 1;
            } else if (msg.round == current_round) {
                current_round_count += 1;
            }
        }

        if (current_round == 0) return; // No messages yet, wait for initial dispatch

        // 5. Check if current round is complete (all participants responded)
        if (current_round_count < num_participants) {
            // Round not complete, wait
            return;
        }

        // 6. Check exit condition in latest round's messages
        if (exit_condition) |cond| {
            for (messages) |msg| {
                if (msg.round == current_round) {
                    if (std.mem.indexOf(u8, msg.message, cond) != null) {
                        // Exit condition met — complete with transcript
                        const transcript = try buildChatTranscript(alloc, messages);
                        const output = try wrapOutput(alloc, transcript);
                        try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
                        try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
                        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
                        log.info("group_chat step {s} completed (exit condition met at round {d})", .{ step.id, current_round });
                        return;
                    }
                }
            }
        }

        // 7. Check if max rounds reached
        if (current_round >= max_rounds) {
            const transcript = try buildChatTranscript(alloc, messages);
            const output = try wrapOutput(alloc, transcript);
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("group_chat step {s} completed (max rounds {d} reached)", .{ step.id, max_rounds });
            return;
        }

        // 8. Start next round — build chat history and dispatch
        const next_round = current_round + 1;
        const chat_history = try buildChatTranscript(alloc, messages);

        const round_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "round_template") orelse {
            // No round_template — complete with what we have
            const output = try wrapOutput(alloc, chat_history);
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            return;
        };

        // Dispatch to each participant with round_template
        const participant_items = parsed_participants.value.array.items;
        for (participant_items) |p_val| {
            if (p_val != .object) continue;
            const p_obj = p_val.object;

            const role = if (p_obj.get("role")) |r| blk: {
                if (r == .string) break :blk r.string;
                break :blk "participant";
            } else "participant";

            // Render round_template with {{chat_history}} and {{role}}
            var rendered = try std.mem.replaceOwned(u8, alloc, round_template, "{{chat_history}}", chat_history);
            rendered = try std.mem.replaceOwned(u8, alloc, rendered, "{{role}}", role);

            // Get participant tags
            const tags_val = p_obj.get("tags");
            var tag_list: std.ArrayListUnmanaged([]const u8) = .empty;
            if (tags_val) |tv| {
                if (tv == .array) {
                    for (tv.array.items) |tag_item| {
                        if (tag_item == .string) {
                            try tag_list.append(alloc, tag_item.string);
                        }
                    }
                }
            }

            // Select worker and dispatch
            const workers = try self.store.listWorkers(alloc);
            var worker_infos: std.ArrayListUnmanaged(dispatch.WorkerInfo) = .empty;
            for (workers) |w| {
                const current_tasks = self.store.countRunningStepsByWorker(w.id) catch 0;
                try worker_infos.append(alloc, .{
                    .id = w.id,
                    .url = w.url,
                    .token = w.token,
                    .protocol = w.protocol,
                    .model = w.model,
                    .tags_json = w.tags_json,
                    .max_concurrent = w.max_concurrent,
                    .status = w.status,
                    .current_tasks = current_tasks,
                });
            }

            const selected = try dispatch.selectWorker(alloc, worker_infos.items, tag_list.items);
            if (selected) |worker| {
                const result = try dispatch.dispatchStep(
                    alloc,
                    worker.url,
                    worker.token,
                    worker.protocol,
                    worker.model,
                    run_row.id,
                    step.id,
                    rendered,
                );
                if (result.success) {
                    try self.store.insertChatMessage(run_row.id, step.id, next_round, role, worker.id, result.output);
                } else {
                    log.warn("group_chat round {d} dispatch failed for role {s}", .{ next_round, role });
                }
            } else {
                log.debug("no worker for group_chat round {d} participant role {s}", .{ next_round, role });
            }
        }

        log.info("group_chat step {s} dispatched round {d}", .{ step.id, next_round });
    }

    // ── executeSagaStep ─────────────────────────────────────────────
    //
    // First tick (step is "ready"):
    //   - Parse body array and compensations map from workflow definition
    //   - Create first body step as child (status="ready")
    //   - Initialize saga_state entries for all body steps
    //   - Mark saga step as "running"

    fn executeSagaStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        // 1. Parse body array from step definition
        const body_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "body") orelse {
            log.warn("no body for saga step {s}", .{step.def_step_id});
            try self.store.updateStepStatus(step.id, "failed", null, null, "missing body in saga definition", step.attempt);
            return;
        };

        const body_parsed = std.json.parseFromSlice(std.json.Value, alloc, body_raw, .{}) catch {
            try self.store.updateStepStatus(step.id, "failed", null, null, "invalid body JSON in saga definition", step.attempt);
            return;
        };

        if (body_parsed.value != .array or body_parsed.value.array.items.len == 0) {
            try self.store.updateStepStatus(step.id, "failed", null, null, "body must be a non-empty array", step.attempt);
            return;
        }

        const body_items = body_parsed.value.array.items;

        // 2. Parse compensations map (optional)
        const comp_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "compensations");
        var comp_map: ?std.json.ObjectMap = null;
        if (comp_raw) |cr| {
            const comp_parsed = std.json.parseFromSlice(std.json.Value, alloc, cr, .{}) catch null;
            if (comp_parsed) |cp| {
                if (cp.value == .object) {
                    comp_map = cp.value.object;
                }
            }
        }

        // 3. Initialize saga_state for all body steps and create first child
        for (body_items, 0..) |body_item, i| {
            const body_def_id = switch (body_item) {
                .string => |s| s,
                else => continue,
            };

            // Look up compensation for this body step
            var comp_def_id: ?[]const u8 = null;
            if (comp_map) |cm| {
                if (cm.get(body_def_id)) |cv| {
                    if (cv == .string) {
                        comp_def_id = cv.string;
                    }
                }
            }

            // Insert saga_state entry
            try self.store.insertSagaState(run_row.id, step.id, body_def_id, comp_def_id);

            // Create child step for first body step only (rest created sequentially)
            if (i == 0) {
                const body_step_type = try getStepField(alloc, run_row.workflow_json, body_def_id, "type") orelse "task";
                const child_id_buf = ids.generateId();
                const child_id = try alloc.dupe(u8, &child_id_buf);

                try self.store.insertStep(
                    child_id,
                    run_row.id,
                    body_def_id,
                    body_step_type,
                    "ready",
                    step.input_json,
                    step.max_attempts,
                    step.timeout_ms,
                    step.id, // parent_step_id
                    0, // item_index
                );
                log.info("saga step {s} created first body child {s} (def: {s})", .{ step.id, child_id, body_def_id });
            }
        }

        // 4. Mark saga step as "running"
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.running", "{}");
        log.info("saga step {s} started with {d} body steps", .{ step.id, body_items.len });
    }

    // ── pollRunningSagaStep ──────────────────────────────────────────
    //
    // Each tick:
    //   - Get saga_state entries to understand progress
    //   - Find current body step child and check its status
    //   - If completed: update saga_state, create next body step
    //   - If all body steps completed: mark saga completed
    //   - If body step failed: enter compensation mode
    //   - Track compensation progress

    fn pollRunningSagaStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        const children = try self.store.getChildSteps(alloc, step.id);
        if (children.len == 0) return;

        const saga_states = try self.store.getSagaStates(alloc, run_row.id, step.id);
        if (saga_states.len == 0) return;

        // Parse body array to know the order
        const body_raw = try getStepFieldRaw(alloc, run_row.workflow_json, step.def_step_id, "body") orelse return;
        const body_parsed = std.json.parseFromSlice(std.json.Value, alloc, body_raw, .{}) catch return;
        if (body_parsed.value != .array) return;
        const body_items = body_parsed.value.array.items;

        // Build body def IDs list in order
        var body_def_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        for (body_items) |bi| {
            if (bi == .string) {
                try body_def_ids.append(alloc, bi.string);
            }
        }

        // Check if we're in compensation mode (any saga_state has status "compensating")
        var in_compensation = false;
        for (saga_states) |ss| {
            if (std.mem.eql(u8, ss.status, "compensating")) {
                in_compensation = true;
                break;
            }
        }

        if (in_compensation) {
            // In compensation mode: check if current compensation child is done
            try self.pollSagaCompensation(alloc, run_row, step, children, saga_states, body_def_ids.items);
            return;
        }

        // Forward mode: check the current body step child
        // Find which body step we're on by looking at saga_states
        var current_body_idx: ?usize = null;
        var failed_body_def_id: ?[]const u8 = null;

        for (saga_states, 0..) |ss, i| {
            if (std.mem.eql(u8, ss.status, "pending")) {
                // This is the next body step to process or the current one
                // Check if there's a child for this body step
                var has_child = false;
                for (children) |child| {
                    if (std.mem.eql(u8, child.def_step_id, ss.body_step_id)) {
                        has_child = true;
                        if (std.mem.eql(u8, child.status, "completed")) {
                            // Body step completed — update saga_state
                            try self.store.updateSagaState(run_row.id, step.id, ss.body_step_id, "completed");
                            log.info("saga body step {s} completed", .{ss.body_step_id});
                            // Create next body step if there is one
                            if (i + 1 < saga_states.len) {
                                const next_def_id = saga_states[i + 1].body_step_id;
                                const next_type = try getStepField(alloc, run_row.workflow_json, next_def_id, "type") orelse "task";
                                const next_id_buf = ids.generateId();
                                const next_id = try alloc.dupe(u8, &next_id_buf);
                                const next_idx: i64 = @intCast(i + 1);

                                try self.store.insertStep(
                                    next_id,
                                    run_row.id,
                                    next_def_id,
                                    next_type,
                                    "ready",
                                    step.input_json,
                                    step.max_attempts,
                                    step.timeout_ms,
                                    step.id,
                                    next_idx,
                                );
                                log.info("saga step {s} created body child {s} (def: {s})", .{ step.id, next_id, next_def_id });
                            }
                            // Don't process further this tick
                            return;
                        } else if (std.mem.eql(u8, child.status, "failed")) {
                            // Body step failed — enter compensation mode
                            failed_body_def_id = ss.body_step_id;
                            current_body_idx = i;
                            break;
                        }
                        // Still running/ready — wait
                        return;
                    }
                }
                if (!has_child) {
                    // First pending step without a child — this shouldn't happen normally
                    // since executeSagaStep creates the first and we create subsequent ones
                    return;
                }
                break;
            }
        }

        // Check if ALL body steps are completed
        var all_completed = true;
        for (saga_states) |ss| {
            if (!std.mem.eql(u8, ss.status, "completed")) {
                all_completed = false;
                break;
            }
        }

        if (all_completed) {
            // Saga completed successfully — output is last body step's output
            var last_output: ?[]const u8 = null;
            for (children) |child| {
                if (std.mem.eql(u8, child.status, "completed") and child.output_json != null) {
                    // Check if this child is the last body step
                    if (body_def_ids.items.len > 0 and
                        std.mem.eql(u8, child.def_step_id, body_def_ids.items[body_def_ids.items.len - 1]))
                    {
                        last_output = child.output_json;
                    }
                }
            }
            const output = last_output orelse try wrapOutput(alloc, "saga completed");
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output, self.metrics);
            log.info("saga step {s} completed successfully", .{step.id});
            return;
        }

        // Check if compensation has fully completed (all compensating states
        // have become "compensated" and at least one is "failed")
        {
            var has_failed_state = false;
            var has_unfinished_compensation = false;
            for (saga_states) |ss| {
                if (std.mem.eql(u8, ss.status, "failed")) {
                    has_failed_state = true;
                } else if (std.mem.eql(u8, ss.status, "compensating")) {
                    has_unfinished_compensation = true;
                }
            }
            if (has_failed_state and !has_unfinished_compensation) {
                try self.finishSagaCompensation(alloc, run_row, step, saga_states);
                return;
            }
        }

        // If a body step failed, start compensation
        if (failed_body_def_id) |failed_def| {
            log.info("saga step {s} body step {s} failed, starting compensation", .{ step.id, failed_def });

            // Mark the failed body step in saga_state
            try self.store.updateSagaState(run_row.id, step.id, failed_def, "failed");

            // Find completed body steps and start compensating in reverse
            // Mark all completed body steps as "compensating"
            var completed_steps: std.ArrayListUnmanaged([]const u8) = .empty;
            for (saga_states) |ss| {
                if (std.mem.eql(u8, ss.status, "completed")) {
                    try completed_steps.append(alloc, ss.body_step_id);
                    try self.store.updateSagaState(run_row.id, step.id, ss.body_step_id, "compensating");
                }
            }

            if (completed_steps.items.len == 0) {
                // No completed steps to compensate — saga fails immediately
                const output = try std.fmt.allocPrint(alloc, "{{\"failed_at\":\"{s}\",\"compensated\":[]}}", .{failed_def});
                try self.store.updateStepStatus(step.id, "failed", null, output, null, step.attempt);
                try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
                log.info("saga step {s} failed at {s}, no compensations needed", .{ step.id, failed_def });
                return;
            }

            // Create the last completed step's compensation child (reverse order)
            // Start from the last completed body step
            const last_completed = completed_steps.items[completed_steps.items.len - 1];
            try self.createCompensationChild(alloc, run_row, step, saga_states, last_completed);
        }
    }

    /// Create a compensation child step for a given body step.
    fn createCompensationChild(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, saga_step: types.StepRow, saga_states: []const types.SagaStateRow, body_def_id: []const u8) !void {
        // Find the compensation def_id for this body step
        var comp_def_id: ?[]const u8 = null;
        for (saga_states) |ss| {
            if (std.mem.eql(u8, ss.body_step_id, body_def_id)) {
                comp_def_id = ss.compensation_step_id;
                break;
            }
        }

        if (comp_def_id == null) {
            // No compensation for this step — mark as compensated immediately
            try self.store.updateSagaState(run_row.id, saga_step.id, body_def_id, "compensated");
            log.info("saga body step {s} has no compensation, marking compensated", .{body_def_id});
            return;
        }

        const comp_type = try getStepField(alloc, run_row.workflow_json, comp_def_id.?, "type") orelse "task";
        const comp_child_id_buf = ids.generateId();
        const comp_child_id = try alloc.dupe(u8, &comp_child_id_buf);

        try self.store.insertStep(
            comp_child_id,
            run_row.id,
            comp_def_id.?,
            comp_type,
            "ready",
            "{}",
            1, // max_attempts
            null, // timeout_ms
            saga_step.id, // parent_step_id
            null, // item_index
        );
        log.info("saga step {s} created compensation child {s} for body {s}", .{ saga_step.id, comp_child_id, body_def_id });
    }

    /// Poll compensation progress in a saga step.
    fn pollSagaCompensation(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, children: []const types.StepRow, saga_states: []const types.SagaStateRow, body_def_ids: []const []const u8) !void {
        // Find the body step currently being compensated (has a running/ready compensation child)
        // Work backwards through body_def_ids to find the current compensating step
        var compensating_body: ?[]const u8 = null;
        var compensating_idx: ?usize = null;

        // Find compensating steps in reverse order (last completed first)
        var i: usize = body_def_ids.len;
        while (i > 0) {
            i -= 1;
            for (saga_states) |ss| {
                if (std.mem.eql(u8, ss.body_step_id, body_def_ids[i]) and
                    std.mem.eql(u8, ss.status, "compensating"))
                {
                    compensating_body = body_def_ids[i];
                    compensating_idx = i;
                    break;
                }
            }
            if (compensating_body != null) break;
        }

        if (compensating_body == null) {
            // All compensations done — build failure output and fail saga
            try self.finishSagaCompensation(alloc, run_row, step, saga_states);
            return;
        }

        // Check if there's a compensation child for this body step
        var comp_def_id: ?[]const u8 = null;
        for (saga_states) |ss| {
            if (std.mem.eql(u8, ss.body_step_id, compensating_body.?)) {
                comp_def_id = ss.compensation_step_id;
                break;
            }
        }

        if (comp_def_id == null) {
            // No compensation defined — mark as compensated and move on
            try self.store.updateSagaState(run_row.id, step.id, compensating_body.?, "compensated");
            return;
        }

        // Find the compensation child step
        var comp_child: ?types.StepRow = null;
        for (children) |child| {
            if (std.mem.eql(u8, child.def_step_id, comp_def_id.?)) {
                comp_child = child;
            }
        }

        if (comp_child == null) {
            // Compensation child not created yet — create it
            try self.createCompensationChild(alloc, run_row, step, saga_states, compensating_body.?);
            return;
        }

        const comp = comp_child.?;
        if (std.mem.eql(u8, comp.status, "completed")) {
            // Compensation completed — mark this body step as compensated
            try self.store.updateSagaState(run_row.id, step.id, compensating_body.?, "compensated");
            log.info("saga compensation for body step {s} completed", .{compensating_body.?});

            // Find next compensating step (earlier in the list)
            if (compensating_idx.? > 0) {
                var next_idx: ?usize = null;
                var j: usize = compensating_idx.?;
                while (j > 0) {
                    j -= 1;
                    for (saga_states) |ss| {
                        if (std.mem.eql(u8, ss.body_step_id, body_def_ids[j]) and
                            std.mem.eql(u8, ss.status, "compensating"))
                        {
                            next_idx = j;
                            break;
                        }
                    }
                    if (next_idx != null) break;
                }

                // Check if any compensating steps remain. We may have already
                // updated some to compensated in previous iterations, so re-check.
                // The next tick will pick them up via pollSagaCompensation.
            }
        } else if (std.mem.eql(u8, comp.status, "failed")) {
            // Compensation itself failed — saga fails with compensation error
            const err_msg = try std.fmt.allocPrint(alloc, "compensation step {s} failed", .{comp_def_id.?});
            try self.store.updateStepStatus(step.id, "failed", null, null, err_msg, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
            log.info("saga step {s} failed during compensation", .{step.id});
        }
        // Otherwise compensation child still running/ready — wait
    }

    /// Finish saga compensation and mark saga as failed with output.
    fn finishSagaCompensation(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, saga_states: []const types.SagaStateRow) !void {
        // Build list of compensated steps and find failed_at step
        var failed_at: []const u8 = "unknown";
        var compensated: std.ArrayListUnmanaged([]const u8) = .empty;

        for (saga_states) |ss| {
            if (std.mem.eql(u8, ss.status, "failed")) {
                failed_at = ss.body_step_id;
            } else if (std.mem.eql(u8, ss.status, "compensated")) {
                try compensated.append(alloc, ss.body_step_id);
            }
        }

        // Build output JSON
        var comp_json: std.ArrayListUnmanaged(u8) = .empty;
        try comp_json.append(alloc, '[');
        for (compensated.items, 0..) |c, ci| {
            if (ci > 0) try comp_json.append(alloc, ',');
            try comp_json.append(alloc, '"');
            try comp_json.appendSlice(alloc, c);
            try comp_json.append(alloc, '"');
        }
        try comp_json.append(alloc, ']');
        const comp_str = try comp_json.toOwnedSlice(alloc);

        const output = try std.fmt.allocPrint(alloc, "{{\"failed_at\":\"{s}\",\"compensated\":{s}}}", .{ failed_at, comp_str });

        try self.store.updateStepStatus(step.id, "failed", null, output, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.failed", output);
        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, output, self.metrics);
        log.info("saga step {s} failed at {s}, compensated {d} steps", .{ step.id, failed_at, compensated.items.len });
    }

    // ── handleCycleBack ─────────────────────────────────────────────
    //
    // When a condition/router routes to an already-completed step,
    // detect the cycle and create new step instances for the cycle body.

    fn handleCycleBack(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, routing_step: types.StepRow, target_def_id: []const u8, all_steps: []const types.StepRow) !bool {
        // 1. Check if target step is already completed/skipped
        var target_completed = false;
        for (all_steps) |s| {
            if (std.mem.eql(u8, s.def_step_id, target_def_id) and
                (std.mem.eql(u8, s.status, "completed") or std.mem.eql(u8, s.status, "skipped")))
            {
                target_completed = true;
                break;
            }
        }

        if (!target_completed) return false; // Not a backward edge

        // 2. Build cycle_key from routing step's def_step_id
        const cycle_key = try std.fmt.allocPrint(alloc, "cycle_{s}", .{routing_step.def_step_id});

        // 3. Get or initialize cycle state
        const cycle_state = try self.store.getCycleState(run_row.id, cycle_key);
        var iteration_count: i64 = 0;
        var max_iterations: i64 = 10;

        if (cycle_state) |cs| {
            iteration_count = cs.iteration_count;
            max_iterations = cs.max_iterations;
        }

        // Check max_cycle_iterations from workflow config
        const wf_max = try getStepFieldInt(alloc, run_row.workflow_json, routing_step.def_step_id, "max_cycle_iterations");
        if (wf_max) |m| {
            max_iterations = m;
        }

        // 4. Check if limit exceeded
        if (iteration_count >= max_iterations) {
            const err_msg = try std.fmt.allocPrint(alloc, "cycle iteration limit ({d}) exceeded for {s}", .{ max_iterations, cycle_key });
            try self.store.updateStepStatus(routing_step.id, "failed", null, null, err_msg, routing_step.attempt);
            try self.store.insertEvent(run_row.id, routing_step.id, "step.failed", "{}");
            try self.store.updateRunStatus(run_row.id, "failed", err_msg);
            log.warn("cycle limit exceeded for {s}", .{cycle_key});
            return true;
        }

        // 5. Increment cycle iteration
        iteration_count += 1;
        try self.store.upsertCycleState(run_row.id, cycle_key, iteration_count, max_iterations);

        // 6. Walk workflow_json steps to find the cycle body
        //    (from target_def_id through routing step's def_step_id)
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, run_row.workflow_json, .{}) catch return false;
        if (parsed.value != .object) return false;
        const steps_val = parsed.value.object.get("steps") orelse return false;
        if (steps_val != .array) return false;

        // Build ordered list of step def IDs and their types + depends_on
        const StepInfo = struct {
            def_id: []const u8,
            step_type: []const u8,
            depends_on: []const []const u8,
        };

        var step_infos: std.ArrayListUnmanaged(StepInfo) = .empty;
        for (steps_val.array.items) |step_val| {
            if (step_val != .object) continue;
            const step_obj = step_val.object;
            const id_val = step_obj.get("id") orelse continue;
            if (id_val != .string) continue;

            const stype = if (step_obj.get("type")) |t| blk: {
                if (t == .string) break :blk t.string;
                break :blk "task";
            } else "task";

            var deps_list: std.ArrayListUnmanaged([]const u8) = .empty;
            if (step_obj.get("depends_on")) |deps_val| {
                if (deps_val == .array) {
                    for (deps_val.array.items) |dep_item| {
                        if (dep_item == .string) {
                            try deps_list.append(alloc, dep_item.string);
                        }
                    }
                }
            }

            try step_infos.append(alloc, .{
                .def_id = id_val.string,
                .step_type = stype,
                .depends_on = try deps_list.toOwnedSlice(alloc),
            });
        }

        // Find indices of target and routing step in the workflow
        var target_idx: ?usize = null;
        var routing_idx: ?usize = null;
        for (step_infos.items, 0..) |si, idx| {
            if (std.mem.eql(u8, si.def_id, target_def_id)) target_idx = idx;
            if (std.mem.eql(u8, si.def_id, routing_step.def_step_id)) routing_idx = idx;
        }

        if (target_idx == null or routing_idx == null) return false;
        if (target_idx.? >= routing_idx.?) return false; // Not a backward edge

        // 7. Create new step instances for target through routing step
        var new_step_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        var new_def_ids: std.ArrayListUnmanaged([]const u8) = .empty;

        var idx: usize = target_idx.?;
        while (idx <= routing_idx.?) : (idx += 1) {
            const si = step_infos.items[idx];
            const new_id_buf = ids.generateId();
            const new_id = try alloc.dupe(u8, &new_id_buf);

            // First step in cycle is "ready", rest are "pending"
            const initial_status: []const u8 = if (idx == target_idx.?) "ready" else "pending";

            try self.store.insertStepWithIteration(
                new_id,
                run_row.id,
                si.def_id,
                si.step_type,
                initial_status,
                "{}",
                1,
                null,
                null,
                null,
                iteration_count,
            );

            try new_step_ids.append(alloc, new_id);
            try new_def_ids.append(alloc, si.def_id);
        }

        // 8. Chain new instances with deps among themselves
        for (step_infos.items[target_idx.? .. routing_idx.? + 1], 0..) |si, si_idx| {
            const new_id = new_step_ids.items[si_idx];
            for (si.depends_on) |dep_def_id| {
                // Check if dep is within the cycle body
                const dep_new_id = lookupId(new_def_ids.items, new_step_ids.items, dep_def_id);
                if (dep_new_id) |did| {
                    try self.store.insertStepDep(new_id, did);
                }
            }
        }

        // 9. For any step outside the cycle that depended on the routing step,
        //    add a dep to the new routing step instance
        const new_routing_id = new_step_ids.items[new_step_ids.items.len - 1];
        for (all_steps) |s| {
            // Skip steps inside the cycle body
            var in_cycle = false;
            for (new_def_ids.items) |cd| {
                if (std.mem.eql(u8, s.def_step_id, cd)) {
                    in_cycle = true;
                    break;
                }
            }
            if (in_cycle) continue;

            // Check if this step depends on the old routing step
            const deps = try self.store.getStepDeps(alloc, s.id);
            for (deps) |dep_id| {
                if (std.mem.eql(u8, dep_id, routing_step.id)) {
                    // Add new dep to the new routing step instance
                    try self.store.insertStepDep(s.id, new_routing_id);
                    break;
                }
            }
        }

        // 10. Mark the routing step as completed (the current instance)
        const output = try std.fmt.allocPrint(alloc, "{{\"output\":\"cycle_back\",\"target\":\"{s}\",\"iteration\":{d}}}", .{ target_def_id, iteration_count });
        try self.store.updateStepStatus(routing_step.id, "completed", null, output, null, routing_step.attempt);
        try self.store.insertEvent(run_row.id, routing_step.id, "step.completed", output);
        log.info("cycle back from {s} to {s} (iteration {d})", .{ routing_step.def_step_id, target_def_id, iteration_count });

        return true;
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
            // Fire run.completed callbacks
            if (try self.store.getRun(alloc, run_id)) |run_row| {
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.completed", run_id, null, "{}", self.metrics);
            }
            log.info("run {s} completed", .{run_id});
        } else if (all_terminal and any_failed) {
            try self.store.updateRunStatus(run_id, "failed", "one or more steps failed");
            try self.store.insertEvent(run_id, null, "run.failed", "{}");
            // Fire run.failed callbacks
            if (try self.store.getRun(alloc, run_id)) |run_row| {
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.failed", run_id, null, "{}", self.metrics);
            }
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

    fn failStepWithError(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow, err_text: []const u8) !void {
        try self.store.updateStepStatus(step.id, "failed", null, null, err_text, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
    }
};

fn computeRetryDelayMs(cfg: RuntimeConfig, step: types.StepRow, now_ms: i64) i64 {
    var delay = cfg.retry_base_delay_ms;
    var remaining_exp = step.attempt - 1;
    while (remaining_exp > 0) : (remaining_exp -= 1) {
        if (delay >= cfg.retry_max_delay_ms) break;
        const doubled = delay * 2;
        delay = if (doubled > cfg.retry_max_delay_ms) cfg.retry_max_delay_ms else doubled;
    }

    const jitter_cap = if (cfg.retry_jitter_ms > 0) cfg.retry_jitter_ms else 0;
    var jitter: i64 = 0;
    if (jitter_cap > 0) {
        const seed = std.hash.Wyhash.hash(0, step.id);
        const mixed = seed ^ @as(u64, @intCast(now_ms));
        jitter = @as(i64, @intCast(mixed % @as(u64, @intCast(jitter_cap + 1))));
    }
    return delay + jitter;
}

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

/// Parse workflow_json to find a step definition by def_step_id and return a field as raw JSON.
/// Unlike getStepField which only returns strings, this serializes any JSON value type.
fn getStepFieldRaw(alloc: std.mem.Allocator, workflow_json: []const u8, def_step_id: []const u8, field: []const u8) !?[]const u8 {
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
        if (field_val == .string) {
            return try alloc.dupe(u8, field_val.string);
        }
        // Serialize non-string values as JSON
        var out: std.io.Writer.Allocating = .init(alloc);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.write(field_val) catch return null;
        return out.toOwnedSlice() catch return null;
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

/// Look up a generated ID by definition ID from parallel arrays.
fn lookupId(def_ids: []const []const u8, gen_ids: []const []const u8, target: []const u8) ?[]const u8 {
    for (def_ids, 0..) |did, i| {
        if (std.mem.eql(u8, did, target)) return gen_ids[i];
    }
    return null;
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

/// Parsed handoff target information.
const HandoffTarget = struct {
    tags: []const []const u8,
    tags_str: []const u8,
    message: ?[]const u8,
};

/// Extract handoff_to target from a worker output string.
/// Worker output may be raw text or JSON like: {"output": "...", "handoff_to": {"tags": [...], "message": "..."}}
fn extractHandoffTarget(alloc: std.mem.Allocator, output: []const u8) ?HandoffTarget {
    // Try to parse the output as JSON
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, output, .{}) catch return null;
    const root = parsed.value;
    if (root != .object) return null;

    const handoff_val = root.object.get("handoff_to") orelse return null;
    if (handoff_val != .object) return null;

    // Extract tags
    const tags_val = handoff_val.object.get("tags") orelse return null;
    if (tags_val != .array) return null;

    var tag_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var tags_str_buf: std.ArrayListUnmanaged(u8) = .empty;

    for (tags_val.array.items, 0..) |tag_item, i| {
        if (tag_item == .string) {
            tag_list.append(alloc, alloc.dupe(u8, tag_item.string) catch return null) catch return null;
            if (i > 0) tags_str_buf.append(alloc, ',') catch return null;
            tags_str_buf.appendSlice(alloc, tag_item.string) catch return null;
        }
    }

    if (tag_list.items.len == 0) return null;

    // Extract message (optional)
    var message: ?[]const u8 = null;
    if (handoff_val.object.get("message")) |msg_val| {
        if (msg_val == .string) {
            message = alloc.dupe(u8, msg_val.string) catch null;
        }
    }

    return HandoffTarget{
        .tags = tag_list.toOwnedSlice(alloc) catch return null,
        .tags_str = tags_str_buf.toOwnedSlice(alloc) catch return null,
        .message = message,
    };
}

/// Build a formatted chat transcript from chat messages.
fn buildChatTranscript(alloc: std.mem.Allocator, messages: []const types.ChatMessageRow) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (messages, 0..) |msg, i| {
        if (i > 0) try buf.appendSlice(alloc, "\\n");
        const line = try std.fmt.allocPrint(alloc, "[Round {d}] {s}: {s}", .{ msg.round, msg.role, msg.message });
        try buf.appendSlice(alloc, line);
    }
    return try buf.toOwnedSlice(alloc);
}

/// Build input_json payload that carries an already rendered prompt for child task steps.
fn buildRenderedPromptInputJson(alloc: std.mem.Allocator, rendered_prompt: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(alloc, .{
        .rendered_prompt = rendered_prompt,
    }, .{});
}

/// Extract optional input_json.rendered_prompt for dynamic child task execution.
fn extractRenderedPromptFromInput(alloc: std.mem.Allocator, input_json: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, input_json, .{}) catch {
        return null;
    };
    const root = parsed.value;
    if (root != .object) return null;
    const rendered = root.object.get("rendered_prompt") orelse return null;
    if (rendered != .string) return null;
    return alloc.dupe(u8, rendered.string) catch null;
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
    try store.insertRun("r1", null, "running", "{\"steps\":[]}", "{}", "[]");

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

    try store.insertRun("r1", null, "running", "{\"steps\":[]}", "{}", "[]");
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

    try store.insertRun("r1", null, "running", "{\"steps\":[]}", "{}", "[]");
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
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

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
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
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
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
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
    try store.insertRun("r1", null, "running", wf, input, "[]");
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

test "build/extract rendered_prompt input JSON round-trip" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const input_json = try buildRenderedPromptInputJson(arena.allocator(), "say \"hi\"\\nnext");
    const prompt = extractRenderedPromptFromInput(arena.allocator(), input_json);
    try std.testing.expect(prompt != null);
    try std.testing.expectEqualStrings("say \"hi\"\\nnext", prompt.?);
}

test "Engine: task step fallback uses input_json.rendered_prompt" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("r-rendered", null, "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertWorker("w-rendered", "http://127.0.0.1:1", "", "webhook", null, "[]", 1, "registered");
    try store.insertStep("parent-step", "r-rendered", "missing-parent-def", "task", "completed", "{}", 1, null, null, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const rendered_input = try buildRenderedPromptInputJson(arena.allocator(), "child fallback prompt");
    try store.insertStep(
        "child-step",
        "r-rendered",
        "missing-child-def",
        "task",
        "ready",
        rendered_input,
        2,
        null,
        "parent-step",
        0,
    );

    var engine = Engine.init(&store, allocator, 500);
    const run_row = (try store.getRun(arena.allocator(), "r-rendered")).?;
    try engine.processRun(arena.allocator(), run_row);

    const child = (try store.getStep(arena.allocator(), "child-step")).?;
    try std.testing.expectEqualStrings("ready", child.status);
    try std.testing.expectEqual(@as(i64, 2), child.attempt);
}

test "Engine: rendered_prompt has priority over parent prompt_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"parent","type":"debate","prompt_template":"parent template"},{"id":"child","type":"task","prompt_template":"child template"}]}
    ;
    try store.insertRun("r-priority", null, "running", wf, "{}", "[]");
    try store.insertStep("parent-step", "r-priority", "parent", "debate", "running", "{}", 1, null, null, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const rendered_input = try buildRenderedPromptInputJson(arena.allocator(), "rendered prompt");
    try store.insertStep(
        "child-step",
        "r-priority",
        "child",
        "task",
        "ready",
        rendered_input,
        1,
        null,
        "parent-step",
        0,
    );

    var engine = Engine.init(&store, allocator, 500);
    const run_row = (try store.getRun(arena.allocator(), "r-priority")).?;
    const child_step = (try store.getStep(arena.allocator(), "child-step")).?;
    const source = (try engine.resolveTaskPromptSource(arena.allocator(), run_row, child_step)).?;

    switch (source) {
        .rendered => |prompt| try std.testing.expectEqualStrings("rendered prompt", prompt),
        .template => try std.testing.expect(false),
    }
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
        .next_attempt_at_ms = null,
        .parent_step_id = null,
        .item_index = null,
        .created_at_ms = 0,
        .updated_at_ms = 0,
        .started_at_ms = null,
        .ended_at_ms = null,
        .child_run_id = null,
        .iteration_index = 0,
    };
}

// ── Transform step tests ─────────────────────────────────────────────

test "Engine: transform step renders output_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"t1","type":"task","prompt_template":"hello"},{"id":"tr1","type":"transform","output_template":"result: {{steps.t1.output}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    // Insert task1 as completed with output
    try store.insertStep("step_t1", "r1", "t1", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_t1", "completed", null, "{\"output\":\"hello\"}", null, 1);

    // Insert transform1 as ready with dependency on task1
    try store.insertStep("step_tr1", "r1", "tr1", "transform", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_tr1", "step_t1");

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Verify transform completed
    const s = (try store.getStep(arena.allocator(), "step_tr1")).?;
    try std.testing.expectEqualStrings("completed", s.status);
    // Output should contain the rendered template
    try std.testing.expect(s.output_json != null);
    // The output should contain "hello" from the task step
    try std.testing.expect(std.mem.indexOf(u8, s.output_json.?, "hello") != null);
}

test "Engine: transform step fails without output_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"tr1","type":"transform"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_tr1", "r1", "tr1", "transform", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const s = (try store.getStep(arena.allocator(), "step_tr1")).?;
    try std.testing.expectEqualStrings("failed", s.status);
    try std.testing.expect(s.error_text != null);
}

// ── Wait step tests ──────────────────────────────────────────────────

test "Engine: wait step with duration_ms=0 completes after two ticks" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"w1","type":"wait","duration_ms":0}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_w1", "r1", "w1", "wait", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // First tick: step becomes "running" with started_at_ms
    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const s1 = (try store.getStep(arena.allocator(), "step_w1")).?;
    try std.testing.expectEqualStrings("running", s1.status);
    try std.testing.expect(s1.started_at_ms != null);

    // Second tick: step should be "completed" since duration=0
    const run_row2 = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row2);

    const s2 = (try store.getStep(arena.allocator(), "step_w1")).?;
    try std.testing.expectEqualStrings("completed", s2.status);
    try std.testing.expect(s2.output_json != null);
}

test "Engine: wait step with signal enters waiting_approval" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"w1","type":"wait","signal":"deploy"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_w1", "r1", "w1", "wait", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const s = (try store.getStep(arena.allocator(), "step_w1")).?;
    try std.testing.expectEqualStrings("waiting_approval", s.status);
}

test "Engine: wait step without config fails" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"w1","type":"wait"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_w1", "r1", "w1", "wait", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const s = (try store.getStep(arena.allocator(), "step_w1")).?;
    try std.testing.expectEqualStrings("failed", s.status);
}

test "Engine: wait step with invalid duration string fails" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"w1","type":"wait","duration_ms":"abc"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_w1", "r1", "w1", "wait", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const s = (try store.getStep(arena.allocator(), "step_w1")).?;
    try std.testing.expectEqualStrings("failed", s.status);
    try std.testing.expect(s.error_text != null);
    try std.testing.expect(std.mem.indexOf(u8, s.error_text.?, "duration_ms must be an integer") != null);
}

// ── Router step tests ────────────────────────────────────────────────

test "Engine: router step routes to matching target" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"classify","type":"task","prompt_template":"classify"},{"id":"router1","type":"router","routes":{"bug":"fix_bug","feature":"add_feature"}},{"id":"fix_bug","type":"task","prompt_template":"fix"},{"id":"add_feature","type":"task","prompt_template":"add"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    // classify step completed with "bug" in output
    try store.insertStep("step_classify", "r1", "classify", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_classify", "completed", null, "{\"output\":\"this is a bug report\"}", null, 1);

    // router step is ready, depends on classify
    try store.insertStep("step_router", "r1", "router1", "router", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_router", "step_classify");

    // Target steps are pending
    try store.insertStep("step_fix", "r1", "fix_bug", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step_fix", "step_router");
    try store.insertStep("step_add", "r1", "add_feature", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step_add", "step_router");

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Router should be completed
    const router = (try store.getStep(arena.allocator(), "step_router")).?;
    try std.testing.expectEqualStrings("completed", router.status);
    try std.testing.expect(router.output_json != null);
    try std.testing.expect(std.mem.indexOf(u8, router.output_json.?, "fix_bug") != null);

    // add_feature should be skipped
    const add = (try store.getStep(arena.allocator(), "step_add")).?;
    try std.testing.expectEqualStrings("skipped", add.status);

    // fix_bug should still be pending (not skipped)
    const fix = (try store.getStep(arena.allocator(), "step_fix")).?;
    try std.testing.expectEqualStrings("pending", fix.status);
}

test "Engine: router step uses default when no match" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"classify","type":"task","prompt_template":"classify"},{"id":"router1","type":"router","routes":{"bug":"fix_bug"},"default":"fix_bug"},{"id":"fix_bug","type":"task","prompt_template":"fix"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    // classify step completed with something that doesn't match any route
    try store.insertStep("step_classify", "r1", "classify", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_classify", "completed", null, "{\"output\":\"unknown category\"}", null, 1);

    // router step is ready
    try store.insertStep("step_router", "r1", "router1", "router", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_router", "step_classify");

    // Target step
    try store.insertStep("step_fix", "r1", "fix_bug", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step_fix", "step_router");

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Router should be completed with default target
    const router = (try store.getStep(arena.allocator(), "step_router")).?;
    try std.testing.expectEqualStrings("completed", router.status);
    try std.testing.expect(router.output_json != null);
    try std.testing.expect(std.mem.indexOf(u8, router.output_json.?, "fix_bug") != null);
}

test "Engine: router step fails without routes" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"classify","type":"task","prompt_template":"classify"},{"id":"router1","type":"router"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    try store.insertStep("step_classify", "r1", "classify", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_classify", "completed", null, "{\"output\":\"test\"}", null, 1);

    try store.insertStep("step_router", "r1", "router1", "router", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_router", "step_classify");

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const router = (try store.getStep(arena.allocator(), "step_router")).?;
    try std.testing.expectEqualStrings("failed", router.status);
}

// ── getStepFieldRaw tests ────────────────────────────────────────────

test "getStepFieldRaw returns JSON object as string" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"steps":[{"id":"r1","type":"router","routes":{"bug":"fix_bug","feature":"add_feature"}}]}
    ;
    const result = try getStepFieldRaw(arena.allocator(), wf, "r1", "routes");
    try std.testing.expect(result != null);
    // Should be a JSON string containing the routes object
    try std.testing.expect(std.mem.indexOf(u8, result.?, "bug") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "fix_bug") != null);
}

test "getStepFieldRaw returns string values directly" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"steps":[{"id":"r1","type":"router","default":"fallback"}]}
    ;
    const result = try getStepFieldRaw(arena.allocator(), wf, "r1", "default");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("fallback", result.?);
}

// ── Loop step tests ──────────────────────────────────────────────────

test "Engine: loop step creates first iteration children" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow: loop with body ["t1"] — single body step for simplicity
    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":3,"exit_condition":"done","body":["t1"]},{"id":"t1","type":"task","prompt_template":"do work"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Loop step should be "running"
    const loop_step = (try store.getStep(arena.allocator(), "step_loop")).?;
    try std.testing.expectEqualStrings("running", loop_step.status);

    // Should have created 1 child step
    const children = try store.getChildSteps(arena.allocator(), "step_loop");
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expectEqualStrings("ready", children[0].status);
    try std.testing.expectEqualStrings("t1", children[0].def_step_id);
    try std.testing.expectEqual(@as(i64, 0), children[0].iteration_index);
}

test "Engine: loop step iterates until exit condition" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":5,"exit_condition":"done","body":["t1"]},{"id":"t1","type":"task","prompt_template":"do work"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates iteration 0 children, marks loop as running
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Get the first child and mark it completed with "not done"
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        try std.testing.expectEqual(@as(usize, 1), children.len);
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"not done\"}", null, 1);
    }

    // Tick 2: exit condition "done" not in "not done"... wait, "not done" contains "done"!
    // Let's use a different output that doesn't contain "done"
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        // Fix: update to something that doesn't contain "done"
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"still working\"}", null, 1);
    }

    // Tick 2: exit condition not met, creates iteration 1
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Should now have 2 children (iteration 0 and 1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        try std.testing.expectEqual(@as(usize, 2), children.len);
    }

    // Mark iteration 1 child as completed with "done" in output
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        // Find iteration 1 child
        for (children) |child| {
            if (child.iteration_index == 1) {
                try store.updateStepStatus(child.id, "completed", null, "{\"output\":\"done\"}", null, 1);
            }
        }
    }

    // Tick 3: exit condition met, loop completes
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Loop should be completed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loop_step = (try store.getStep(arena.allocator(), "step_loop")).?;
        try std.testing.expectEqualStrings("completed", loop_step.status);
        try std.testing.expect(loop_step.output_json != null);
    }
}

test "Engine: loop step stops at max_iterations" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":2,"exit_condition":"never_match","body":["t1"]},{"id":"t1","type":"task","prompt_template":"do work"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates iteration 0
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete iteration 0 child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"result0\"}", null, 1);
    }

    // Tick 2: creates iteration 1
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete iteration 1 child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        for (children) |child| {
            if (child.iteration_index == 1) {
                try store.updateStepStatus(child.id, "completed", null, "{\"output\":\"result1\"}", null, 1);
            }
        }
    }

    // Tick 3: max_iterations=2 reached (iterations 0,1), loop completes
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Loop should be completed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loop_step = (try store.getStep(arena.allocator(), "step_loop")).?;
        try std.testing.expectEqualStrings("completed", loop_step.status);
    }
}

test "Engine: loop step fails when child fails" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":3,"exit_condition":"done","body":["t1"]},{"id":"t1","type":"task","prompt_template":"do work"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates iteration 0
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Mark child as failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        try store.updateStepStatus(children[0].id, "failed", null, null, "child error", 1);
    }

    // Tick 2: loop should fail
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loop_step = (try store.getStep(arena.allocator(), "step_loop")).?;
        try std.testing.expectEqualStrings("failed", loop_step.status);
    }
}

test "Engine: loop step with multiple body steps chains them" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":1,"exit_condition":"done","body":["s1","s2"]},{"id":"s1","type":"task","prompt_template":"step1"},{"id":"s2","type":"task","prompt_template":"step2"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates iteration 0 with 2 body steps chained
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_loop");
        try std.testing.expectEqual(@as(usize, 2), children.len);

        // First child (s1) should be "ready", second (s2) should be "pending"
        // Children are ordered by item_index ASC
        var ready_count: usize = 0;
        var pending_count: usize = 0;
        for (children) |child| {
            if (std.mem.eql(u8, child.status, "ready")) ready_count += 1;
            if (std.mem.eql(u8, child.status, "pending")) pending_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), ready_count);
        try std.testing.expectEqual(@as(usize, 1), pending_count);
    }
}

// ── Sub-workflow step tests ──────────────────────────────────────────

test "Engine: sub_workflow step creates child run" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Parent workflow has a sub_workflow step with inline workflow
    const wf =
        \\{"steps":[{"id":"sub1","type":"sub_workflow","workflow":{"steps":[{"id":"inner1","type":"task","prompt_template":"inner work"}]}}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_sub", "r1", "sub1", "sub_workflow", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates child run and marks sub_workflow as running
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Verify sub_workflow step is "running" and has child_run_id
    var child_run_id: []const u8 = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        try std.testing.expectEqualStrings("running", sub_step.status);
        try std.testing.expect(sub_step.child_run_id != null);
        child_run_id = try allocator.dupe(u8, sub_step.child_run_id.?);
    }
    defer allocator.free(child_run_id);

    // Verify child run exists and has steps
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const child_run = (try store.getRun(arena.allocator(), child_run_id)).?;
        try std.testing.expectEqualStrings("running", child_run.status);

        const child_steps = try store.getStepsByRun(arena.allocator(), child_run_id);
        try std.testing.expectEqual(@as(usize, 1), child_steps.len);
        try std.testing.expectEqualStrings("inner1", child_steps[0].def_step_id);
        try std.testing.expectEqualStrings("ready", child_steps[0].status);
    }
}

test "Engine: sub_workflow step completes when child run completes" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"sub1","type":"sub_workflow","workflow":{"steps":[{"id":"inner1","type":"task","prompt_template":"inner work"}]}}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_sub", "r1", "sub1", "sub_workflow", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates child run
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Get child run ID and manually complete its step + run
    var child_run_id: []const u8 = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        child_run_id = try allocator.dupe(u8, sub_step.child_run_id.?);
    }
    defer allocator.free(child_run_id);

    // Complete the child run's step
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const child_steps = try store.getStepsByRun(arena.allocator(), child_run_id);
        try store.updateStepStatus(child_steps[0].id, "completed", null, "{\"output\":\"inner result\"}", null, 1);
    }

    // Mark child run as completed
    try store.updateRunStatus(child_run_id, "completed", null);

    // Tick 2: sub_workflow should detect child run completed and complete itself
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Verify sub_workflow step completed with child's output
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        try std.testing.expectEqualStrings("completed", sub_step.status);
        try std.testing.expect(sub_step.output_json != null);
        try std.testing.expect(std.mem.indexOf(u8, sub_step.output_json.?, "inner result") != null);
    }
}

test "Engine: sub_workflow step fails when child run fails" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"sub1","type":"sub_workflow","workflow":{"steps":[{"id":"inner1","type":"task","prompt_template":"inner work"}]}}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_sub", "r1", "sub1", "sub_workflow", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates child run
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Get child run ID
    var child_run_id: []const u8 = undefined;
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        child_run_id = try allocator.dupe(u8, sub_step.child_run_id.?);
    }
    defer allocator.free(child_run_id);

    // Mark child run as failed
    try store.updateRunStatus(child_run_id, "failed", "inner step failed");

    // Tick 2: sub_workflow should detect child run failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Verify sub_workflow step failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        try std.testing.expectEqualStrings("failed", sub_step.status);
        try std.testing.expect(sub_step.error_text != null);
    }
}

test "Engine: sub_workflow step fails without workflow" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"sub1","type":"sub_workflow"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_sub", "r1", "sub1", "sub_workflow", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const sub_step = (try store.getStep(arena.allocator(), "step_sub")).?;
        try std.testing.expectEqualStrings("failed", sub_step.status);
    }
}

test "Engine: loop step fails without body" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"loop1","type":"loop","max_iterations":3,"exit_condition":"done"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_loop", "r1", "loop1", "loop", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const loop_step = (try store.getStep(arena.allocator(), "step_loop")).?;
        try std.testing.expectEqualStrings("failed", loop_step.status);
    }
}

// ── Debate step tests ────────────────────────────────────────────────

test "Engine: debate step creates participant children" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2,"worker_tags":["reviewer"],"judge_tags":["senior"],"prompt_template":"Review this code","judge_template":"Pick the best:\n{{debate_responses}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Debate step should be "running"
    const debate_step = (try store.getStep(arena.allocator(), "step_debate")).?;
    try std.testing.expectEqualStrings("running", debate_step.status);

    // Should have 2 participant children
    const children = try store.getChildSteps(arena.allocator(), "step_debate");
    try std.testing.expectEqual(@as(usize, 2), children.len);

    for (children) |child| {
        try std.testing.expectEqualStrings("ready", child.status);
        try std.testing.expectEqualStrings("task", child.type);
    }
}

test "Engine: debate step fails without count" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","prompt_template":"Review this"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const step = (try store.getStep(arena.allocator(), "step_debate")).?;
    try std.testing.expectEqualStrings("failed", step.status);
}

test "Engine: debate step fails without prompt_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const step = (try store.getStep(arena.allocator(), "step_debate")).?;
    try std.testing.expectEqualStrings("failed", step.status);
}

test "Engine: debate step creates judge after participants complete" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2,"worker_tags":["reviewer"],"judge_tags":["senior"],"prompt_template":"Review this code","judge_template":"Pick the best:\n{{debate_responses}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates participant children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete both participant children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        try std.testing.expectEqual(@as(usize, 2), children.len);
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"review A\"}", null, 1);
        try store.updateStepStatus(children[1].id, "completed", null, "{\"output\":\"review B\"}", null, 1);
    }

    // Tick 2: should create judge child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Should now have 3 children (2 participants + 1 judge)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        try std.testing.expectEqual(@as(usize, 3), children.len);

        // Find judge child
        var found_judge = false;
        for (children) |child| {
            if (std.mem.indexOf(u8, child.def_step_id, "_judge") != null) {
                found_judge = true;
                try std.testing.expectEqualStrings("ready", child.status);
                try std.testing.expectEqualStrings("task", child.type);
            }
        }
        try std.testing.expect(found_judge);
    }
}

test "Engine: debate step completes when judge completes" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2,"prompt_template":"Review this","judge_template":"Pick best: {{debate_responses}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates participant children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete participants
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"A\"}", null, 1);
        try store.updateStepStatus(children[1].id, "completed", null, "{\"output\":\"B\"}", null, 1);
    }

    // Tick 2: creates judge child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete the judge child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        for (children) |child| {
            if (std.mem.indexOf(u8, child.def_step_id, "_judge") != null) {
                try store.updateStepStatus(child.id, "completed", null, "{\"output\":\"A is best\"}", null, 1);
            }
        }
    }

    // Tick 3: debate should be completed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const debate_step = (try store.getStep(arena.allocator(), "step_debate")).?;
        try std.testing.expectEqualStrings("completed", debate_step.status);
        try std.testing.expect(debate_step.output_json != null);
        try std.testing.expect(std.mem.indexOf(u8, debate_step.output_json.?, "A is best") != null);
    }
}

test "Engine: debate step completes without judge_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // No judge_template — should complete with collected responses when participants are done
    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2,"prompt_template":"Review this"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates participant children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete participants
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"review 1\"}", null, 1);
        try store.updateStepStatus(children[1].id, "completed", null, "{\"output\":\"review 2\"}", null, 1);
    }

    // Tick 2: no judge_template, should complete with responses
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const debate_step = (try store.getStep(arena.allocator(), "step_debate")).?;
        try std.testing.expectEqualStrings("completed", debate_step.status);
        try std.testing.expect(debate_step.output_json != null);
    }
}

test "Engine: debate step fails when participant fails" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"review","type":"debate","count":2,"prompt_template":"Review this","judge_template":"Pick: {{debate_responses}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_debate", "r1", "review", "debate", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates participant children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Fail one participant
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_debate");
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"review A\"}", null, 1);
        try store.updateStepStatus(children[1].id, "failed", null, null, "worker error", 1);
    }

    // Tick 2: debate should fail
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const debate_step = (try store.getStep(arena.allocator(), "step_debate")).?;
        try std.testing.expectEqualStrings("failed", debate_step.status);
    }
}

// ── Group chat step tests ────────────────────────────────────────────

test "Engine: group_chat step parses participants and starts" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"discuss","type":"group_chat","participants":[{"tags":["architect"],"role":"Architect"},{"tags":["security"],"role":"Security"}],"max_rounds":3,"exit_condition":"CONSENSUS","prompt_template":"Discuss: topic","round_template":"Previous:\n{{chat_history}}\nYour role: {{role}}. Respond."}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_gc", "r1", "discuss", "group_chat", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // group_chat step should be "running"
    const gc_step = (try store.getStep(arena.allocator(), "step_gc")).?;
    try std.testing.expectEqualStrings("running", gc_step.status);
}

test "Engine: group_chat step fails without participants" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"discuss","type":"group_chat","prompt_template":"Discuss"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_gc", "r1", "discuss", "group_chat", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const step = (try store.getStep(arena.allocator(), "step_gc")).?;
    try std.testing.expectEqualStrings("failed", step.status);
}

test "Engine: group_chat step fails without prompt_template" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"discuss","type":"group_chat","participants":[{"tags":["a"],"role":"A"}]}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_gc", "r1", "discuss", "group_chat", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const step = (try store.getStep(arena.allocator(), "step_gc")).?;
    try std.testing.expectEqualStrings("failed", step.status);
}

test "Engine: group_chat builds chat history across rounds" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Manually insert chat messages and test the poll logic
    const wf =
        \\{"steps":[{"id":"discuss","type":"group_chat","participants":[{"tags":["a"],"role":"Architect"},{"tags":["b"],"role":"Security"}],"max_rounds":2,"exit_condition":"CONSENSUS","prompt_template":"Discuss topic","round_template":"Previous:\n{{chat_history}}\nYour role: {{role}}. Respond."}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_gc", "r1", "discuss", "group_chat", "running", "{}", 1, null, null, null);

    // Insert round 1 messages (simulating what dispatch would produce)
    try store.insertChatMessage("r1", "step_gc", 1, "Architect", null, "I suggest microservices");
    try store.insertChatMessage("r1", "step_gc", 1, "Security", null, "We need auth first");

    var engine = Engine.init(&store, allocator, 500);

    // Poll: round 1 complete, no CONSENSUS, max_rounds=2, so it should try round 2
    // Since no workers, dispatch will fail silently. Then next poll round_count stays at 2 for round 1.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Step should still be running (no workers to dispatch round 2)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const step = (try store.getStep(arena.allocator(), "step_gc")).?;
        try std.testing.expectEqualStrings("running", step.status);
    }

    // Simulate round 2 messages with CONSENSUS
    try store.insertChatMessage("r1", "step_gc", 2, "Architect", null, "CONSENSUS reached");
    try store.insertChatMessage("r1", "step_gc", 2, "Security", null, "Agreed, CONSENSUS");

    // Poll: round 2 complete with CONSENSUS, should complete
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const step = (try store.getStep(arena.allocator(), "step_gc")).?;
        try std.testing.expectEqualStrings("completed", step.status);
        try std.testing.expect(step.output_json != null);
    }
}

test "Engine: group_chat completes at max_rounds" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"discuss","type":"group_chat","participants":[{"tags":["a"],"role":"A"},{"tags":["b"],"role":"B"}],"max_rounds":1,"exit_condition":"NEVER_MATCH","prompt_template":"Discuss","round_template":"{{chat_history}} {{role}}"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_gc", "r1", "discuss", "group_chat", "running", "{}", 1, null, null, null);

    // Insert round 1 messages (no exit condition match)
    try store.insertChatMessage("r1", "step_gc", 1, "A", null, "hello");
    try store.insertChatMessage("r1", "step_gc", 1, "B", null, "world");

    var engine = Engine.init(&store, allocator, 500);

    // Poll: round 1 complete, no exit match, max_rounds=1, should complete
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const step = (try store.getStep(arena.allocator(), "step_gc")).?;
        try std.testing.expectEqualStrings("completed", step.status);
    }
}

test "buildChatTranscript formats messages" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const messages = [_]types.ChatMessageRow{
        .{ .id = 1, .run_id = "r1", .step_id = "s1", .round = 1, .role = "Architect", .worker_id = null, .message = "hello", .ts_ms = 1000 },
        .{ .id = 2, .run_id = "r1", .step_id = "s1", .round = 1, .role = "Security", .worker_id = null, .message = "world", .ts_ms = 1001 },
    };

    const transcript = try buildChatTranscript(arena.allocator(), &messages);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Architect") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "Security") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, transcript, "world") != null);
}

// ── Saga step tests ──────────────────────────────────────────────────

test "Engine: saga step creates first body child and initializes state" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"deploy_saga","type":"saga","body":["provision","deploy","verify"],"compensations":{"provision":"deprovision","deploy":"rollback_deploy"}},{"id":"provision","type":"task","prompt_template":"provision"},{"id":"deploy","type":"task","prompt_template":"deploy"},{"id":"verify","type":"task","prompt_template":"verify"},{"id":"deprovision","type":"task","prompt_template":"deprovision"},{"id":"rollback_deploy","type":"task","prompt_template":"rollback"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_saga", "r1", "deploy_saga", "saga", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Saga step should be "running"
    const saga_step = (try store.getStep(arena.allocator(), "step_saga")).?;
    try std.testing.expectEqualStrings("running", saga_step.status);

    // Should have created 1 child step (first body step)
    const children = try store.getChildSteps(arena.allocator(), "step_saga");
    try std.testing.expectEqual(@as(usize, 1), children.len);
    try std.testing.expectEqualStrings("provision", children[0].def_step_id);
    try std.testing.expectEqualStrings("ready", children[0].status);

    // Should have saga_state entries
    const saga_states = try store.getSagaStates(arena.allocator(), "r1", "step_saga");
    try std.testing.expectEqual(@as(usize, 3), saga_states.len);
    try std.testing.expectEqualStrings("pending", saga_states[0].status);
    try std.testing.expectEqualStrings("pending", saga_states[1].status);
    try std.testing.expectEqualStrings("pending", saga_states[2].status);
}

test "Engine: saga step executes body sequentially and completes" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"saga1","type":"saga","body":["s1","s2"],"compensations":{"s1":"c1"}},{"id":"s1","type":"task","prompt_template":"step1"},{"id":"s2","type":"task","prompt_template":"step2"},{"id":"c1","type":"task","prompt_template":"comp1"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_saga", "r1", "saga1", "saga", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates first body child (s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete first body child (s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        try std.testing.expectEqual(@as(usize, 1), children.len);
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"provisioned\"}", null, 1);
    }

    // Tick 2: detects s1 completed, creates s2
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Should now have 2 children
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        try std.testing.expectEqual(@as(usize, 2), children.len);
    }

    // Complete second body child (s2)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        for (children) |child| {
            if (std.mem.eql(u8, child.def_step_id, "s2")) {
                try store.updateStepStatus(child.id, "completed", null, "{\"output\":\"deployed\"}", null, 1);
            }
        }
    }

    // Tick 3: detects s2 completed, all body steps done, saga completes
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Tick 4: saga polls — should now detect all completed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Saga should be completed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const saga_step = (try store.getStep(arena.allocator(), "step_saga")).?;
        try std.testing.expectEqualStrings("completed", saga_step.status);
        try std.testing.expect(saga_step.output_json != null);
    }
}

test "Engine: saga step runs compensation in reverse on failure" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"saga1","type":"saga","body":["s1","s2"],"compensations":{"s1":"c1","s2":"c2"}},{"id":"s1","type":"task","prompt_template":"step1"},{"id":"s2","type":"task","prompt_template":"step2"},{"id":"c1","type":"task","prompt_template":"comp1"},{"id":"c2","type":"task","prompt_template":"comp2"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_saga", "r1", "saga1", "saga", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates first body child (s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Complete first body child (s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        try store.updateStepStatus(children[0].id, "completed", null, "{\"output\":\"provisioned\"}", null, 1);
    }

    // Tick 2: creates s2
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Fail second body child (s2)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        for (children) |child| {
            if (std.mem.eql(u8, child.def_step_id, "s2")) {
                try store.updateStepStatus(child.id, "failed", null, null, "deploy failed", 1);
            }
        }
    }

    // Tick 3: detects s2 failed, starts compensation (s1 was completed, so compensate s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Tick 4: compensation child creation may happen here
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Should have created compensation child for s1
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        var found_comp = false;
        for (children) |child| {
            if (std.mem.eql(u8, child.def_step_id, "c1")) {
                found_comp = true;
            }
        }
        try std.testing.expect(found_comp);
    }

    // Complete the compensation child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        for (children) |child| {
            if (std.mem.eql(u8, child.def_step_id, "c1")) {
                try store.updateStepStatus(child.id, "completed", null, "{\"output\":\"deprovisioned\"}", null, 1);
            }
        }
    }

    // Tick 5: compensation done
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Tick 6: saga should finalize as failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Saga should be failed with compensation output
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const saga_step = (try store.getStep(arena.allocator(), "step_saga")).?;
        try std.testing.expectEqualStrings("failed", saga_step.status);
        try std.testing.expect(saga_step.output_json != null);
        // Output should contain failed_at and compensated
        try std.testing.expect(std.mem.indexOf(u8, saga_step.output_json.?, "failed_at") != null);
        try std.testing.expect(std.mem.indexOf(u8, saga_step.output_json.?, "compensated") != null);
    }
}

test "Engine: saga step fails immediately with no completed steps to compensate" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"saga1","type":"saga","body":["s1"],"compensations":{"s1":"c1"}},{"id":"s1","type":"task","prompt_template":"step1"},{"id":"c1","type":"task","prompt_template":"comp1"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_saga", "r1", "saga1", "saga", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: creates first body child (s1)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Fail the first body child
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const children = try store.getChildSteps(arena.allocator(), "step_saga");
        try store.updateStepStatus(children[0].id, "failed", null, null, "provision failed", 1);
    }

    // Tick 2: detects s1 failed, no completed steps, saga fails immediately
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const saga_step = (try store.getStep(arena.allocator(), "step_saga")).?;
        try std.testing.expectEqualStrings("failed", saga_step.status);
        try std.testing.expect(saga_step.output_json != null);
        try std.testing.expect(std.mem.indexOf(u8, saga_step.output_json.?, "compensated\":[]") != null);
    }
}

test "Engine: saga step fails without body" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"saga1","type":"saga"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_saga", "r1", "saga1", "saga", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const saga_step = (try store.getStep(arena.allocator(), "step_saga")).?;
    try std.testing.expectEqualStrings("failed", saga_step.status);
}

// ── Graph cycle tests ────────────────────────────────────────────────

test "Engine: condition routes back to earlier step creates new instances" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow: compute -> check -> (if true_target=compute, false_target=done)
    const wf =
        \\{"steps":[{"id":"compute","type":"task","prompt_template":"compute","depends_on":[]},{"id":"check","type":"condition","expression":"retry","true_target":"compute","false_target":"done","depends_on":["compute"]},{"id":"done","type":"task","prompt_template":"done","depends_on":["check"]}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    // Step "compute" completed
    try store.insertStep("step_compute", "r1", "compute", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_compute", "completed", null, "{\"output\":\"retry this\"}", null, 1);

    // Step "check" is ready, depends on compute
    try store.insertStep("step_check", "r1", "check", "condition", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_check", "step_compute");

    // Step "done" is pending
    try store.insertStep("step_done", "r1", "done", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step_done", "step_check");

    var engine = Engine.init(&store, allocator, 500);

    // Tick 1: condition evaluates to true, target "compute" is already completed
    //         Should detect cycle and create new step instances
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Verify: condition step should be completed with cycle_back output
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const check_step = (try store.getStep(arena.allocator(), "step_check")).?;
        try std.testing.expectEqualStrings("completed", check_step.status);
        try std.testing.expect(check_step.output_json != null);
        try std.testing.expect(std.mem.indexOf(u8, check_step.output_json.?, "cycle_back") != null);
    }

    // Verify: new step instances were created (total steps > 3)
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const all_steps = try store.getStepsByRun(arena.allocator(), "r1");
        // Original: compute, check, done = 3
        // New: compute(iter1), check(iter1) = 2 more
        try std.testing.expect(all_steps.len > 3);

        // Find new compute instance with iteration_index > 0
        var found_new_compute = false;
        for (all_steps) |s| {
            if (std.mem.eql(u8, s.def_step_id, "compute") and s.iteration_index > 0) {
                found_new_compute = true;
                try std.testing.expectEqualStrings("ready", s.status);
            }
        }
        try std.testing.expect(found_new_compute);
    }

    // Verify cycle_state was updated
    {
        const cycle_state = try store.getCycleState("r1", "cycle_check");
        try std.testing.expect(cycle_state != null);
        try std.testing.expectEqual(@as(i64, 1), cycle_state.?.iteration_count);
    }
}

test "Engine: graph cycle respects max_cycle_iterations" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow with max_cycle_iterations=1
    const wf =
        \\{"steps":[{"id":"compute","type":"task","prompt_template":"compute"},{"id":"check","type":"condition","expression":"retry","true_target":"compute","false_target":"done","max_cycle_iterations":1,"depends_on":["compute"]},{"id":"done","type":"task","prompt_template":"done","depends_on":["check"]}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");

    // Pre-set cycle state to max
    try store.upsertCycleState("r1", "cycle_check", 1, 1);

    // compute completed
    try store.insertStep("step_compute", "r1", "compute", "task", "completed", "{}", 1, null, null, null);
    try store.updateStepStatus("step_compute", "completed", null, "{\"output\":\"retry\"}", null, 1);

    // check is ready
    try store.insertStep("step_check", "r1", "check", "condition", "ready", "{}", 1, null, null, null);
    try store.insertStepDep("step_check", "step_compute");

    // done is pending
    try store.insertStep("step_done", "r1", "done", "task", "pending", "{}", 1, null, null, null);
    try store.insertStepDep("step_done", "step_check");

    var engine = Engine.init(&store, allocator, 500);

    // Tick: condition should fail because cycle limit exceeded
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run_row = (try store.getRun(arena.allocator(), "r1")).?;
        try engine.processRun(arena.allocator(), run_row);
    }

    // Check step should be failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const check_step = (try store.getStep(arena.allocator(), "step_check")).?;
        try std.testing.expectEqualStrings("failed", check_step.status);
        try std.testing.expect(check_step.error_text != null);
        try std.testing.expect(std.mem.indexOf(u8, check_step.error_text.?, "exceeded") != null);
    }

    // Run should be failed
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const run = (try store.getRun(arena.allocator(), "r1")).?;
        try std.testing.expectEqualStrings("failed", run.status);
    }
}

// ── Worker handoff tests ─────────────────────────────────────────────

test "extractHandoffTarget parses handoff_to from output" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"output":"cannot handle","handoff_to":{"tags":["security_expert"],"message":"needs security review"}}
    ;
    const target = extractHandoffTarget(arena.allocator(), output);
    try std.testing.expect(target != null);
    try std.testing.expectEqual(@as(usize, 1), target.?.tags.len);
    try std.testing.expectEqualStrings("security_expert", target.?.tags[0]);
    try std.testing.expect(target.?.message != null);
    try std.testing.expectEqualStrings("needs security review", target.?.message.?);
}

test "extractHandoffTarget returns null for normal output" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"output":"all good, no handoff needed"}
    ;
    const target = extractHandoffTarget(arena.allocator(), output);
    try std.testing.expect(target == null);
}

test "extractHandoffTarget returns null for non-JSON output" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const target = extractHandoffTarget(arena.allocator(), "plain text output");
    try std.testing.expect(target == null);
}

test "extractHandoffTarget handles handoff without message" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"output":"redirect","handoff_to":{"tags":["expert"]}}
    ;
    const target = extractHandoffTarget(arena.allocator(), output);
    try std.testing.expect(target != null);
    try std.testing.expectEqual(@as(usize, 1), target.?.tags.len);
    try std.testing.expectEqualStrings("expert", target.?.tags[0]);
    try std.testing.expect(target.?.message == null);
}

test "Engine: task step stays ready when no workers available (handoff path)" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"steps":[{"id":"t1","type":"task","prompt_template":"do work"}]}
    ;
    try store.insertRun("r1", null, "running", wf, "{}", "[]");
    try store.insertStep("step_t1", "r1", "t1", "task", "ready", "{}", 1, null, null, null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // No workers available, step should remain "ready"
    const step = (try store.getStep(arena.allocator(), "step_t1")).?;
    try std.testing.expectEqualStrings("ready", step.status);
}
