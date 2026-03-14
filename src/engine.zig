/// DAG Engine — Unified State Model Scheduler
///
/// The engine runs on its own thread, polling the database for active runs
/// and processing them using a graph-based state model with 7 node types:
///   task, route, interrupt, agent, send, transform, subgraph
///
/// Each tick:
///   1. Get active runs (status = running)
///   2. For each run:
///      a. Load current state from run.state_json
///      b. Load workflow definition from run.workflow_json
///      c. Get completed nodes from latest checkpoint (or [])
///      d. Find ready nodes (all nodes whose inbound edges are satisfied)
///      e. Execute ready nodes in sequence
///      f. Apply state updates via reducers, save checkpoint
///      g. Check termination / deadlock
///
/// Features:
///   - Command primitive (goto): worker responses can contain "goto" to override routing
///   - Breakpoints: interrupt_before / interrupt_after arrays in workflow definition
///   - Subgraph: inline execution of child workflows with input/output mapping
///   - Multi-turn: agent nodes can loop with continuation_prompt up to max_turns
///   - Configurable runs: config stored as state.__config, accessible via templates
///   - Reconciliation: check nulltickets task status between steps
const std = @import("std");
const log = std.log.scoped(.engine);
const json = std.json;

const Store = @import("store.zig").Store;
const types = @import("types.zig");
const ids = @import("ids.zig");
const templates = @import("templates.zig");
const dispatch = @import("dispatch.zig");
const callbacks = @import("callbacks.zig");
const metrics_mod = @import("metrics.zig");
const async_dispatch = @import("async_dispatch.zig");
const state_mod = @import("state.zig");
const sse_mod = @import("sse.zig");
const tracker_client = @import("tracker_client.zig");
const workflow_loader = @import("workflow_loader.zig");

// ── Structured Events ────────────────────────────────────────────────

pub const OrchestratorEvent = struct {
    event_type: EventType,
    run_id: ?[]const u8,
    step_id: ?[]const u8,
    node_name: ?[]const u8,
    timestamp_ms: i64,
    metadata_json: ?[]const u8,

    pub const EventType = enum {
        run_started,
        run_completed,
        run_failed,
        run_interrupted,
        run_cancelled,
        step_started,
        step_completed,
        step_failed,
        step_retrying,
        agent_turn_started,
        agent_turn_completed,
        workflow_reloaded,
        checkpoint_created,
        state_injected,
    };

    pub fn eventKindString(et: EventType) []const u8 {
        return switch (et) {
            .run_started => "run.started",
            .run_completed => "run.completed",
            .run_failed => "run.failed",
            .run_interrupted => "run.interrupted",
            .run_cancelled => "run.cancelled",
            .step_started => "step.started",
            .step_completed => "step.completed",
            .step_failed => "step.failed",
            .step_retrying => "step.retrying",
            .agent_turn_started => "agent_turn.started",
            .agent_turn_completed => "agent_turn.completed",
            .workflow_reloaded => "workflow.reloaded",
            .checkpoint_created => "checkpoint.created",
            .state_injected => "state.injected",
        };
    }

    pub fn toJson(self: OrchestratorEvent, alloc: std.mem.Allocator) ?[]const u8 {
        return std.fmt.allocPrint(alloc,
            \\{{"event_type":"{s}","run_id":"{s}","step_id":"{s}","node_name":"{s}","timestamp_ms":{d}}}
        , .{
            eventKindString(self.event_type),
            self.run_id orelse "",
            self.step_id orelse "",
            self.node_name orelse "",
            self.timestamp_ms,
        }) catch null;
    }
};

// ── Constants ────────────────────────────────────────────────────────

/// Maximum number of node executions per tick to prevent infinite loops.
const max_nodes_per_tick: u32 = 1000;

/// Maximum inline subgraph recursion depth.
const max_subgraph_depth: u32 = 10;

const StoreWriter = *const fn (
    alloc: std.mem.Allocator,
    base_url: []const u8,
    api_token: ?[]const u8,
    namespace: []const u8,
    key: []const u8,
    value_json: []const u8,
) anyerror!void;

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

pub const RateLimitInfo = struct {
    worker_id: []const u8,
    remaining: i64,
    limit: i64,
    reset_ms: i64,
    updated_at_ms: i64,
};

pub const Engine = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    poll_interval_ns: u64,
    running: std.atomic.Value(bool),
    runtime_cfg: RuntimeConfig,
    next_health_check_at_ms: i64,
    metrics: ?*metrics_mod.Metrics,
    response_queue: ?*async_dispatch.ResponseQueue,
    sse_hub: ?*sse_mod.SseHub = null,
    workflow_watcher: ?*workflow_loader.WorkflowWatcher = null,
    rate_limits: std.StringHashMap(RateLimitInfo),
    store_fetcher: templates.StoreFetcher,
    store_writer: StoreWriter,
    trusted_tracker_url: ?[]const u8 = null,
    trusted_tracker_api_token: ?[]const u8 = null,
    config_valid: bool = false,
    last_config_check_ms: i64 = 0,

    /// How often to re-run config validation (default 30s).
    const config_check_interval_ms: i64 = 30_000;

    pub fn init(store: *Store, allocator: std.mem.Allocator, poll_interval_ms: u64) Engine {
        return .{
            .store = store,
            .allocator = allocator,
            .poll_interval_ns = poll_interval_ms * std.time.ns_per_ms,
            .running = std.atomic.Value(bool).init(true),
            .runtime_cfg = .{},
            .next_health_check_at_ms = 0,
            .metrics = null,
            .response_queue = null,
            .sse_hub = null,
            .workflow_watcher = null,
            .rate_limits = std.StringHashMap(RateLimitInfo).init(allocator),
            .store_fetcher = templates.fetchStoreValueHttp,
            .store_writer = putStoreValueViaHttp,
            .trusted_tracker_url = null,
            .trusted_tracker_api_token = null,
            .config_valid = false,
            .last_config_check_ms = 0,
        };
    }

    pub fn configure(self: *Engine, runtime_cfg: RuntimeConfig, metrics: ?*metrics_mod.Metrics) void {
        self.runtime_cfg = runtime_cfg;
        self.metrics = metrics;
    }

    pub fn setTrustedTrackerAccess(self: *Engine, base_url: ?[]const u8, api_token: ?[]const u8) void {
        self.trusted_tracker_url = base_url;
        self.trusted_tracker_api_token = api_token;
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

    // ── Config Validation ────────────────────────────────────────────

    /// Validate that the engine configuration is healthy before dispatching
    /// new work. Returns true if workers exist and the store is reachable.
    /// Results are cached for config_check_interval_ms to avoid running
    /// 2 DB queries (listWorkers + getActiveRuns) on every tick.
    fn validateConfig(self: *Engine) bool {
        const now_ms = ids.nowMs();
        if (self.config_valid and (now_ms - self.last_config_check_ms) < config_check_interval_ms) {
            return true;
        }

        // Check: at least one worker registered and active
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const workers = self.store.listWorkers(alloc) catch {
            log.warn("config validation: store query failed (listWorkers)", .{});
            self.config_valid = false;
            return false;
        };

        if (workers.len == 0) {
            log.warn("config validation: no workers registered", .{});
            self.config_valid = false;
            return false;
        }

        // Check: store connection healthy (simple query)
        _ = self.store.getActiveRuns(alloc) catch {
            log.warn("config validation: store connection unhealthy", .{});
            self.config_valid = false;
            return false;
        };

        self.config_valid = true;
        self.last_config_check_ms = now_ms;
        return true;
    }

    // ── Structured Event Emission ────────────────────────────────────

    /// Emit a structured OrchestratorEvent: persist to the events table and
    /// broadcast via SseHub for real-time consumption.
    fn emitEvent(
        self: *Engine,
        alloc: std.mem.Allocator,
        event_type: OrchestratorEvent.EventType,
        run_id: ?[]const u8,
        step_id: ?[]const u8,
        node_name: ?[]const u8,
        metadata_json: ?[]const u8,
    ) void {
        const ev = OrchestratorEvent{
            .event_type = event_type,
            .run_id = run_id,
            .step_id = step_id,
            .node_name = node_name,
            .timestamp_ms = ids.nowMs(),
            .metadata_json = metadata_json,
        };

        const kind = OrchestratorEvent.eventKindString(event_type);
        const data = ev.toJson(alloc) orelse "{}";

        // Persist to events table
        if (run_id) |rid| {
            self.store.insertEvent(rid, step_id, kind, data) catch |err| {
                log.warn("failed to persist event {s}: {}", .{ kind, err });
            };
        }

        // Broadcast via SSE
        if (self.sse_hub) |hub| {
            if (run_id) |rid| {
                hub.broadcast(rid, .{ .event_type = kind, .data = data });
            }
        }
    }

    // ── tick — single scheduler iteration ────────────────────────────

    fn tick(self: *Engine) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Validate config before processing — skip dispatch if unhealthy
        if (!self.validateConfig()) {
            log.warn("config validation failed, skipping dispatch this tick", .{});
            return;
        }

        // Check for hot-reloaded workflow files
        if (self.workflow_watcher) |watcher| {
            watcher.checkForChanges();
        }

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

    // ── processRun — state-based graph execution ─────────────────────

    fn processRun(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow) !void {
        return self.processRunWithDepth(alloc, run_row, 0);
    }

    /// Wrapper for inline subgraph execution. Uses anyerror to break
    /// the recursive inferred-error-set cycle.
    fn processRunInline(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, recursion_depth: u32) void {
        self.processRunWithDepth(alloc, run_row, recursion_depth) catch |err| {
            log.err("inline subgraph run {s} failed: {}", .{ run_row.id, err });
        };
    }

    fn processRunWithDepth(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, recursion_depth: u32) !void {
        // 1. Load current state
        var current_state = run_row.state_json orelse "{}";

        // 1b. Inject __config into state (configurable runs)
        if (run_row.config_json) |config_str| {
            if (config_str.len > 0) {
                const config_update = std.fmt.allocPrint(alloc, "{{\"__config\":{s}}}", .{config_str}) catch null;
                if (config_update) |cu| {
                    // Simple merge: parse state, add __config key
                    const merged = state_mod.applyUpdates(alloc, current_state, cu, "{}") catch null;
                    if (merged) |m| {
                        current_state = m;
                    }
                }
            }
        }

        // 2. Load and parse workflow definition once for the entire tick.
        // Helper functions still accept raw JSON strings for external callers,
        // but we pre-extract commonly used values here to avoid redundant parsing.
        const workflow_json = run_row.workflow_json;
        const wf_parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch {
            log.err("failed to parse workflow_json for run {s}", .{run_row.id});
            try self.store.updateRunStatus(run_row.id, "failed", "invalid workflow JSON");
            return;
        };
        const wf_root = wf_parsed.value;

        // Pre-extract schema (used many times in the loop)
        const cached_schema_json = if (wf_root == .object) blk: {
            if (wf_root.object.get("state_schema")) |ss| {
                break :blk serializeJsonValue(alloc, ss) catch "{}";
            }
            if (wf_root.object.get("schema")) |ss| {
                break :blk serializeJsonValue(alloc, ss) catch "{}";
            }
            break :blk "{}";
        } else "{}";

        // 2b. Parse breakpoint lists from workflow definition
        const interrupt_before = parseBreakpointListFromRoot(alloc, wf_root, "interrupt_before");
        const interrupt_after = parseBreakpointListFromRoot(alloc, wf_root, "interrupt_after");

        // 2d. Collect deferred nodes (Gap 6)
        const deferred_nodes = collectDeferredNodesFromRoot(alloc, wf_root);

        // 2c. Get task id for reconciliation.
        const task_id = getRuntimeStringSetting(alloc, current_state, workflow_json, &.{"task_id"});

        // 3. Get completed nodes from latest checkpoint
        var completed_nodes = std.StringHashMap(void).init(alloc);
        var route_results = std.StringHashMap([]const u8).init(alloc);

        const latest_checkpoint = try self.store.getLatestCheckpoint(alloc, run_row.id);
        if (latest_checkpoint) |cp| {
            // Parse completed_nodes_json array
            const cn_parsed = json.parseFromSlice(json.Value, alloc, cp.completed_nodes_json, .{}) catch null;
            if (cn_parsed) |p| {
                if (p.value == .array) {
                    for (p.value.array.items) |item| {
                        if (item == .string) {
                            try completed_nodes.put(item.string, {});
                        }
                    }
                }
            }

            // Parse route results from checkpoint metadata
            if (cp.metadata_json) |meta_str| {
                const meta_parsed = json.parseFromSlice(json.Value, alloc, meta_str, .{}) catch null;
                if (meta_parsed) |mp| {
                    if (mp.value == .object) {
                        if (mp.value.object.get("route_results")) |rr| {
                            if (rr == .object) {
                                var it = rr.object.iterator();
                                while (it.next()) |entry| {
                                    if (entry.value_ptr.* == .string) {
                                        try route_results.put(entry.key_ptr.*, entry.value_ptr.string);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        var version: i64 = if (latest_checkpoint) |cp| cp.version else 0;
        const initial_version = version;

        // Track the latest checkpoint ID for correct parent chaining.
        // Updated after each checkpoint creation so subsequent checkpoints
        // within the same tick correctly chain to their predecessor.
        var latest_checkpoint_id: ?[]const u8 = if (latest_checkpoint) |cp| cp.id else null;

        // Emit run_started only on the first tick (no prior checkpoints)
        if (latest_checkpoint == null) {
            self.emitEvent(alloc, .run_started, run_row.id, null, null, null);
        }

        // 3b. Workflow version migration check
        const wf_version = getWorkflowVersion(alloc, workflow_json);
        if (latest_checkpoint) |cp| {
            const cp_version = getCheckpointWorkflowVersion(alloc, cp.metadata_json);
            if (cp_version != wf_version) {
                log.warn("workflow version changed from {d} to {d}, attempting migration", .{ cp_version, wf_version });
                // Filter completed_nodes to only include nodes that still exist
                _ = migrateCompletedNodes(alloc, &completed_nodes, workflow_json);
            }
        }

        // 4. Main execution loop: find ready nodes, execute, repeat
        var running_state: []const u8 = try alloc.dupe(u8, current_state);
        var max_iterations: u32 = max_nodes_per_tick;
        var goto_ready: ?[]const []const u8 = null; // goto override from command primitive

        while (max_iterations > 0) : (max_iterations -= 1) {
            // Use goto override if set, otherwise find ready nodes normally
            const all_ready_nodes = if (goto_ready) |gr| blk: {
                goto_ready = null;
                break :blk gr;
            } else try findReadyNodesFromRoot(alloc, wf_root, &completed_nodes, &route_results);

            // Gap 6: Filter out deferred nodes from ready list (execute them later)
            var ready_list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (all_ready_nodes) |name| {
                if (!isInBreakpointList(name, deferred_nodes)) {
                    try ready_list.append(alloc, name);
                }
            }
            const ready_nodes = ready_list.items;
            if (ready_nodes.len == 0) {
                // Check termination: if all paths reached __end__
                if (completed_nodes.get("__end__") != null) {
                    // Save final state if we made progress
                    if (version > initial_version) {
                        try self.store.updateRunState(run_row.id, running_state);
                    }
                    try self.store.updateRunStatus(run_row.id, "completed", null);
                    try self.store.insertEvent(run_row.id, null, "run.completed", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.completed", run_row.id, null, "{}", self.metrics);
                    log.info("run {s} completed", .{run_row.id});
                    return;
                }
                // Deadlock: no ready nodes and not done
                if (completed_nodes.count() > 0) {
                    // Check if any step is still running asynchronously
                    const steps = try self.store.getStepsByRun(alloc, run_row.id);
                    var has_running = false;
                    for (steps) |step| {
                        if (std.mem.eql(u8, step.status, "running")) {
                            has_running = true;
                            break;
                        }
                    }
                    if (has_running) {
                        for (steps) |step| {
                            if (std.mem.eql(u8, step.status, "running")) {
                                self.pollAsyncTaskStep(alloc, run_row, step) catch |err| {
                                    log.err("error polling async step {s}: {}", .{ step.id, err });
                                };
                            }
                        }
                        return;
                    }
                    log.err("run {s} deadlocked: no ready nodes, not completed", .{run_row.id});
                    try self.store.updateRunStatus(run_row.id, "failed", "deadlock: no ready nodes");
                    try self.store.insertEvent(run_row.id, null, "run.failed", "{\"reason\":\"deadlock\"}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.failed", run_row.id, null, "{}", self.metrics);
                }
                return;
            }

            // 5. Execute ready nodes sequentially
            var made_progress = false;
            var goto_override: ?[]const []const u8 = null;

            for (ready_nodes) |node_name| {
                if (std.mem.eql(u8, node_name, "__end__")) {
                    // Gap 6: Execute deferred nodes before completing
                    for (deferred_nodes) |deferred_name| {
                        if (completed_nodes.get(deferred_name) != null) continue;

                        const def_node_json = getNodeJsonFromRoot(alloc, wf_root, deferred_name) orelse continue;
                        const def_node_type = getNodeField(alloc, def_node_json, "type") orelse "task";

                        if (std.mem.eql(u8, def_node_type, "transform")) {
                            const def_updates = getNodeField(alloc, def_node_json, "updates") orelse "{}";
                            const def_schema = cached_schema_json;
                            const def_new_state = state_mod.applyUpdates(alloc, running_state, def_updates, def_schema) catch running_state;
                            running_state = def_new_state;
                        } else if (std.mem.eql(u8, def_node_type, "task") or std.mem.eql(u8, def_node_type, "agent")) {
                            const def_result = self.executeTaskNode(alloc, run_row, deferred_name, def_node_json, running_state) catch continue;
                            switch (def_result) {
                                .completed => |cr| {
                                    if (cr.state_updates) |updates| {
                                        const def_schema = cached_schema_json;
                                        const def_new_state = state_mod.applyUpdates(alloc, running_state, updates, def_schema) catch running_state;
                                        running_state = def_new_state;
                                    }
                                },
                                else => {},
                            }
                        }

                        try completed_nodes.put(try alloc.dupe(u8, deferred_name), {});
                        log.info("deferred node {s} completed for run {s}", .{ deferred_name, run_row.id });
                    }

                    // Mark __end__ as completed
                    try completed_nodes.put("__end__", {});
                    version += 1;

                    // Save checkpoint
                    const cp_id_buf = ids.generateId();
                    const cp_id = try alloc.dupe(u8, &cp_id_buf);
                    const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                    const parent_id: ?[]const u8 = latest_checkpoint_id;
                    const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                    try self.store.createCheckpoint(cp_id, run_row.id, "__end__", parent_id, running_state, cn_json, version, meta_json);
                    try self.store.incrementCheckpointCount(run_row.id);
                    try self.store.updateRunState(run_row.id, running_state);
                    latest_checkpoint_id = cp_id;

                    // Run is completed
                    try self.store.updateRunStatus(run_row.id, "completed", null);
                    try self.store.insertEvent(run_row.id, null, "run.completed", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.completed", run_row.id, null, "{}", self.metrics);
                    log.info("run {s} completed", .{run_row.id});
                    return;
                }

                // Breakpoint: interrupt_before check
                if (isInBreakpointList(node_name, interrupt_before)) {
                    log.info("breakpoint interrupt_before at node {s} for run {s}", .{ node_name, run_row.id });
                    version += 1;
                    const cp_id_buf = ids.generateId();
                    const cp_id = try alloc.dupe(u8, &cp_id_buf);
                    const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                    const parent_id: ?[]const u8 = latest_checkpoint_id;
                    const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                    try self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json);
                    try self.store.incrementCheckpointCount(run_row.id);
                    try self.store.updateRunState(run_row.id, running_state);
                    latest_checkpoint_id = cp_id;

                    try self.store.updateRunStatus(run_row.id, "interrupted", null);
                    try self.store.insertEvent(run_row.id, null, "run.interrupted", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.interrupted", run_row.id, null, "{}", self.metrics);
                    return;
                }

                // Get node definition from workflow
                const node_json = getNodeJsonFromRoot(alloc, wf_root, node_name) orelse {
                    log.err("node {s} not found in workflow for run {s}", .{ node_name, run_row.id });
                    try self.store.updateRunStatus(run_row.id, "failed", "node not found in workflow");
                    return;
                };

                // Get node type
                const node_type = getNodeField(alloc, node_json, "type") orelse "task";

                // Execute based on type
                if (std.mem.eql(u8, node_type, "route")) {
                    // Route: evaluate routing logic, no worker dispatch
                    const result = try self.executeRouteNode(alloc, node_name, node_json, running_state);
                    if (result.route_value) |rv| {
                        try route_results.put(try alloc.dupe(u8, node_name), rv);
                    }
                    try completed_nodes.put(try alloc.dupe(u8, node_name), {});

                    // Create step record
                    const step_id_buf = ids.generateId();
                    const step_id = try alloc.dupe(u8, &step_id_buf);
                    try self.store.insertStep(step_id, run_row.id, node_name, "route", "completed", "{}", 1, null, null, null);
                    const route_output = try std.fmt.allocPrint(alloc, "{{\"route\":\"{s}\"}}", .{result.route_value orelse "default"});
                    try self.store.updateStepStatus(step_id, "completed", null, route_output, null, 1);
                    try self.store.insertEvent(run_row.id, step_id, "step.completed", route_output);

                    log.info("route node {s} -> {s}", .{ node_name, result.route_value orelse "default" });
                } else if (std.mem.eql(u8, node_type, "interrupt")) {
                    // Interrupt: save checkpoint, set run to interrupted
                    try completed_nodes.put(try alloc.dupe(u8, node_name), {});
                    version += 1;

                    const step_id_buf = ids.generateId();
                    const step_id = try alloc.dupe(u8, &step_id_buf);
                    try self.store.insertStep(step_id, run_row.id, node_name, "interrupt", "completed", "{}", 1, null, null, null);
                    try self.store.updateStepStatus(step_id, "completed", null, "{\"interrupted\":true}", null, 1);
                    try self.store.insertEvent(run_row.id, step_id, "step.completed", "{}");

                    const cp_id_buf = ids.generateId();
                    const cp_id = try alloc.dupe(u8, &cp_id_buf);
                    const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                    const parent_id: ?[]const u8 = latest_checkpoint_id;
                    const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                    try self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json);
                    try self.store.incrementCheckpointCount(run_row.id);
                    try self.store.updateRunState(run_row.id, running_state);
                    latest_checkpoint_id = cp_id;

                    try self.store.updateRunStatus(run_row.id, "interrupted", null);
                    try self.store.insertEvent(run_row.id, null, "run.interrupted", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.interrupted", run_row.id, null, "{}", self.metrics);
                    log.info("run {s} interrupted at node {s}", .{ run_row.id, node_name });
                    return;
                } else if (std.mem.eql(u8, node_type, "transform")) {
                    // Transform: apply static updates, no worker dispatch
                    const state_updates = getNodeField(alloc, node_json, "updates") orelse "{}";

                    // Get schema from workflow
                    const schema_json = cached_schema_json;

                    // Apply updates via reducers
                    const new_state = state_mod.applyUpdates(alloc, running_state, state_updates, schema_json) catch |err| {
                        log.err("transform node {s} failed to apply updates: {}", .{ node_name, err });
                        try self.store.updateRunStatus(run_row.id, "failed", "transform failed");
                        return;
                    };
                    running_state = new_state;

                    if (getNodeField(alloc, node_json, "store_updates")) |store_updates_json| {
                        self.applyStoreUpdates(alloc, workflow_json, running_state, store_updates_json) catch |err| {
                            log.err("transform node {s} failed to write store updates: {}", .{ node_name, err });
                            try self.store.updateRunStatus(run_row.id, "failed", "transform store update failed");
                            return;
                        };
                    }

                    try completed_nodes.put(try alloc.dupe(u8, node_name), {});

                    // Create step record
                    const step_id_buf = ids.generateId();
                    const step_id = try alloc.dupe(u8, &step_id_buf);
                    try self.store.insertStep(step_id, run_row.id, node_name, "transform", "completed", "{}", 1, null, null, null);
                    try self.store.updateStepStatus(step_id, "completed", null, state_updates, null, 1);
                    try self.store.insertEvent(run_row.id, step_id, "step.completed", "{}");

                    log.info("transform node {s} completed", .{node_name});
                } else if (std.mem.eql(u8, node_type, "task") or std.mem.eql(u8, node_type, "agent")) {
                    // Gap 7: Inject __meta managed values
                    const state_with_meta = injectMeta(alloc, running_state, run_row.id, node_name, version, @as(i64, @intCast(max_iterations))) catch running_state;

                    // Gap 3: Check cache before executing
                    const cache_ttl = parseCacheTtlMs(alloc, node_json);
                    if (cache_ttl != null) cache_check: {
                        const pt_c = getNodeField(alloc, node_json, "prompt_template") orelse break :cache_check;
                        const rnd_c = self.renderWorkflowTemplate(alloc, workflow_json, pt_c, state_with_meta, run_row.input_json, null) catch break :cache_check;
                        const ck_c = computeCacheKey(alloc, node_name, rnd_c) catch break :cache_check;
                        const cached = self.store.getCachedResult(alloc, ck_c) catch break :cache_check;
                        if (cached) |cached_upd| {
                            const cs = cached_schema_json;
                            running_state = state_mod.applyUpdates(alloc, running_state, cached_upd, cs) catch running_state;
                            try completed_nodes.put(try alloc.dupe(u8, node_name), {});
                            log.info("task node {s} cache hit for run {s}", .{ node_name, run_row.id });
                            made_progress = true;
                            version += 1;
                            const ccb = ids.generateId();
                            const cci = try alloc.dupe(u8, &ccb);
                            const ccn = try serializeCompletedNodes(alloc, &completed_nodes);
                            const cpi: ?[]const u8 = latest_checkpoint_id;
                            const cmj = try serializeRouteResults(alloc, &route_results);
                            try self.store.createCheckpoint(cci, run_row.id, node_name, cpi, running_state, ccn, version, cmj);
                            try self.store.incrementCheckpointCount(run_row.id);
                            try self.store.updateRunState(run_row.id, running_state);
                            latest_checkpoint_id = cci;
                            continue;
                        }
                    }

                    // Gap 2: Non-blocking retry — check for pending retry step
                    const max_attempts = parseRetryMaxAttempts(alloc, node_json) orelse 1;
                    const retry_init_ms = parseRetryInitialMs(alloc, node_json) orelse 500;
                    const retry_bf = parseRetryBackoff(alloc, node_json) orelse 2.0;
                    const retry_max_ms = parseRetryMaxMs(alloc, node_json) orelse 30000;

                    // Check if there's a pending retry step for this node
                    const retrying_step = self.store.getRetryingStepForNode(alloc, run_row.id, node_name) catch null;
                    if (retrying_step) |rs| {
                        const now_ms = ids.nowMs();
                        if (rs.next_attempt_at_ms) |next_at| {
                            if (now_ms < next_at) {
                                // Retry delay not elapsed yet — skip this node, let other runs process
                                return;
                            }
                        }
                        // Retry timer expired — clear the retrying step and re-execute below
                        // The attempt count is tracked on the step record
                    }

                    const current_attempt: u32 = if (retrying_step) |rs| @intCast(rs.attempt) else 0;
                    const result = try self.executeTaskNode(alloc, run_row, node_name, node_json, state_with_meta);

                    // Handle retry scheduling for failed results (non-blocking)
                    const result_after_retry: TaskNodeResult = switch (result) {
                        .failed => |err_text| blk: {
                            if (current_attempt + 1 < max_attempts) {
                                // Calculate delay with exponential backoff
                                var dms: u64 = retry_init_ms;
                                var ei: u32 = 0;
                                while (ei < current_attempt) : (ei += 1) {
                                    const nd = @as(f64, @floatFromInt(dms)) * retry_bf;
                                    dms = @intFromFloat(@min(nd, @as(f64, @floatFromInt(retry_max_ms))));
                                }
                                if (dms > retry_max_ms) dms = retry_max_ms;
                                log.info("task node {s} attempt {d}/{d} failed, scheduling retry in {d}ms", .{ node_name, current_attempt + 1, max_attempts, dms });
                                self.emitEvent(alloc, .step_retrying, run_row.id, null, node_name, null);

                                // Create or update step record with retry schedule
                                const next_retry_at = ids.nowMs() + @as(i64, @intCast(dms));
                                if (retrying_step) |rs| {
                                    // Update existing step with next retry time
                                    self.store.scheduleStepRetry(rs.id, next_retry_at, @as(i64, @intCast(current_attempt + 1)), err_text) catch {};
                                } else {
                                    // Create new step record for retry tracking
                                    const retry_step_id_buf = ids.generateId();
                                    const retry_step_id = alloc.dupe(u8, &retry_step_id_buf) catch {
                                        break :blk result;
                                    };
                                    self.store.insertStep(retry_step_id, run_row.id, node_name, node_type, "ready", "{}", @intCast(max_attempts), null, null, null) catch {
                                        break :blk result;
                                    };
                                    self.store.scheduleStepRetry(retry_step_id, next_retry_at, 1, err_text) catch {};
                                }

                                // Save progress checkpoint before returning
                                if (version > initial_version) {
                                    const cp_id_buf = ids.generateId();
                                    const cp_id = alloc.dupe(u8, &cp_id_buf) catch {
                                        break :blk result;
                                    };
                                    const cn_json = serializeCompletedNodes(alloc, &completed_nodes) catch {
                                        break :blk result;
                                    };
                                    const parent_id: ?[]const u8 = if (latest_checkpoint_id) |pid| pid else null;
                                    const meta_json = serializeRouteResultsWithVersion(alloc, &route_results, wf_version) catch {
                                        break :blk result;
                                    };
                                    self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json) catch {};
                                    self.store.incrementCheckpointCount(run_row.id) catch {};
                                    self.store.updateRunState(run_row.id, running_state) catch {};
                                    latest_checkpoint_id = cp_id;
                                }

                                // Return without marking node as completed — next tick will retry
                                return;
                            }
                            break :blk result;
                        },
                        else => result,
                    };

                    switch (result_after_retry) {
                        .completed => |cr| {
                            // Gap 7: Strip __meta (don't persist)
                            running_state = stripMeta(alloc, running_state) catch running_state;

                            if (cr.state_updates) |updates| {
                                const schema_json = cached_schema_json;
                                const new_state = state_mod.applyUpdates(alloc, running_state, updates, schema_json) catch |err| {
                                    log.err("task node {s} failed to apply updates: {}", .{ node_name, err });
                                    try self.store.updateRunStatus(run_row.id, "failed", "state update failed");
                                    return;
                                };
                                running_state = new_state;

                                // Gap 3: Store result in cache
                                if (cache_ttl) |ttl| cache_store: {
                                    const pt_s = getNodeField(alloc, node_json, "prompt_template") orelse break :cache_store;
                                    const rnd_s = self.renderWorkflowTemplate(alloc, workflow_json, pt_s, state_with_meta, run_row.input_json, null) catch break :cache_store;
                                    const ck_s = computeCacheKey(alloc, node_name, rnd_s) catch break :cache_store;
                                    self.store.setCachedResult(ck_s, node_name, updates, ttl) catch |cerr| {
                                        log.warn("failed to cache result for node {s}: {}", .{ node_name, cerr });
                                    };
                                }

                                // Gap 4: Save as pending write
                                self.store.savePendingWrite(run_row.id, node_name, node_name, updates) catch |perr| {
                                    log.warn("failed to save pending write for node {s}: {}", .{ node_name, perr });
                                };
                            }

                            // Apply UI messages to state (__ui_messages key)
                            if (cr.raw_output) |raw_out| {
                                running_state = applyUiMessagesToState(alloc, running_state, raw_out) catch running_state;
                            }

                            // Consume pending injections
                            const injections = self.store.consumePendingInjections(alloc, run_row.id, node_name) catch &.{};
                            for (injections) |injection| {
                                const schema_json = cached_schema_json;
                                const new_state = state_mod.applyUpdates(alloc, running_state, injection.updates_json, schema_json) catch |err| {
                                    log.warn("failed to apply injection for run {s}: {}", .{ run_row.id, err });
                                    continue;
                                };
                                running_state = new_state;
                            }

                            try completed_nodes.put(try alloc.dupe(u8, node_name), {});

                            if (cr.goto_targets) |targets| {
                                var valid_targets: std.ArrayListUnmanaged([]const u8) = .empty;
                                for (targets) |target| {
                                    if (std.mem.eql(u8, target, "__end__") or workflowHasNode(wf_root, target)) {
                                        try valid_targets.append(alloc, target);
                                    } else {
                                        log.warn("goto target {s} not found in workflow, skipping", .{target});
                                    }
                                }
                                if (valid_targets.items.len > 0) {
                                    goto_override = try valid_targets.toOwnedSlice(alloc);
                                    log.info("task node {s} goto: {d} targets", .{ node_name, goto_override.?.len });
                                }
                            }

                            // Gap 4: Clear pending writes
                            self.store.clearPendingWrites(run_row.id) catch {};

                            log.info("task node {s} completed for run {s}", .{ node_name, run_row.id });
                        },
                        .async_pending => {
                            // Step is dispatched async, don't mark as completed yet
                            // Will be polled on next tick
                            log.info("task node {s} dispatched async for run {s}", .{ node_name, run_row.id });
                            // Save checkpoint with current progress before returning
                            version += 1;
                            const cp_id_buf = ids.generateId();
                            const cp_id = try alloc.dupe(u8, &cp_id_buf);
                            const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                            const parent_id: ?[]const u8 = latest_checkpoint_id;
                            const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                            try self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json);
                            try self.store.incrementCheckpointCount(run_row.id);
                            try self.store.updateRunState(run_row.id, running_state);
                            latest_checkpoint_id = cp_id;
                            return;
                        },
                        .no_worker => {
                            // No worker available, will retry next tick
                            log.debug("no worker for task node {s}, will retry", .{node_name});
                            // Save progress so far
                            if (version > initial_version) {
                                const cp_id_buf = ids.generateId();
                                const cp_id = try alloc.dupe(u8, &cp_id_buf);
                                const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                                const parent_id: ?[]const u8 = latest_checkpoint_id;
                                const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                                try self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json);
                                try self.store.incrementCheckpointCount(run_row.id);
                                try self.store.updateRunState(run_row.id, running_state);
                                latest_checkpoint_id = cp_id;
                            }
                            return;
                        },
                        .failed => |err_text| {
                            log.err("task node {s} failed: {s}", .{ node_name, err_text });
                            try self.store.updateRunStatus(run_row.id, "failed", err_text);
                            try self.store.insertEvent(run_row.id, null, "run.failed", "{}");
                            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.failed", run_row.id, null, "{}", self.metrics);
                            return;
                        },
                    }
                } else if (std.mem.eql(u8, node_type, "subgraph")) {
                    // Subgraph: execute child workflow inline
                    const result = try self.executeSubgraphNode(alloc, run_row, node_name, node_json, running_state, recursion_depth);

                    switch (result) {
                        .completed => |cr| {
                            if (cr.state_updates) |updates| {
                                const schema_json = cached_schema_json;
                                const new_state = state_mod.applyUpdates(alloc, running_state, updates, schema_json) catch |err| {
                                    log.err("subgraph node {s} failed to apply updates: {}", .{ node_name, err });
                                    try self.store.updateRunStatus(run_row.id, "failed", "subgraph state update failed");
                                    return;
                                };
                                running_state = new_state;
                            }
                            try completed_nodes.put(try alloc.dupe(u8, node_name), {});
                            log.info("subgraph node {s} completed for run {s}", .{ node_name, run_row.id });
                        },
                        .failed => |err_text| {
                            log.err("subgraph node {s} failed: {s}", .{ node_name, err_text });
                            try self.store.updateRunStatus(run_row.id, "failed", err_text);
                            try self.store.insertEvent(run_row.id, null, "run.failed", "{}");
                            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.failed", run_row.id, null, "{}", self.metrics);
                            return;
                        },
                        else => {},
                    }
                } else if (std.mem.eql(u8, node_type, "send")) {
                    // Send: read items from state, dispatch target_node per item
                    const result = try self.executeSendNode(alloc, run_row, node_name, node_json, running_state);
                    if (result.state_updates) |updates| {
                        const schema_json = cached_schema_json;
                        const new_state = state_mod.applyUpdates(alloc, running_state, updates, schema_json) catch |err| {
                            log.err("send node {s} failed to apply updates: {}", .{ node_name, err });
                            try self.store.updateRunStatus(run_row.id, "failed", "send state update failed");
                            return;
                        };
                        running_state = new_state;
                    }
                    try completed_nodes.put(try alloc.dupe(u8, node_name), {});
                    log.info("send node {s} completed for run {s}", .{ node_name, run_row.id });
                } else {
                    log.warn("unknown node type {s} for node {s}", .{ node_type, node_name });
                    try self.store.updateRunStatus(run_row.id, "failed", "unknown node type");
                    return;
                }

                // Breakpoint: interrupt_after check
                if (isInBreakpointList(node_name, interrupt_after)) {
                    log.info("breakpoint interrupt_after at node {s} for run {s}", .{ node_name, run_row.id });
                    // Save checkpoint with updated state first
                    version += 1;
                    const bp_cp_id_buf = ids.generateId();
                    const bp_cp_id = try alloc.dupe(u8, &bp_cp_id_buf);
                    const bp_cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                    const bp_parent_id: ?[]const u8 = latest_checkpoint_id;
                    const bp_meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                    try self.store.createCheckpoint(bp_cp_id, run_row.id, node_name, bp_parent_id, running_state, bp_cn_json, version, bp_meta_json);
                    try self.store.incrementCheckpointCount(run_row.id);
                    try self.store.updateRunState(run_row.id, running_state);
                    latest_checkpoint_id = bp_cp_id;

                    try self.store.updateRunStatus(run_row.id, "interrupted", null);
                    try self.store.insertEvent(run_row.id, null, "run.interrupted", "{}");
                    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.interrupted", run_row.id, null, "{}", self.metrics);
                    return;
                }

                // Reconciliation: check tracker task status between steps
                if (self.trusted_tracker_url != null and task_id != null) {
                    if (!reconcileWithTracker(alloc, self.trusted_tracker_url.?, self.trusted_tracker_api_token, task_id.?)) {
                        log.info("run {s} cancelled by reconciliation", .{run_row.id});
                        try self.store.updateRunStatus(run_row.id, "failed", "cancelled by tracker reconciliation");
                        try self.store.insertEvent(run_row.id, null, "run.failed", "{\"reason\":\"tracker_cancelled\"}");
                        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "run.failed", run_row.id, null, "{}", self.metrics);
                        return;
                    }
                }

                // Strip ephemeral keys before checkpoint persistence
                const schema_for_eph = cached_schema_json;
                running_state = state_mod.stripEphemeralKeys(alloc, running_state, schema_for_eph) catch running_state;

                // Save checkpoint after each node
                made_progress = true;
                version += 1;
                const cp_id_buf = ids.generateId();
                const cp_id = try alloc.dupe(u8, &cp_id_buf);
                const cn_json = try serializeCompletedNodes(alloc, &completed_nodes);
                const parent_id: ?[]const u8 = latest_checkpoint_id;
                const meta_json = try serializeRouteResultsWithVersion(alloc, &route_results, wf_version);
                try self.store.createCheckpoint(cp_id, run_row.id, node_name, parent_id, running_state, cn_json, version, meta_json);
                try self.store.incrementCheckpointCount(run_row.id);
                try self.store.updateRunState(run_row.id, running_state);
                latest_checkpoint_id = cp_id;

                // Emit structured checkpoint event
                self.emitEvent(alloc, .checkpoint_created, run_row.id, null, node_name, null);

                // Broadcast rich SSE events for all modes
                if (self.sse_hub) |hub| {
                    const node_json_for_sse = getNodeJsonFromRoot(alloc, wf_root, node_name);
                    const nt = if (node_json_for_sse) |nj| (getNodeField(alloc, nj, "type") orelse "task") else "task";
                    broadcastNodeEvents(hub, alloc, run_row.id, node_name, nt, running_state, null, version, 0);
                }
            }

            // If goto override is set, use it for next iteration instead of findReadyNodes
            if (goto_override) |targets| {
                goto_ready = targets;
            }

            // If no progress was made in this iteration, break
            if (!made_progress) break;
        } // end while loop
    }

    // ── Node Execution Results ───────────────────────────────────────

    const TaskNodeResult = union(enum) {
        completed: struct {
            state_updates: ?[]const u8,
            goto_targets: ?[]const []const u8 = null,
            raw_output: ?[]const u8 = null,
        },
        async_pending: void,
        no_worker: void,
        failed: []const u8,
    };

    const SendNodeResult = struct {
        state_updates: ?[]const u8,
    };

    const RouteNodeResult = struct {
        route_value: ?[]const u8,
    };

    // ── executeRouteNode ─────────────────────────────────────────────

    fn executeRouteNode(self: *Engine, alloc: std.mem.Allocator, node_name: []const u8, node_json: []const u8, state_json: []const u8) !RouteNodeResult {
        _ = self;
        _ = node_name;

        // Get the input path to read from state
        const input_path = getNodeField(alloc, node_json, "input") orelse "state.route_input";

        // Read value from state
        const value_json = state_mod.getStateValue(alloc, state_json, input_path) catch null;
        if (value_json == null) {
            // No value at path, try default route
            const default_route = getNodeField(alloc, node_json, "default");
            return RouteNodeResult{ .route_value = default_route };
        }

        // Stringify value for route matching
        const route_key = state_mod.stringifyForRoute(alloc, value_json.?) catch {
            const default_route = getNodeField(alloc, node_json, "default");
            return RouteNodeResult{ .route_value = default_route };
        };

        // Look up in routes map — but routes are encoded in edges, not in node
        // The route value is used for conditional edge matching like "node:value"
        return RouteNodeResult{ .route_value = route_key };
    }

    // ── executeTaskNode ──────────────────────────────────────────────

    fn executeTaskNode(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, node_name: []const u8, node_json: []const u8, state_json: []const u8) !TaskNodeResult {
        // 1. Get prompt template from node definition
        const prompt_template = getNodeField(alloc, node_json, "prompt_template") orelse {
            // No prompt template — mark as completed with no state updates
            return TaskNodeResult{ .completed = .{ .state_updates = null } };
        };

        // 2. Render prompt with graph template interpolation and optional store access.
        const rendered_prompt = self.renderWorkflowTemplate(alloc, run_row.workflow_json, prompt_template, state_json, run_row.input_json, null) catch |err| {
            log.err("template render failed for node {s}: {}", .{ node_name, err });
            return TaskNodeResult{ .failed = "template render failed" };
        };

        // 3. Get workers and select one
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

        const required_tags = getNodeTags(alloc, node_json);
        const node_type = getNodeField(alloc, node_json, "type") orelse "task";
        const is_agent_node = std.mem.eql(u8, node_type, "agent");

        // For agent nodes, prefer A2A-protocol workers first, then fall back to any worker
        var selected_worker: ?dispatch.WorkerInfo = null;
        if (is_agent_node) {
            // Filter to A2A workers only
            var a2a_workers: std.ArrayListUnmanaged(dispatch.WorkerInfo) = .empty;
            for (worker_infos.items) |w| {
                if (std.mem.eql(u8, w.protocol, "a2a")) {
                    try a2a_workers.append(alloc, w);
                }
            }
            if (a2a_workers.items.len > 0) {
                selected_worker = try dispatch.selectWorker(alloc, a2a_workers.items, required_tags);
            }
        }
        // Fall back to any protocol if no A2A worker found (or not an agent node)
        if (selected_worker == null) {
            selected_worker = try dispatch.selectWorker(alloc, worker_infos.items, required_tags);
        }
        if (selected_worker == null) {
            return TaskNodeResult{ .no_worker = {} };
        }
        const worker = selected_worker.?;

        // 4. Create step record
        const step_id_buf = ids.generateId();
        const step_id = try alloc.dupe(u8, &step_id_buf);
        try self.store.insertStep(step_id, run_row.id, node_name, node_type, "running", state_json, 1, null, null, null);
        try self.store.insertEvent(run_row.id, step_id, "step.running", "{}");
        self.emitEvent(alloc, .step_started, run_row.id, step_id, node_name, null);

        if (self.metrics) |m| {
            metrics_mod.Metrics.incr(&m.steps_claimed_total);
        }

        // 5. Dispatch to worker (A2A protocol for agent nodes with A2A workers,
        //    or standard protocol dispatch for task nodes / fallback)
        if (is_agent_node and std.mem.eql(u8, worker.protocol, "a2a")) {
            log.info("agent node {s} dispatching via A2A to worker {s}", .{ node_name, worker.id });
        }
        const result = try dispatch.dispatchStep(
            alloc,
            worker.url,
            worker.token,
            worker.protocol,
            worker.model,
            run_row.id,
            step_id,
            rendered_prompt,
        );

        // 6. Handle async dispatch
        if (result.async_pending) {
            const async_state = try mergeAsyncState(alloc, state_json, result.correlation_id orelse "");
            try self.store.updateStepInputJson(step_id, async_state);
            log.info("step {s} dispatched async, correlation_id={s}", .{ step_id, result.correlation_id orelse "?" });
            return TaskNodeResult{ .async_pending = {} };
        }

        // 7. Handle result
        if (result.success) {
            var final_output = result.output;

            // Track cumulative token usage (Gap 2)
            var total_input_tokens: i64 = 0;
            var total_output_tokens: i64 = 0;
            if (result.usage) |usage| {
                total_input_tokens += usage.input_tokens;
                total_output_tokens += usage.output_tokens;
            }

            // 7a. Multi-turn continuation for agent nodes
            if (is_agent_node) {
                const max_turns_val = getNodeFieldInt(alloc, node_json, "max_turns");
                const continuation_prompt = getNodeField(alloc, node_json, "continuation_prompt");
                const turn_timeout_ms_val = getNodeFieldInt(alloc, node_json, "turn_timeout_ms");
                const turn_start_ms = ids.nowMs();

                if (max_turns_val != null and continuation_prompt != null) {
                    const mt = max_turns_val.?;
                    const max_turns: u32 = @intCast(@min(@max(mt, 1), 100));
                    if (max_turns > 1) {
                        var turn: u32 = 1;
                        while (turn < max_turns) : (turn += 1) {
                            // Check turn timeout (Gap 4)
                            if (turn_timeout_ms_val) |timeout_ms| {
                                const elapsed = ids.nowMs() - turn_start_ms;
                                if (elapsed > timeout_ms) {
                                    log.info("agent node {s} turn timeout after {d}ms (limit={d}ms)", .{ node_name, elapsed, timeout_ms });
                                    break;
                                }
                            }

                            // Consume pending injections between turns — these are
                            // queued but cannot be applied mid-node. Re-save them so
                            // they are applied after the full node completes.
                            const mid_injections = self.store.consumePendingInjections(alloc, run_row.id, node_name) catch &.{};
                            for (mid_injections) |inj| {
                                self.store.createPendingInjection(run_row.id, inj.updates_json, node_name) catch {};
                            }

                            // Render continuation prompt
                            const cont_rendered = self.renderWorkflowTemplate(alloc, run_row.workflow_json, continuation_prompt.?, state_json, run_row.input_json, null) catch break;

                            const cont_result = try dispatch.dispatchStep(
                                alloc,
                                worker.url,
                                worker.token,
                                worker.protocol,
                                worker.model,
                                run_row.id,
                                step_id,
                                cont_rendered,
                            );

                            if (!cont_result.success) break;
                            final_output = cont_result.output;

                            // Accumulate token usage from continuation turns
                            if (cont_result.usage) |usage| {
                                total_input_tokens += usage.input_tokens;
                                total_output_tokens += usage.output_tokens;
                            }
                        }
                        log.info("agent node {s} completed {d} turns", .{ node_name, turn });
                    }
                }
            }

            // Record token usage (Gap 2)
            if (total_input_tokens > 0 or total_output_tokens > 0) {
                self.store.updateStepTokens(step_id, total_input_tokens, total_output_tokens) catch |err| {
                    log.warn("failed to update step tokens: {}", .{err});
                };
                self.store.updateRunTokens(run_row.id, total_input_tokens, total_output_tokens) catch |err| {
                    log.warn("failed to update run tokens: {}", .{err});
                };
            }

            // Store rate limit info (Gap 3)
            if (result.rate_limit) |rl| {
                self.rate_limits.put(worker.id, RateLimitInfo{
                    .worker_id = worker.id,
                    .remaining = rl.remaining,
                    .limit = rl.limit,
                    .reset_ms = rl.reset_ms,
                    .updated_at_ms = ids.nowMs(),
                }) catch {};
            }

            const output_json = try wrapOutput(alloc, final_output);
            try self.store.updateStepStatus(step_id, "completed", worker.id, output_json, null, 1);
            try self.store.insertEvent(run_row.id, step_id, "step.completed", "{}");
            self.emitEvent(alloc, .step_completed, run_row.id, step_id, node_name, null);
            try self.store.markWorkerSuccess(worker.id, ids.nowMs());

            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_success_total);
            }
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step_id, output_json, self.metrics);

            // Process UI messages and stream messages from worker response
            if (self.sse_hub) |hub| {
                processUiMessages(hub, alloc, run_row.id, step_id, final_output);
                processStreamMessages(hub, alloc, run_row.id, step_id, node_type, final_output);
            }

            // Build state_updates from output. Prefer explicit state_updates
            // from the worker, otherwise honor node-level output_key /
            // output_mapping before falling back to the legacy "output" key.
            const state_updates = try buildTaskStateUpdates(alloc, node_json, final_output);

            // Extract goto targets from output (command primitive)
            const goto_targets = extractGotoTargets(alloc, final_output);

            return TaskNodeResult{ .completed = .{ .state_updates = state_updates, .goto_targets = goto_targets, .raw_output = final_output } };
        } else {
            const err_text = result.error_text orelse "dispatch failed";
            try self.store.updateStepStatus(step_id, "failed", worker.id, null, err_text, 1);
            try self.store.insertEvent(run_row.id, step_id, "step.failed", "{}");
            self.emitEvent(alloc, .step_failed, run_row.id, step_id, node_name, null);

            const now_ms = ids.nowMs();
            const circuit_until = now_ms + self.runtime_cfg.worker_circuit_breaker_ms;
            try self.store.markWorkerFailure(
                worker.id,
                err_text,
                now_ms,
                self.runtime_cfg.worker_failure_threshold,
                circuit_until,
            );

            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_failure_total);
            }
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step_id, "{}", self.metrics);

            return TaskNodeResult{ .failed = err_text };
        }
    }

    // ── executeSubgraphNode ─────────────────────────────────────────

    fn executeSubgraphNode(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, node_name: []const u8, node_json: []const u8, state_json: []const u8, recursion_depth: u32) !TaskNodeResult {
        if (recursion_depth >= max_subgraph_depth) {
            log.err("subgraph node {s}: max recursion depth ({d}) exceeded", .{ node_name, max_subgraph_depth });
            return TaskNodeResult{ .failed = "subgraph max recursion depth exceeded" };
        }

        // Get workflow_id
        const workflow_id = getNodeField(alloc, node_json, "workflow_id") orelse {
            log.err("subgraph node {s}: missing workflow_id", .{node_name});
            return TaskNodeResult{ .failed = "subgraph missing workflow_id" };
        };

        // Load workflow definition from store
        const workflow_row = try self.store.getWorkflow(alloc, workflow_id);
        if (workflow_row == null) {
            log.err("subgraph node {s}: workflow {s} not found", .{ node_name, workflow_id });
            return TaskNodeResult{ .failed = "subgraph workflow not found" };
        }
        const definition = workflow_row.?.definition_json;

        // Build input state from parent state using input_mapping
        const input_mapping_json = getNodeField(alloc, node_json, "input_mapping") orelse "{}";
        const child_input = buildSubgraphInput(alloc, state_json, input_mapping_json) catch "{}";

        // Get schema from child workflow for initState
        const child_schema = getSchemaJson(alloc, definition);
        const child_state = state_mod.initState(alloc, child_input, child_schema) catch try alloc.dupe(u8, child_input);

        // Create child run
        const child_id_buf = ids.generateId();
        const child_id = try alloc.dupe(u8, &child_id_buf);
        try self.store.createRunWithState(child_id, workflow_id, definition, child_input, child_state);
        try self.store.setParentRunId(child_id, run_row.id);
        try self.store.updateRunStatus(child_id, "running", null);

        // Create step record for the subgraph node
        const step_id_buf = ids.generateId();
        const step_id = try alloc.dupe(u8, &step_id_buf);
        try self.store.insertStep(step_id, run_row.id, node_name, "subgraph", "running", "{}", 1, null, null, null);
        try self.store.insertEvent(run_row.id, step_id, "step.running", "{}");

        // Execute child run inline (recursive call to processRunWithDepth)
        const child_run = (try self.store.getRun(alloc, child_id)).?;
        self.processRunInline(alloc, child_run, recursion_depth + 1);

        // Check child run result
        const completed_child = (try self.store.getRun(alloc, child_id)).?;
        if (!std.mem.eql(u8, completed_child.status, "completed")) {
            const child_error = completed_child.error_text orelse "subgraph did not complete";
            try self.store.updateStepStatus(step_id, "failed", null, null, child_error, 1);
            return TaskNodeResult{ .failed = child_error };
        }

        // Extract output_key from child's final state
        const output_key = getNodeField(alloc, node_json, "output_key") orelse "output";
        const child_final_state = completed_child.state_json orelse "{}";

        // Get the value at output_key from child state
        const output_path = try std.fmt.allocPrint(alloc, "state.{s}", .{output_key});
        const output_value = state_mod.getStateValue(alloc, child_final_state, output_path) catch null;

        // Build state_updates: {output_key: value}
        const state_updates = if (output_value) |val|
            try std.fmt.allocPrint(alloc, "{{\"{s}\":{s}}}", .{ output_key, val })
        else
            try std.fmt.allocPrint(alloc, "{{\"{s}\":null}}", .{output_key});

        try self.store.updateStepStatus(step_id, "completed", null, state_updates, null, 1);
        try self.store.insertEvent(run_row.id, step_id, "step.completed", "{}");

        log.info("subgraph node {s} completed (child run {s})", .{ node_name, child_id });
        return TaskNodeResult{ .completed = .{ .state_updates = state_updates } };
    }

    // ── executeSendNode ──────────────────────────────────────────────

    fn executeSendNode(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, node_name: []const u8, node_json: []const u8, state_json: []const u8) !SendNodeResult {
        // Read items_key state path, with items_from kept as a legacy alias.
        const items_path = getSendItemsPath(alloc, node_json) orelse {
            log.warn("send node {s} missing items_key/items_from", .{node_name});
            return SendNodeResult{ .state_updates = null };
        };

        // Get the target_node
        const target_node = getNodeField(alloc, node_json, "target_node") orelse {
            log.warn("send node {s} missing target_node", .{node_name});
            return SendNodeResult{ .state_updates = null };
        };

        // Get target node definition from workflow
        const target_json = getNodeJson(alloc, run_row.workflow_json, target_node) orelse {
            log.warn("send node {s} target {s} not found", .{ node_name, target_node });
            return SendNodeResult{ .state_updates = null };
        };

        // Read items from state
        const items_json = state_mod.getStateValue(alloc, state_json, items_path) catch null;
        if (items_json == null) {
            log.warn("send node {s}: no items at path {s}", .{ node_name, items_path });
            return SendNodeResult{ .state_updates = null };
        }

        // Parse items as array
        const items_parsed = json.parseFromSlice(json.Value, alloc, items_json.?, .{}) catch {
            log.warn("send node {s}: items not valid JSON", .{node_name});
            return SendNodeResult{ .state_updates = null };
        };
        if (items_parsed.value != .array) {
            log.warn("send node {s}: items not an array", .{node_name});
            return SendNodeResult{ .state_updates = null };
        }

        // Build worker list once before iterating items
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
        const required_tags = getNodeTags(alloc, target_json);

        // For each item, execute the target node
        var results: std.ArrayListUnmanaged([]const u8) = .empty;
        for (items_parsed.value.array.items, 0..) |item, idx| {
            // Serialize item
            const item_str = serializeJsonValue(alloc, item) catch continue;

            // Get prompt template from target node
            const prompt_template = getNodeField(alloc, target_json, "prompt_template") orelse continue;

            // Render with item
            const rendered = self.renderWorkflowTemplate(alloc, run_row.workflow_json, prompt_template, state_json, run_row.input_json, item_str) catch continue;

            const selected_worker = try dispatch.selectWorker(alloc, worker_infos.items, required_tags);
            if (selected_worker == null) {
                try results.append(alloc, "null");
                continue;
            }
            const worker = selected_worker.?;

            // Create child step
            const child_step_id_buf = ids.generateId();
            const child_step_id = try alloc.dupe(u8, &child_step_id_buf);
            const child_def_id = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ node_name, idx });
            try self.store.insertStep(child_step_id, run_row.id, child_def_id, "task", "running", item_str, 1, null, null, @as(?i64, @intCast(idx)));
            try self.store.insertEvent(run_row.id, child_step_id, "step.running", "{}");

            const dr = try dispatch.dispatchStep(
                alloc,
                worker.url,
                worker.token,
                worker.protocol,
                worker.model,
                run_row.id,
                child_step_id,
                rendered,
            );

            if (dr.success) {
                const output_json = try wrapOutput(alloc, dr.output);
                try self.store.updateStepStatus(child_step_id, "completed", worker.id, output_json, null, 1);
                try self.store.insertEvent(run_row.id, child_step_id, "step.completed", "{}");
                try results.append(alloc, try jsonStringify(alloc, dr.output));
            } else {
                try self.store.updateStepStatus(child_step_id, "failed", worker.id, null, dr.error_text, 1);
                try results.append(alloc, "null");
            }
        }

        // Build state_updates from collected results
        const results_json = try serializeStringArray(alloc, results.items);
        const output_key = getNodeField(alloc, node_json, "output_key") orelse "send_results";
        const state_updates = try std.fmt.allocPrint(alloc, "{{\"{s}\":{s}}}", .{ output_key, results_json });

        // Create parent step record
        const step_id_buf = ids.generateId();
        const step_id = try alloc.dupe(u8, &step_id_buf);
        try self.store.insertStep(step_id, run_row.id, node_name, "send", "completed", "{}", 1, null, null, null);
        try self.store.updateStepStatus(step_id, "completed", null, state_updates, null, 1);
        try self.store.insertEvent(run_row.id, step_id, "step.completed", "{}");

        return SendNodeResult{ .state_updates = state_updates };
    }

    fn renderWorkflowTemplate(
        self: *Engine,
        alloc: std.mem.Allocator,
        workflow_json: []const u8,
        template: []const u8,
        state_json: []const u8,
        input_json: ?[]const u8,
        item_json: ?[]const u8,
    ) ![]const u8 {
        const store_access = self.resolveRuntimeStoreAccess(alloc, workflow_json, state_json);
        return templates.renderTemplateWithStore(alloc, template, state_json, input_json, item_json, store_access);
    }

    fn resolveRuntimeStoreAccess(self: *Engine, alloc: std.mem.Allocator, workflow_json: []const u8, state_json: []const u8) ?templates.StoreAccess {
        _ = alloc;
        _ = workflow_json;
        _ = state_json;
        const base_url = self.trusted_tracker_url orelse return null;
        return .{
            .base_url = base_url,
            .api_token = self.trusted_tracker_api_token,
            .fetcher = self.store_fetcher,
        };
    }

    fn applyStoreUpdates(self: *Engine, alloc: std.mem.Allocator, workflow_json: []const u8, state_json: []const u8, store_updates_json: []const u8) !void {
        const access = self.resolveRuntimeStoreAccess(alloc, workflow_json, state_json) orelse return error.StoreNotConfigured;
        const parsed = try json.parseFromSlice(json.Value, alloc, store_updates_json, .{});

        switch (parsed.value) {
            .object => try self.applySingleStoreUpdate(alloc, access, state_json, parsed.value.object),
            .array => |arr| {
                for (arr.items) |item| {
                    if (item != .object) return error.InvalidStoreUpdates;
                    try self.applySingleStoreUpdate(alloc, access, state_json, item.object);
                }
            },
            else => return error.InvalidStoreUpdates,
        }
    }

    fn applySingleStoreUpdate(self: *Engine, alloc: std.mem.Allocator, access: templates.StoreAccess, state_json: []const u8, obj: json.ObjectMap) !void {
        const namespace_val = obj.get("namespace") orelse return error.InvalidStoreUpdates;
        const key_val = obj.get("key") orelse return error.InvalidStoreUpdates;
        const value_val = obj.get("value") orelse return error.InvalidStoreUpdates;

        if (namespace_val != .string or key_val != .string) return error.InvalidStoreUpdates;

        const value_json = try resolveStoreUpdateValue(alloc, state_json, value_val);
        try self.store_writer(alloc, access.base_url, access.api_token, namespace_val.string, key_val.string, value_json);
    }

    // ── Async polling ────────────────────────────────────────────────

    fn pollAsyncTaskStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
        const input_json = step.input_json;
        if (input_json.len == 0) return;

        const parsed = json.parseFromSlice(json.Value, alloc, input_json, .{}) catch return;
        if (parsed.value != .object) return;

        const async_flag = parsed.value.object.get("async_pending") orelse return;
        if (async_flag != .bool or !async_flag.bool) return;

        const corr_val = parsed.value.object.get("correlation_id") orelse return;
        if (corr_val != .string) return;
        const correlation_id = corr_val.string;

        const queue = self.response_queue orelse return;
        const response = queue.take(correlation_id) orelse {
            if (step.timeout_ms) |timeout_ms| {
                if (step.started_at_ms) |started_at| {
                    const elapsed = ids.nowMs() - started_at;
                    if (elapsed > timeout_ms) {
                        const err_text = try std.fmt.allocPrint(alloc, "async step timed out after {d}ms", .{timeout_ms});
                        try self.store.updateStepStatus(step.id, "failed", step.worker_id, null, err_text, step.attempt);
                        try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
                        if (self.metrics) |m| {
                            metrics_mod.Metrics.incr(&m.worker_dispatch_failure_total);
                        }
                        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
                        log.err("async step {s} timed out", .{step.id});
                    }
                }
            }
            return;
        };

        if (response.success) {
            const output_json = try wrapOutput(alloc, response.output);
            try self.store.updateStepStatus(step.id, "completed", step.worker_id, output_json, null, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.completed", "{}");
            if (step.worker_id) |wid| {
                try self.store.markWorkerSuccess(wid, ids.nowMs());
            }
            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_success_total);
            }
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output_json, self.metrics);
            log.info("async step {s} completed", .{step.id});
        } else {
            const err_text = response.error_text orelse "async dispatch failed";
            try self.store.updateStepStatus(step.id, "failed", step.worker_id, null, err_text, step.attempt);
            try self.store.insertEvent(run_row.id, step.id, "step.failed", "{}");
            if (step.worker_id) |wid| {
                const now_ms = ids.nowMs();
                const circuit_until = now_ms + self.runtime_cfg.worker_circuit_breaker_ms;
                try self.store.markWorkerFailure(wid, err_text, now_ms, self.runtime_cfg.worker_failure_threshold, circuit_until);
            }
            if (self.metrics) |m| {
                metrics_mod.Metrics.incr(&m.worker_dispatch_failure_total);
            }
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.failed", run_row.id, step.id, "{}", self.metrics);
            log.err("async step {s} failed: {s}", .{ step.id, err_text });
        }
    }

    /// Merge async_pending + correlation_id into existing input_json.
    fn mergeAsyncState(alloc: std.mem.Allocator, existing_input: []const u8, correlation_id: []const u8) ![]const u8 {
        var obj = json.ObjectMap.init(alloc);

        if (existing_input.len > 0) {
            const p = json.parseFromSlice(json.Value, alloc, existing_input, .{}) catch null;
            if (p) |parsed| {
                if (parsed.value == .object) {
                    var it = parsed.value.object.iterator();
                    while (it.next()) |entry| {
                        try obj.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                }
            }
        }

        try obj.put("async_pending", .{ .bool = true });
        try obj.put("correlation_id", .{ .string = correlation_id });

        return json.Stringify.valueAlloc(alloc, json.Value{ .object = obj }, .{});
    }
};

// ── findReadyNodes ──────────────────────────────────────────────────

/// Find nodes that are ready to execute.
/// A node is ready when ALL its inbound edges have their source in completed_nodes.
/// __start__ is always "completed" (synthetic).
/// For conditional edges "source:value", the source is just "source" (strip after `:`)
/// and the edge is only satisfied if route_results[source] == value.
pub fn findReadyNodes(
    alloc: std.mem.Allocator,
    workflow_json: []const u8,
    completed_nodes: *std.StringHashMap(void),
    route_results: *std.StringHashMap([]const u8),
) ![]const []const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch {
        return &.{};
    };
    return findReadyNodesFromRoot(alloc, parsed.value, completed_nodes, route_results);
}

fn findReadyNodesFromRoot(
    alloc: std.mem.Allocator,
    root: json.Value,
    completed_nodes: *std.StringHashMap(void),
    route_results: *std.StringHashMap([]const u8),
) ![]const []const u8 {
    if (root != .object) return &.{};

    // Get edges array
    const edges_val = root.object.get("edges") orelse return &.{};
    if (edges_val != .array) return &.{};

    // Get all node names from "nodes" object
    const nodes_val = root.object.get("nodes") orelse return &.{};
    if (nodes_val != .object) return &.{};

    // Build inbound edge map: target -> list of (source, condition_value?)
    const EdgeInfo = struct {
        source: []const u8,
        condition: ?[]const u8, // null for unconditional, "value" for conditional
    };

    var inbound = std.StringHashMap(std.ArrayListUnmanaged(EdgeInfo)).init(alloc);

    // Also collect all target nodes mentioned in edges
    for (edges_val.array.items) |edge_item| {
        if (edge_item != .array) continue;
        if (edge_item.array.items.len < 2) continue;

        const source_raw = if (edge_item.array.items[0] == .string) edge_item.array.items[0].string else continue;
        const target = if (edge_item.array.items[1] == .string) edge_item.array.items[1].string else continue;

        // Parse source: might be "node:value" for conditional edges
        var source: []const u8 = source_raw;
        var condition: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, source_raw, ':')) |colon_pos| {
            source = source_raw[0..colon_pos];
            condition = source_raw[colon_pos + 1 ..];
        }

        var entry = inbound.getPtr(target);
        if (entry == null) {
            try inbound.put(target, std.ArrayListUnmanaged(EdgeInfo){});
            entry = inbound.getPtr(target);
        }
        try entry.?.append(alloc, .{
            .source = source,
            .condition = condition,
        });
    }

    // Detect dead nodes: nodes that are unreachable because a conditional
    // edge was not taken. A node is dead if ALL its inbound edges are
    // conditional and none match the route result. Dead nodes propagate:
    // any node whose only inbound edges come from dead nodes is also dead.
    var dead_nodes = std.StringHashMap(void).init(alloc);

    // Iterative dead node detection (propagate through the graph)
    var changed = true;
    while (changed) {
        changed = false;
        var dead_it = inbound.iterator();
        while (dead_it.next()) |kv| {
            const target = kv.key_ptr.*;
            const edges = kv.value_ptr.items;

            if (dead_nodes.get(target) != null) continue;
            if (completed_nodes.get(target) != null) continue;

            var all_dead_or_unsat = true;
            for (edges) |edge| {
                if (std.mem.eql(u8, edge.source, "__start__")) {
                    // __start__ is never dead
                    all_dead_or_unsat = false;
                    break;
                }

                // If source is dead, this edge is dead
                if (dead_nodes.get(edge.source) != null) continue;

                if (edge.condition) |cond| {
                    // Conditional edge: check if source completed and condition matched
                    if (completed_nodes.get(edge.source) != null) {
                        if (route_results.get(edge.source)) |actual| {
                            if (std.mem.eql(u8, actual, cond)) {
                                // This edge IS satisfied
                                all_dead_or_unsat = false;
                                break;
                            }
                        }
                        // Source completed but condition didn't match -> dead edge
                    } else {
                        // Source not completed yet and not dead -> not dead yet
                        all_dead_or_unsat = false;
                        break;
                    }
                } else {
                    // Non-conditional edge from a live, non-dead source
                    all_dead_or_unsat = false;
                    break;
                }
            }

            if (all_dead_or_unsat) {
                try dead_nodes.put(target, {});
                changed = true;
            }
        }
    }

    // Find ready nodes: for each node, check if all inbound edges are satisfied
    // (treating dead source nodes as satisfied)
    var ready: std.ArrayListUnmanaged([]const u8) = .empty;

    var inbound_it = inbound.iterator();
    while (inbound_it.next()) |kv| {
        const target = kv.key_ptr.*;
        const edges = kv.value_ptr.items;

        // Skip if already completed or dead
        if (completed_nodes.get(target) != null) continue;
        if (dead_nodes.get(target) != null) continue;

        var all_satisfied = true;
        var any_conditional_edge = false;
        var any_conditional_satisfied = false;

        for (edges) |edge| {
            // __start__ is always satisfied
            if (std.mem.eql(u8, edge.source, "__start__")) continue;

            // Dead sources are considered satisfied (their branch was skipped)
            if (dead_nodes.get(edge.source) != null) continue;

            const source_completed = completed_nodes.get(edge.source) != null;

            if (!source_completed) {
                all_satisfied = false;
                break;
            }

            if (edge.condition) |cond| {
                any_conditional_edge = true;
                if (route_results.get(edge.source)) |actual| {
                    if (std.mem.eql(u8, actual, cond)) {
                        any_conditional_satisfied = true;
                    }
                }
            }
        }

        if (!all_satisfied) continue;

        // If there are conditional edges, at least one must be satisfied
        if (any_conditional_edge and !any_conditional_satisfied) continue;

        try ready.append(alloc, target);
    }

    return ready.toOwnedSlice(alloc);
}

// ── Workflow JSON Helpers ────────────────────────────────────────────

/// Get the JSON string for a specific node from workflow_json.
/// Workflow format: {"nodes": {"node_name": {...}}, "edges": [...]}
fn getNodeJson(alloc: std.mem.Allocator, workflow_json: []const u8, node_name: []const u8) ?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return null;
    return getNodeJsonFromRoot(alloc, parsed.value, node_name);
}

fn getNodeJsonFromRoot(alloc: std.mem.Allocator, root: json.Value, node_name: []const u8) ?[]const u8 {
    if (root != .object) return null;

    const nodes = root.object.get("nodes") orelse return null;
    if (nodes != .object) return null;

    const node = nodes.object.get(node_name) orelse return null;
    return serializeJsonValue(alloc, node) catch null;
}

fn workflowHasNode(root: json.Value, node_name: []const u8) bool {
    if (root != .object) return false;
    const nodes = root.object.get("nodes") orelse return false;
    if (nodes != .object) return false;
    return nodes.object.get(node_name) != null;
}

/// Get a string field from a node's JSON.
fn getNodeField(alloc: std.mem.Allocator, node_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, node_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    if (val == .string) return alloc.dupe(u8, val.string) catch null;
    return serializeJsonValue(alloc, val) catch null;
}

/// Get the state schema JSON from a workflow definition.
/// Looks up "state_schema" first (canonical key used by API/validation),
/// then falls back to "schema" for inline workflow definitions in tests.
fn getSchemaJson(alloc: std.mem.Allocator, workflow_json: []const u8) []const u8 {
    return getWorkflowField(alloc, workflow_json, "state_schema") orelse
        getWorkflowField(alloc, workflow_json, "schema") orelse
        "{}";
}

/// Get a top-level field from workflow_json.
fn getWorkflowField(alloc: std.mem.Allocator, workflow_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    if (val == .string) return alloc.dupe(u8, val.string) catch null;
    return serializeJsonValue(alloc, val) catch null;
}

fn getRuntimeStringSetting(
    alloc: std.mem.Allocator,
    state_json: []const u8,
    workflow_json: []const u8,
    field_names: []const []const u8,
) ?[]const u8 {
    for (field_names) |field_name| {
        if (getConfigString(alloc, state_json, field_name)) |value| return value;
    }
    for (field_names) |field_name| {
        if (getWorkflowField(alloc, workflow_json, field_name)) |value| return value;
    }
    return null;
}

fn getConfigString(alloc: std.mem.Allocator, state_json: []const u8, field_name: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(alloc, "state.__config.{s}", .{field_name}) catch return null;
    defer alloc.free(path);

    const raw = state_mod.getStateValue(alloc, state_json, path) catch return null;
    const raw_value = raw orelse return null;
    defer alloc.free(raw_value);

    const parsed = json.parseFromSlice(json.Value, alloc, raw_value, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .string) return null;
    return alloc.dupe(u8, parsed.value.string) catch null;
}

fn resolveStoreUpdateValue(alloc: std.mem.Allocator, state_json: []const u8, value: json.Value) ![]const u8 {
    if (value == .string and std.mem.startsWith(u8, value.string, "state.")) {
        const raw = try state_mod.getStateValue(alloc, state_json, value.string);
        return raw orelse try alloc.dupe(u8, "null");
    }
    return serializeJsonValue(alloc, value);
}

fn putStoreValueViaHttp(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    api_token: ?[]const u8,
    namespace: []const u8,
    key: []const u8,
    value_json: []const u8,
) !void {
    var client = tracker_client.TrackerClient.init(alloc, base_url, api_token);
    const ok = try client.storePutValue(namespace, key, value_json);
    if (!ok) return error.StoreWriteFailed;
}

fn encodePathSegment(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (value) |byte| {
        if ((byte >= 'A' and byte <= 'Z') or
            (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or
            byte == '_' or
            byte == '.' or
            byte == '~')
        {
            try buf.append(allocator, byte);
        } else {
            try buf.writer(allocator).print("%{X:0>2}", .{byte});
        }
    }

    return buf.toOwnedSlice(allocator);
}

var test_store_write_base_url: []const u8 = "";
var test_store_write_api_token: ?[]const u8 = null;
var test_store_write_namespace: []const u8 = "";
var test_store_write_key: []const u8 = "";
var test_store_write_value_json: []const u8 = "";

fn mockStoreWriter(
    alloc: std.mem.Allocator,
    base_url: []const u8,
    api_token: ?[]const u8,
    namespace: []const u8,
    key: []const u8,
    value_json: []const u8,
) !void {
    _ = alloc;
    test_store_write_base_url = base_url;
    test_store_write_api_token = api_token;
    test_store_write_namespace = namespace;
    test_store_write_key = key;
    test_store_write_value_json = value_json;
}

/// Get worker tags from node definition.
fn getNodeTags(alloc: std.mem.Allocator, node_json: []const u8) []const []const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, node_json, .{}) catch return &.{};
    if (parsed.value != .object) return &.{};
    const tags = parsed.value.object.get("worker_tags") orelse return &.{};
    if (tags != .array) return &.{};

    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    for (tags.array.items) |item| {
        if (item == .string) {
            result.append(alloc, item.string) catch continue;
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

// ── JSON / Serialization Helpers ────────────────────────────────────

fn serializeJsonValue(alloc: std.mem.Allocator, value: json.Value) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(alloc);
    var jw: json.Stringify = .{ .writer = &out.writer };
    try jw.write(value);
    return try out.toOwnedSlice();
}

/// Wrap a raw output string as {"output": "..."} JSON.
fn wrapOutput(alloc: std.mem.Allocator, output: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(alloc, .{
        .output = output,
    }, .{});
}

/// Escape a string as a JSON string literal (with quotes).
fn jsonStringify(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(alloc, s, .{});
}

/// Resolve the state path used by a send node. `items_key` is the canonical
/// field; `items_from` is accepted as a compatibility alias.
fn getSendItemsPath(alloc: std.mem.Allocator, node_json: []const u8) ?[]const u8 {
    return getNodeField(alloc, node_json, "items_key") orelse
        getNodeField(alloc, node_json, "items_from");
}

/// Build the state update payload for a task/agent node result.
///
/// Precedence:
/// 1. explicit worker-provided `state_updates`
/// 2. node `output_key` / `output_mapping`
/// 3. legacy fallback to `{"output": "..."}`
fn buildTaskStateUpdates(alloc: std.mem.Allocator, node_json: []const u8, output: []const u8) ![]const u8 {
    if (extractStateUpdates(alloc, output)) |updates| {
        return updates;
    }

    const output_key = getNodeField(alloc, node_json, "output_key");
    const output_mapping_json = getNodeObjectField(alloc, node_json, "output_mapping");
    if (output_key == null and output_mapping_json == null) {
        return std.fmt.allocPrint(alloc, "{{\"output\":{s}}}", .{try jsonStringify(alloc, output)});
    }

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var result = json.ObjectMap.init(arena_alloc);
    const parsed_output = json.parseFromSlice(json.Value, arena_alloc, output, .{}) catch null;

    if (output_key) |key| {
        if (parsed_output) |parsed| {
            try result.put(key, parsed.value);
        } else {
            try result.put(key, .{ .string = output });
        }
    }

    if (output_mapping_json) |mapping_json| {
        const parsed_mapping = json.parseFromSlice(json.Value, arena_alloc, mapping_json, .{}) catch null;
        if (parsed_mapping) |mapping| {
            if (mapping.value == .object and parsed_output != null) {
                var it = mapping.value.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .string) continue;
                    const source_path = entry.value_ptr.string;
                    const raw_val = state_mod.getStateValue(arena_alloc, output, source_path) catch null;
                    if (raw_val) |value_json| {
                        const parsed_value = json.parseFromSlice(json.Value, arena_alloc, value_json, .{}) catch continue;
                        try result.put(entry.key_ptr.*, parsed_value.value);
                    }
                }
            }
        }
    }

    return serializeJsonValue(alloc, .{ .object = result });
}

/// Serialize completed_nodes set to JSON array.
fn serializeCompletedNodes(alloc: std.mem.Allocator, completed_nodes: *std.StringHashMap(void)) ![]const u8 {
    var arr: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = completed_nodes.iterator();
    while (it.next()) |entry| {
        try arr.append(alloc, entry.key_ptr.*);
    }
    return json.Stringify.valueAlloc(alloc, arr.items, .{});
}

/// Serialize route_results map + workflow_version to JSON for checkpoint metadata.
fn serializeRouteResults(alloc: std.mem.Allocator, route_results: *std.StringHashMap([]const u8)) !?[]const u8 {
    return serializeRouteResultsWithVersion(alloc, route_results, null);
}

fn serializeRouteResultsWithVersion(alloc: std.mem.Allocator, route_results: *std.StringHashMap([]const u8), wf_version: ?i64) !?[]const u8 {
    if (route_results.count() == 0 and wf_version == null) return null;

    var obj = json.ObjectMap.init(alloc);

    if (route_results.count() > 0) {
        var rr_obj = json.ObjectMap.init(alloc);
        var it = route_results.iterator();
        while (it.next()) |entry| {
            try rr_obj.put(entry.key_ptr.*, .{ .string = entry.value_ptr.* });
        }
        try obj.put("route_results", .{ .object = rr_obj });
    }

    if (wf_version) |v| {
        try obj.put("workflow_version", .{ .integer = v });
    }

    return try serializeJsonValue(alloc, .{ .object = obj });
}

/// Serialize a string array as JSON.
fn serializeStringArray(alloc: std.mem.Allocator, items: []const []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(alloc, items, .{});
}

/// Try to extract "state_updates" from worker output JSON.
/// Worker can return: {"state_updates": {"key": "value"}, ...}
fn extractStateUpdates(alloc: std.mem.Allocator, output: []const u8) ?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, output, .{}) catch return null;
    if (parsed.value != .object) return null;
    const su = parsed.value.object.get("state_updates") orelse return null;
    return serializeJsonValue(alloc, su) catch null;
}

/// Extract "goto" field from worker output JSON.
/// Returns array of target node names. Supports:
///   - "goto": "node_name" -> ["node_name"]
///   - "goto": ["node_a", "node_b"] -> ["node_a", "node_b"]
fn extractGotoTargets(alloc: std.mem.Allocator, output: []const u8) ?[]const []const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, output, .{}) catch return null;
    if (parsed.value != .object) return null;
    const goto_val = parsed.value.object.get("goto") orelse return null;

    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    if (goto_val == .string) {
        targets.append(alloc, goto_val.string) catch return null;
    } else if (goto_val == .array) {
        for (goto_val.array.items) |item| {
            if (item == .string) {
                targets.append(alloc, item.string) catch continue;
            }
        }
    } else {
        return null;
    }

    if (targets.items.len == 0) return null;
    return targets.toOwnedSlice(alloc) catch null;
}

/// Parse interrupt_before / interrupt_after arrays from workflow definition.
fn parseBreakpointList(alloc: std.mem.Allocator, workflow_json: []const u8, field: []const u8) []const []const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return &.{};
    return parseBreakpointListFromRoot(alloc, parsed.value, field);
}

fn parseBreakpointListFromRoot(alloc: std.mem.Allocator, root: json.Value, field: []const u8) []const []const u8 {
    if (root != .object) return &.{};
    const arr_val = root.object.get(field) orelse return &.{};
    if (arr_val != .array) return &.{};

    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    for (arr_val.array.items) |item| {
        if (item == .string) {
            result.append(alloc, item.string) catch continue;
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

/// Check if a node name is in a breakpoint list.
fn isInBreakpointList(name: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, name, item)) return true;
    }
    return false;
}

/// Get an integer field from a node's JSON.
fn getNodeFieldInt(alloc: std.mem.Allocator, node_json: []const u8, field: []const u8) ?i64 {
    const parsed = json.parseFromSlice(json.Value, alloc, node_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    if (val == .integer) return val.integer;
    return null;
}

/// Get a float field from a node's JSON.
fn getNodeFieldFloat(alloc: std.mem.Allocator, node_json: []const u8, field: []const u8) ?f64 {
    const parsed = json.parseFromSlice(json.Value, alloc, node_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    if (val == .float) return val.float;
    if (val == .integer) return @as(f64, @floatFromInt(val.integer));
    return null;
}

/// Get a nested object field as JSON string from a node's JSON.
fn getNodeObjectField(alloc: std.mem.Allocator, node_json: []const u8, field: []const u8) ?[]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, node_json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const val = parsed.value.object.get(field) orelse return null;
    if (val != .object) return null;
    return serializeJsonValue(alloc, val) catch null;
}

// ── Retry Config Helpers (Gap 2) ────────────────────────────────────

/// Parse retry.max_attempts from node JSON. Returns null if no retry config.
fn parseRetryMaxAttempts(alloc: std.mem.Allocator, node_json: []const u8) ?u32 {
    const retry_json = getNodeObjectField(alloc, node_json, "retry") orelse return null;
    const val = getNodeFieldInt(alloc, retry_json, "max_attempts") orelse return null;
    if (val < 1) return 1;
    if (val > 100) return 100;
    return @intCast(val);
}

fn parseRetryInitialMs(alloc: std.mem.Allocator, node_json: []const u8) ?u64 {
    const retry_json = getNodeObjectField(alloc, node_json, "retry") orelse return null;
    const val = getNodeFieldInt(alloc, retry_json, "initial_interval_ms") orelse return null;
    if (val < 0) return 0;
    return @intCast(val);
}

fn parseRetryBackoff(alloc: std.mem.Allocator, node_json: []const u8) ?f64 {
    const retry_json = getNodeObjectField(alloc, node_json, "retry") orelse return null;
    return getNodeFieldFloat(alloc, retry_json, "backoff_factor");
}

fn parseRetryMaxMs(alloc: std.mem.Allocator, node_json: []const u8) ?u64 {
    const retry_json = getNodeObjectField(alloc, node_json, "retry") orelse return null;
    const val = getNodeFieldInt(alloc, retry_json, "max_interval_ms") orelse return null;
    if (val < 0) return 0;
    return @intCast(val);
}

// ── Cache Key Helpers (Gap 3) ───────────────────────────────────────

/// Parse cache.ttl_ms from node JSON. Returns null if no cache config.
fn parseCacheTtlMs(alloc: std.mem.Allocator, node_json: []const u8) ?i64 {
    const cache_json = getNodeObjectField(alloc, node_json, "cache") orelse return null;
    return getNodeFieldInt(alloc, cache_json, "ttl_ms");
}

/// Compute a cache key from node_name + rendered_prompt using FNV hash.
fn computeCacheKey(alloc: std.mem.Allocator, node_name: []const u8, rendered_prompt: []const u8) ![]const u8 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(node_name);
    hasher.update("|");
    hasher.update(rendered_prompt);
    const hash = hasher.final();
    return try std.fmt.allocPrint(alloc, "{x:0>16}", .{hash});
}

// ── Deferred Node Helpers (Gap 6) ───────────────────────────────────

/// Collect all deferred node names from workflow.
fn collectDeferredNodes(alloc: std.mem.Allocator, workflow_json: []const u8) []const []const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return &.{};
    return collectDeferredNodesFromRoot(alloc, parsed.value);
}

fn collectDeferredNodesFromRoot(alloc: std.mem.Allocator, root: json.Value) []const []const u8 {
    if (root != .object) return &.{};
    const nodes_val = root.object.get("nodes") orelse return &.{};
    if (nodes_val != .object) return &.{};

    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = nodes_val.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const node = entry.value_ptr.*;
        if (node == .object) {
            if (node.object.get("defer")) |d| {
                if (d == .bool and d.bool) {
                    result.append(alloc, name) catch continue;
                }
            }
        }
    }
    return result.toOwnedSlice(alloc) catch &.{};
}

// ── Managed Values Helpers (Gap 7) ──────────────────────────────────

/// Inject __meta into state JSON before node execution.
fn injectMeta(alloc: std.mem.Allocator, state_json: []const u8, run_id: []const u8, node_name: []const u8, step_number: i64, max_steps: i64) ![]const u8 {
    const remaining = max_steps - step_number;
    const is_last = (step_number >= max_steps - 1);
    const meta_json = try std.fmt.allocPrint(alloc,
        \\{{"__meta":{{"step":{d},"is_last_step":{s},"remaining_steps":{d},"run_id":"{s}","node_name":"{s}"}}}}
    , .{ step_number, if (is_last) "true" else "false", remaining, run_id, node_name });

    // Merge __meta into state using simple applyUpdates with empty schema (last_value default)
    return state_mod.applyUpdates(alloc, state_json, meta_json, "{}");
}

/// Remove __meta from state JSON after node execution (don't persist in checkpoints).
fn stripMeta(alloc: std.mem.Allocator, state_json: []const u8) ![]const u8 {
    const parsed = json.parseFromSlice(json.Value, alloc, state_json, .{}) catch return try alloc.dupe(u8, state_json);
    if (parsed.value != .object) return try alloc.dupe(u8, state_json);

    var result_obj = json.ObjectMap.init(alloc);
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "__meta")) {
            try result_obj.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    return serializeJsonValue(alloc, .{ .object = result_obj });
}

/// Build subgraph input state from parent state using input_mapping.
/// input_mapping is {"child_key": "state.parent_key", ...}
fn buildSubgraphInput(alloc: std.mem.Allocator, parent_state: []const u8, input_mapping_json: []const u8) ![]const u8 {
    const mapping_parsed = json.parseFromSlice(json.Value, alloc, input_mapping_json, .{}) catch return try alloc.dupe(u8, "{}");
    if (mapping_parsed.value != .object) return try alloc.dupe(u8, "{}");

    var result = json.ObjectMap.init(alloc);
    var it = mapping_parsed.value.object.iterator();
    while (it.next()) |entry| {
        const child_key = entry.key_ptr.*;
        const parent_path = if (entry.value_ptr.* == .string) entry.value_ptr.string else continue;

        // Resolve the value from parent state
        if (state_mod.getStateValue(alloc, parent_state, parent_path) catch null) |value_str| {
            const val_parsed = json.parseFromSlice(json.Value, alloc, value_str, .{}) catch continue;
            try result.put(child_key, val_parsed.value);
        }
    }

    return serializeJsonValue(alloc, .{ .object = result });
}

/// Reconcile with nulltickets: check if associated task has been cancelled.
/// Returns true if the run should continue, false if it should be cancelled.
fn reconcileWithTracker(alloc: std.mem.Allocator, tracker_url: []const u8, tracker_api_token: ?[]const u8, task_id: []const u8) bool {
    const task_id_enc = encodePathSegment(alloc, task_id) catch return true;
    defer alloc.free(task_id_enc);

    const url = std.fmt.allocPrint(alloc, "{s}/tasks/{s}", .{ tracker_url, task_id_enc }) catch return true;
    defer alloc.free(url);

    var client: std.http.Client = .{ .allocator = alloc };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(alloc);
    defer response_body.deinit();

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| alloc.free(value);
    var headers_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (tracker_api_token) |token| blk: {
        auth_header = std.fmt.allocPrint(alloc, "Bearer {s}", .{token}) catch return true;
        headers_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk headers_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch return true; // network errors -> continue

    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) return true;

    const body = response_body.written();
    const parsed = json.parseFromSlice(json.Value, alloc, body, .{}) catch return true;
    if (parsed.value != .object) return true;

    const stage = parsed.value.object.get("stage") orelse return true;
    if (stage != .string) return true;

    // Terminal states -> cancel
    if (std.mem.eql(u8, stage.string, "done") or
        std.mem.eql(u8, stage.string, "cancelled") or
        std.mem.eql(u8, stage.string, "canceled"))
    {
        log.info("reconciliation: task {s} is in terminal state '{s}', cancelling run", .{ task_id, stage.string });
        return false;
    }

    return true;
}

// ── Rich Streaming Helpers ──────────────────────────────────────────

/// Broadcast multi-mode SSE events for a node execution.
/// Emits events in values, updates, tasks, and debug modes.
fn broadcastNodeEvents(
    hub: *sse_mod.SseHub,
    alloc: std.mem.Allocator,
    run_id: []const u8,
    node_name: []const u8,
    node_type: []const u8,
    state_json: []const u8,
    state_updates: ?[]const u8,
    step_number: i64,
    duration_ms: i64,
) void {
    const step_id_buf = ids.generateId();
    const step_id = alloc.dupe(u8, &step_id_buf) catch return;
    const now_ms = ids.nowMs();
    // ISO 8601 timestamp (approximate, using epoch ms)
    const ts_str = std.fmt.allocPrint(alloc, "{d}", .{now_ms}) catch "0";

    // values mode: full state after step
    const values_data = std.fmt.allocPrint(alloc,
        \\{{"event":"values","data":{{"step":"{s}","state":{s}}}}}
    , .{ node_name, state_json }) catch null;
    if (values_data) |vd| {
        hub.broadcast(run_id, .{ .event_type = "values", .data = vd, .mode = .values });
    }

    // updates mode: node name + partial updates
    const updates_payload = state_updates orelse "{}";
    const updates_data = std.fmt.allocPrint(alloc,
        \\{{"event":"updates","data":{{"step":"{s}","updates":{s}}}}}
    , .{ node_name, updates_payload }) catch null;
    if (updates_data) |ud| {
        hub.broadcast(run_id, .{ .event_type = "updates", .data = ud, .mode = .updates });
    }

    // tasks mode: task_start and task_result
    const task_start_data = std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","name":"{s}","type":"{s}"}}
    , .{ step_id, node_name, node_type }) catch null;
    if (task_start_data) |tsd| {
        hub.broadcast(run_id, .{ .event_type = "task_start", .data = tsd, .mode = .tasks });
    }

    const task_result_data = std.fmt.allocPrint(alloc,
        \\{{"id":"{s}","name":"{s}","result":{s},"duration_ms":{d}}}
    , .{ step_id, node_name, updates_payload, duration_ms }) catch null;
    if (task_result_data) |trd| {
        hub.broadcast(run_id, .{ .event_type = "task_result", .data = trd, .mode = .tasks });
    }

    // debug mode: wrapped with step number and timestamp
    const debug_data = std.fmt.allocPrint(alloc,
        \\{{"step_number":{d},"timestamp_ms":{s},"type":"task_result","payload":{{"name":"{s}","updates":{s},"duration_ms":{d}}}}}
    , .{ step_number, ts_str, node_name, updates_payload, duration_ms }) catch null;
    if (debug_data) |dd| {
        hub.broadcast(run_id, .{ .event_type = "debug", .data = dd, .mode = .debug });
    }
}

/// Get workflow version from workflow JSON definition.
fn getWorkflowVersion(alloc: std.mem.Allocator, workflow_json: []const u8) i64 {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return 1;
    if (parsed.value != .object) return 1;
    const val = parsed.value.object.get("version") orelse return 1;
    if (val == .integer) return val.integer;
    return 1;
}

/// Get workflow version from checkpoint metadata.
fn getCheckpointWorkflowVersion(alloc: std.mem.Allocator, metadata_json: ?[]const u8) i64 {
    const meta = metadata_json orelse return 1;
    const parsed = json.parseFromSlice(json.Value, alloc, meta, .{}) catch return 1;
    if (parsed.value != .object) return 1;
    const val = parsed.value.object.get("workflow_version") orelse return 1;
    if (val == .integer) return val.integer;
    return 1;
}

/// Filter completed nodes to only those still present in the workflow definition.
/// Returns true if any nodes were removed (migration happened).
fn migrateCompletedNodes(alloc: std.mem.Allocator, completed_nodes: *std.StringHashMap(void), workflow_json: []const u8) bool {
    const parsed = json.parseFromSlice(json.Value, alloc, workflow_json, .{}) catch return false;
    if (parsed.value != .object) return false;
    const nodes_val = parsed.value.object.get("nodes") orelse return false;
    if (nodes_val != .object) return false;

    var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = completed_nodes.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        // Keep special nodes
        if (std.mem.eql(u8, name, "__start__") or std.mem.eql(u8, name, "__end__")) continue;
        // Remove if node no longer exists in workflow
        if (nodes_val.object.get(name) == null) {
            to_remove.append(alloc, name) catch continue;
        }
    }

    if (to_remove.items.len == 0) return false;

    for (to_remove.items) |name| {
        _ = completed_nodes.remove(name);
        log.warn("migration: removed completed node '{s}' (no longer in workflow)", .{name});
    }
    return true;
}

// ── UI Messages ──────────────────────────────────────────────────────

/// Process "ui_messages" from worker response JSON.
/// For each message:
///   - If it has "remove": true -> broadcast as "ui_message_delete" SSE event
///   - Otherwise -> broadcast as "ui_message" SSE event
/// Also applies to state.__ui_messages via add_messages reducer.
fn processUiMessages(hub: *sse_mod.SseHub, alloc: std.mem.Allocator, run_id: []const u8, step_id: []const u8, response_json: []const u8) void {
    const parsed = json.parseFromSlice(json.Value, alloc, response_json, .{}) catch return;
    if (parsed.value != .object) return;
    const ui_msgs_val = parsed.value.object.get("ui_messages") orelse return;
    if (ui_msgs_val != .array) return;

    for (ui_msgs_val.array.items) |msg| {
        if (msg != .object) continue;

        // Check for remove flag
        const is_remove = blk: {
            if (msg.object.get("remove")) |rm_val| {
                if (rm_val == .bool) break :blk rm_val.bool;
            }
            break :blk false;
        };

        // Add step_id to the event data
        var event_obj = json.ObjectMap.init(alloc);
        var it = msg.object.iterator();
        while (it.next()) |entry| {
            event_obj.put(entry.key_ptr.*, entry.value_ptr.*) catch continue;
        }
        event_obj.put("step_id", .{ .string = step_id }) catch {};
        const event_data = serializeJsonValue(alloc, .{ .object = event_obj }) catch continue;

        if (is_remove) {
            hub.broadcast(run_id, .{ .event_type = "ui_message_delete", .data = event_data, .mode = .custom });
        } else {
            hub.broadcast(run_id, .{ .event_type = "ui_message", .data = event_data, .mode = .custom });
        }
    }
}

/// Apply ui_messages to run state's __ui_messages key using add_messages reducer.
fn applyUiMessagesToState(alloc: std.mem.Allocator, state_json: []const u8, response_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const resp_parsed = json.parseFromSlice(json.Value, arena_alloc, response_json, .{}) catch return try alloc.dupe(u8, state_json);
    if (resp_parsed.value != .object) return try alloc.dupe(u8, state_json);
    const ui_msgs_val = resp_parsed.value.object.get("ui_messages") orelse return try alloc.dupe(u8, state_json);
    if (ui_msgs_val != .array) return try alloc.dupe(u8, state_json);

    // Serialize the ui_messages array
    const ui_msgs_json = serializeJsonValue(arena_alloc, ui_msgs_val) catch return try alloc.dupe(u8, state_json);

    // Build updates: {"__ui_messages": <ui_msgs>}
    const updates = std.fmt.allocPrint(arena_alloc, "{{\"__ui_messages\":{s}}}", .{ui_msgs_json}) catch return try alloc.dupe(u8, state_json);

    // Build a temporary schema that uses add_messages for __ui_messages
    const schema =
        \\{"__ui_messages":{"type":"array","reducer":"add_messages"}}
    ;

    return state_mod.applyUpdates(alloc, state_json, updates, schema) catch try alloc.dupe(u8, state_json);
}

// ── Stream Messages ──────────────────────────────────────────────────

/// Process "stream_messages" from worker response JSON.
/// For each message: broadcast as a "message" SSE event with step context.
fn processStreamMessages(hub: *sse_mod.SseHub, alloc: std.mem.Allocator, run_id: []const u8, step_id: []const u8, node_type: []const u8, response_json: []const u8) void {
    const parsed = json.parseFromSlice(json.Value, alloc, response_json, .{}) catch return;
    if (parsed.value != .object) return;
    const stream_msgs_val = parsed.value.object.get("stream_messages") orelse return;
    if (stream_msgs_val != .array) return;

    for (stream_msgs_val.array.items) |msg| {
        if (msg != .object) continue;

        // Build enriched message with step context
        var event_obj = json.ObjectMap.init(alloc);
        var it = msg.object.iterator();
        while (it.next()) |entry| {
            event_obj.put(entry.key_ptr.*, entry.value_ptr.*) catch continue;
        }
        event_obj.put("step_id", .{ .string = step_id }) catch {};
        event_obj.put("node_type", .{ .string = node_type }) catch {};
        const event_data = serializeJsonValue(alloc, .{ .object = event_obj }) catch continue;

        hub.broadcast(run_id, .{ .event_type = "message", .data = event_data, .mode = .custom });
    }
}

// ── Mermaid Graph Export ─────────────────────────────────────────────

/// Generate Mermaid diagram syntax from a workflow JSON definition.
/// Returns a Mermaid flowchart string.
pub fn generateMermaid(alloc: std.mem.Allocator, definition_json: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try json.parseFromSlice(json.Value, arena_alloc, definition_json, .{});
    if (parsed.value != .object) return try alloc.dupe(u8, "graph TD\n");

    const nodes_val = parsed.value.object.get("nodes") orelse return try alloc.dupe(u8, "graph TD\n");
    if (nodes_val != .object) return try alloc.dupe(u8, "graph TD\n");

    const edges_val = parsed.value.object.get("edges") orelse return try alloc.dupe(u8, "graph TD\n");
    if (edges_val != .array) return try alloc.dupe(u8, "graph TD\n");

    var buf: std.ArrayListUnmanaged(u8) = .empty;

    // Header
    try buf.appendSlice(arena_alloc, "graph TD\n");

    // __start__ and __end__ nodes
    try buf.appendSlice(arena_alloc, "    __start__((Start))\n");

    // Node definitions
    var nodes_it = nodes_val.object.iterator();
    while (nodes_it.next()) |entry| {
        const name = entry.key_ptr.*;
        const node = entry.value_ptr.*;

        const node_type_str = blk: {
            if (node == .object) {
                if (node.object.get("type")) |t| {
                    if (t == .string) break :blk t.string;
                }
            }
            break :blk "task";
        };

        // Choose Mermaid shape based on node type
        if (std.mem.eql(u8, node_type_str, "route")) {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "{");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\nroute}\n");
        } else if (std.mem.eql(u8, node_type_str, "interrupt")) {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "[/");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\ninterrupt/]\n");
        } else if (std.mem.eql(u8, node_type_str, "send")) {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "[[");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\nsend]]\n");
        } else if (std.mem.eql(u8, node_type_str, "transform")) {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "(");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\ntransform)\n");
        } else if (std.mem.eql(u8, node_type_str, "subgraph")) {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "[");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\nsubgraph]\n");
        } else {
            // task, agent, and others: rectangle
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "[");
            try buf.appendSlice(arena_alloc, name);
            try buf.appendSlice(arena_alloc, "\\n");
            try buf.appendSlice(arena_alloc, node_type_str);
            try buf.appendSlice(arena_alloc, "]\n");
        }
    }

    // __end__ node
    try buf.appendSlice(arena_alloc, "    __end__((End))\n");

    // Edges
    for (edges_val.array.items) |edge_item| {
        if (edge_item != .array) continue;
        if (edge_item.array.items.len < 2) continue;

        const source_raw = if (edge_item.array.items[0] == .string) edge_item.array.items[0].string else continue;
        const target = if (edge_item.array.items[1] == .string) edge_item.array.items[1].string else continue;

        // Parse conditional edge "source:value"
        if (std.mem.indexOfScalar(u8, source_raw, ':')) |colon_pos| {
            const source = source_raw[0..colon_pos];
            const condition = source_raw[colon_pos + 1 ..];
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, source);
            try buf.appendSlice(arena_alloc, " -->|");
            try buf.appendSlice(arena_alloc, condition);
            try buf.appendSlice(arena_alloc, "| ");
            try buf.appendSlice(arena_alloc, target);
            try buf.appendSlice(arena_alloc, "\n");
        } else {
            try buf.appendSlice(arena_alloc, "    ");
            try buf.appendSlice(arena_alloc, source_raw);
            try buf.appendSlice(arena_alloc, " --> ");
            try buf.appendSlice(arena_alloc, target);
            try buf.appendSlice(arena_alloc, "\n");
        }
    }

    return try alloc.dupe(u8, buf.items);
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
    try engine.tick();
}

test "engine: find ready nodes - simple chain" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Edges: __start__ -> a -> b -> __end__
    const wf =
        \\{"nodes":{"a":{"type":"task"},"b":{"type":"task"}},"edges":[["__start__","a"],["a","b"],["b","__end__"]],"schema":{}}
    ;

    // Completed: [] -> ready: [a]
    {
        var completed = std.StringHashMap(void).init(alloc);
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("a", ready[0]);
    }

    // Completed: [a] -> ready: [b]
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("a", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("b", ready[0]);
    }

    // Completed: [a, b] -> ready: [__end__]
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("a", {});
        try completed.put("b", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("__end__", ready[0]);
    }
}

test "engine: find ready nodes - parallel" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Edges: __start__ -> a, __start__ -> b, a -> c, b -> c
    const wf =
        \\{"nodes":{"a":{"type":"task"},"b":{"type":"task"},"c":{"type":"task"}},"edges":[["__start__","a"],["__start__","b"],["a","c"],["b","c"]],"schema":{}}
    ;

    // Completed: [] -> ready: [a, b]
    {
        var completed = std.StringHashMap(void).init(alloc);
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 2), ready.len);
        // Both a and b should be ready (order may vary)
        var has_a = false;
        var has_b = false;
        for (ready) |name| {
            if (std.mem.eql(u8, name, "a")) has_a = true;
            if (std.mem.eql(u8, name, "b")) has_b = true;
        }
        try std.testing.expect(has_a);
        try std.testing.expect(has_b);
    }

    // Completed: [a] -> ready: [] (c needs both a and b)
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("a", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        // b is already in completed? No. So b should be ready
        // Wait - b is from __start__ and __start__ is always completed
        // b should be ready since its only inbound is __start__
        // But if we only put "a" as completed, b's inbound __start__ is always satisfied
        // So b should be ready. And c should NOT be ready since b is not completed.
        var has_c = false;
        for (ready) |name| {
            if (std.mem.eql(u8, name, "c")) has_c = true;
        }
        try std.testing.expect(!has_c);
    }

    // Completed: [a, b] -> ready: [c]
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("a", {});
        try completed.put("b", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("c", ready[0]);
    }
}

test "engine: find ready nodes - route edges" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Edges: __start__ -> r, r:yes -> a, r:no -> b
    const wf =
        \\{"nodes":{"r":{"type":"route"},"a":{"type":"task"},"b":{"type":"task"}},"edges":[["__start__","r"],["r:yes","a"],["r:no","b"]],"schema":{}}
    ;

    // Completed: [r] with route result "yes" -> ready: [a]
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("r", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        try routes.put("r", "yes");
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("a", ready[0]);
    }

    // Completed: [r] with route result "no" -> ready: [b]
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("r", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        try routes.put("r", "no");
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("b", ready[0]);
    }

    // Completed: [r] with route result "yes" -> b should NOT be ready
    {
        var completed = std.StringHashMap(void).init(alloc);
        try completed.put("r", {});
        var routes = std.StringHashMap([]const u8).init(alloc);
        try routes.put("r", "yes");
        const ready = try findReadyNodes(alloc, wf, &completed, &routes);
        for (ready) |name| {
            try std.testing.expect(!std.mem.eql(u8, name, "b"));
        }
    }
}

test "engine: processRun completes simple workflow" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Create a workflow with just a transform node
    const wf =
        \\{"nodes":{"t1":{"type":"transform","updates":"{\"result\":\"done\"}"}},"edges":[["__start__","t1"],["t1","__end__"]],"schema":{"result":{"type":"string","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("completed", updated_run.status);

    // Verify state was updated
    if (updated_run.state_json) |sj| {
        try std.testing.expect(std.mem.indexOf(u8, sj, "done") != null);
    }
}

test "engine: interrupt node stops run" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"nodes":{"i1":{"type":"interrupt"}},"edges":[["__start__","i1"],["i1","__end__"]],"schema":{}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("interrupted", updated_run.status);
}

test "engine: route node with conditional edges" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow: start -> route -> (yes: t_yes, no: t_no) -> end
    const wf =
        \\{"nodes":{"r":{"type":"route","input":"state.decision"},"t_yes":{"type":"transform","updates":"{\"path\":\"yes\"}"},"t_no":{"type":"transform","updates":"{\"path\":\"no\"}"}},"edges":[["__start__","r"],["r:yes","t_yes"],["r:no","t_no"],["t_yes","__end__"],["t_no","__end__"]],"schema":{"decision":{"type":"string","reducer":"last_value"},"path":{"type":"string","reducer":"last_value"}}}
    ;

    const init_state =
        \\{"decision":"yes"}
    ;

    try store.createRunWithState("r1", null, wf, "{}", init_state);
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // First tick: route node executes and completes
    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // May need a second tick to process t_yes and __end__
    const run_row2 = (try store.getRun(arena.allocator(), "r1")).?;
    if (std.mem.eql(u8, run_row2.status, "running")) {
        try engine.processRun(arena.allocator(), run_row2);
    }

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("completed", updated_run.status);

    // Verify the "yes" path was taken
    if (updated_run.state_json) |sj| {
        try std.testing.expect(std.mem.indexOf(u8, sj, "yes") != null);
    }
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

test "serializeCompletedNodes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var completed = std.StringHashMap(void).init(alloc);
    try completed.put("a", {});
    try completed.put("b", {});

    const result = try serializeCompletedNodes(alloc, &completed);
    // Should be a JSON array containing "a" and "b"
    try std.testing.expect(std.mem.indexOf(u8, result, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"b\"") != null);
}

test "getNodeJson returns node definition" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"nodes":{"a":{"type":"task","prompt_template":"hello"}},"edges":[]}
    ;
    const result = getNodeJson(arena.allocator(), wf, "a");
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "task") != null);
}

test "getNodeJson returns null for missing node" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"nodes":{"a":{"type":"task"}},"edges":[]}
    ;
    const result = getNodeJson(arena.allocator(), wf, "b");
    try std.testing.expect(result == null);
}

test "getNodeField extracts string field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"task","prompt_template":"hello {{state.name}}"}
    ;
    const result = getNodeField(arena.allocator(), node, "prompt_template");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello {{state.name}}", result.?);
}

test "extractStateUpdates from worker response" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"state_updates":{"result":"done","count":5},"other":"ignored"}
    ;
    const result = extractStateUpdates(arena.allocator(), output);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "done") != null);
}

test "extractStateUpdates returns null for plain text" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = extractStateUpdates(arena.allocator(), "just plain text");
    try std.testing.expect(result == null);
}

test "buildTaskStateUpdates uses output_key for plain text output" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"task","output_key":"plan"}
    ;
    const result = try buildTaskStateUpdates(arena.allocator(), node, "draft plan");
    try std.testing.expectEqualStrings("{\"plan\":\"draft plan\"}", result);
}

test "buildTaskStateUpdates applies output_mapping from JSON output" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"task","output_key":"review_result","output_mapping":{"grade":"grade","feedback":"details.feedback"}}
    ;
    const output =
        \\{"grade":"approve","details":{"feedback":"looks good"}}
    ;
    const result = try buildTaskStateUpdates(arena.allocator(), node, output);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"review_result\":{\"grade\":\"approve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"grade\":\"approve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"feedback\":\"looks good\"") != null);
}

test "getSendItemsPath prefers canonical items_key" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"send","items_key":"state.files","items_from":"state.legacy"}
    ;
    const result = getSendItemsPath(arena.allocator(), node);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("state.files", result.?);
}

test "getSendItemsPath accepts legacy items_from alias" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"send","items_from":"state.files"}
    ;
    const result = getSendItemsPath(arena.allocator(), node);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("state.files", result.?);
}

test "extractGotoTargets: string target" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"state_updates":{"x":1},"goto":"merge_step"}
    ;
    const targets = extractGotoTargets(arena.allocator(), output);
    try std.testing.expect(targets != null);
    try std.testing.expectEqual(@as(usize, 1), targets.?.len);
    try std.testing.expectEqualStrings("merge_step", targets.?[0]);
}

test "extractGotoTargets: array targets" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const output =
        \\{"goto":["step_a","step_b"]}
    ;
    const targets = extractGotoTargets(arena.allocator(), output);
    try std.testing.expect(targets != null);
    try std.testing.expectEqual(@as(usize, 2), targets.?.len);
    try std.testing.expectEqualStrings("step_a", targets.?[0]);
    try std.testing.expectEqualStrings("step_b", targets.?[1]);
}

test "extractGotoTargets: no goto field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = extractGotoTargets(arena.allocator(), "{\"state_updates\":{}}");
    try std.testing.expect(targets == null);
}

test "extractGotoTargets: not JSON" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const targets = extractGotoTargets(arena.allocator(), "plain text");
    try std.testing.expect(targets == null);
}

test "parseBreakpointList: valid list" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"interrupt_before":["review","merge"],"interrupt_after":["generate"],"nodes":{},"edges":[]}
    ;
    const before = parseBreakpointList(arena.allocator(), wf, "interrupt_before");
    try std.testing.expectEqual(@as(usize, 2), before.len);
    try std.testing.expectEqualStrings("review", before[0]);
    try std.testing.expectEqualStrings("merge", before[1]);

    const after = parseBreakpointList(arena.allocator(), wf, "interrupt_after");
    try std.testing.expectEqual(@as(usize, 1), after.len);
    try std.testing.expectEqualStrings("generate", after[0]);
}

test "parseBreakpointList: missing field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const wf =
        \\{"nodes":{},"edges":[]}
    ;
    const result = parseBreakpointList(arena.allocator(), wf, "interrupt_before");
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "isInBreakpointList" {
    const list = [_][]const u8{ "review", "merge" };
    try std.testing.expect(isInBreakpointList("review", &list));
    try std.testing.expect(isInBreakpointList("merge", &list));
    try std.testing.expect(!isInBreakpointList("build", &list));
}

test "getNodeFieldInt: valid integer" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"agent","max_turns":10}
    ;
    const result = getNodeFieldInt(arena.allocator(), node, "max_turns");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(i64, 10), result.?);
}

test "getNodeFieldInt: missing field" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"task"}
    ;
    const result = getNodeFieldInt(arena.allocator(), node, "max_turns");
    try std.testing.expect(result == null);
}

test "getNodeFieldInt: string field returns null" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const node =
        \\{"type":"task","max_turns":"five"}
    ;
    const result = getNodeFieldInt(arena.allocator(), node, "max_turns");
    try std.testing.expect(result == null);
}

test "buildSubgraphInput: maps values from parent state" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parent_state =
        \\{"fix_result":"patched code","count":42}
    ;
    const mapping =
        \\{"code":"state.fix_result"}
    ;

    const result = try buildSubgraphInput(alloc, parent_state, mapping);
    const parsed = try json.parseFromSlice(json.Value, alloc, result, .{});
    try std.testing.expect(parsed.value == .object);
    const code = parsed.value.object.get("code") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("patched code", code.string);
}

test "buildSubgraphInput: empty mapping" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const result = try buildSubgraphInput(arena.allocator(), "{\"x\":1}", "{}");
    try std.testing.expectEqualStrings("{}", result);
}

test "engine: breakpoint interrupt_before stops run" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow with interrupt_before on t1
    const wf =
        \\{"interrupt_before":["t1"],"nodes":{"t1":{"type":"transform","updates":"{\"result\":\"done\"}"}},"edges":[["__start__","t1"],["t1","__end__"]],"schema":{"result":{"type":"string","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    // Should be interrupted, not completed, because interrupt_before fires before t1
    try std.testing.expectEqualStrings("interrupted", updated_run.status);
}

test "engine: breakpoint interrupt_after stops run after node" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow with interrupt_after on t1; there's a t2 after t1
    const wf =
        \\{"interrupt_after":["t1"],"nodes":{"t1":{"type":"transform","updates":"{\"x\":\"done\"}"},"t2":{"type":"transform","updates":"{\"y\":\"also\"}"}},"edges":[["__start__","t1"],["t1","t2"],["t2","__end__"]],"schema":{"x":{"type":"string","reducer":"last_value"},"y":{"type":"string","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    // t1 should have executed (state contains x), but run is interrupted
    try std.testing.expectEqualStrings("interrupted", updated_run.status);
    // Verify t1's state was saved
    if (updated_run.state_json) |sj| {
        try std.testing.expect(std.mem.indexOf(u8, sj, "done") != null);
    }
}

test "engine: configurable runs inject __config" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    // Workflow with a transform that sets result
    const wf =
        \\{"nodes":{"t1":{"type":"transform","updates":"{\"result\":\"ok\"}"}},"edges":[["__start__","t1"],["t1","__end__"]],"schema":{"result":{"type":"string","reducer":"last_value"},"__config":{"type":"object","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.setConfigJson("r1", "{\"model\":\"gpt-4\"}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("completed", updated_run.status);
    // Verify __config was injected into state
    if (updated_run.state_json) |sj| {
        try std.testing.expect(std.mem.indexOf(u8, sj, "__config") != null);
        try std.testing.expect(std.mem.indexOf(u8, sj, "gpt-4") != null);
    }
}

test "engine: transform store_updates uses trusted tracker settings" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    test_store_write_base_url = "";
    test_store_write_api_token = null;
    test_store_write_namespace = "";
    test_store_write_key = "";
    test_store_write_value_json = "";

    const wf =
        \\{"nodes":{"save":{"type":"transform","updates":"{\"review_result\":{\"grade\":\"approved\"}}","store_updates":{"namespace":"project_context","key":"latest_review","value":"state.review_result"}}},"edges":[["__start__","save"],["save","__end__"]],"schema":{"review_result":{"type":"object","reducer":"last_value"},"__config":{"type":"object","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);
    engine.store_writer = mockStoreWriter;
    engine.setTrustedTrackerAccess("http://tickets.test", "secret-token");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    const updated_run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("completed", updated_run.status);
    try std.testing.expectEqualStrings("http://tickets.test", test_store_write_base_url);
    try std.testing.expect(test_store_write_api_token != null);
    try std.testing.expectEqualStrings("secret-token", test_store_write_api_token.?);
    try std.testing.expectEqualStrings("project_context", test_store_write_namespace);
    try std.testing.expectEqualStrings("latest_review", test_store_write_key);
    try std.testing.expectEqualStrings("{\"grade\":\"approved\"}", test_store_write_value_json);
}

test "engine: workflow cannot override trusted tracker settings" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    test_store_write_base_url = "";
    test_store_write_api_token = null;
    test_store_write_namespace = "";
    test_store_write_key = "";
    test_store_write_value_json = "";

    const wf =
        \\{"tracker_url":"http://evil.test","tracker_api_token":"evil-token","nodes":{"save":{"type":"transform","updates":"{\"review_result\":{\"grade\":\"approved\"}}","store_updates":{"namespace":"project_context","key":"latest_review","value":"state.review_result"}}},"edges":[["__start__","save"],["save","__end__"]],"schema":{"review_result":{"type":"object","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);
    engine.store_writer = mockStoreWriter;
    engine.setTrustedTrackerAccess("http://tickets.test", "secret-token");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    try std.testing.expectEqualStrings("http://tickets.test", test_store_write_base_url);
    try std.testing.expect(test_store_write_api_token != null);
    try std.testing.expectEqualStrings("secret-token", test_store_write_api_token.?);
}

test "encodePathSegment percent-encodes reserved characters" {
    const encoded = try encodePathSegment(std.testing.allocator, "task/alpha beta");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("task%2Falpha%20beta", encoded);
}

test "getWorkflowVersion: extracts version" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(i64, 2), getWorkflowVersion(arena.allocator(), "{\"version\":2,\"nodes\":{}}"));
    try std.testing.expectEqual(@as(i64, 1), getWorkflowVersion(arena.allocator(), "{\"nodes\":{}}"));
    try std.testing.expectEqual(@as(i64, 1), getWorkflowVersion(arena.allocator(), "invalid"));
}

test "getCheckpointWorkflowVersion: extracts from metadata" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try std.testing.expectEqual(@as(i64, 3), getCheckpointWorkflowVersion(arena.allocator(), "{\"workflow_version\":3}"));
    try std.testing.expectEqual(@as(i64, 1), getCheckpointWorkflowVersion(arena.allocator(), "{\"route_results\":{}}"));
    try std.testing.expectEqual(@as(i64, 1), getCheckpointWorkflowVersion(arena.allocator(), null));
}

test "migrateCompletedNodes: filters removed nodes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var completed = std.StringHashMap(void).init(alloc);
    try completed.put("analyze", {});
    try completed.put("old_node", {});
    try completed.put("__start__", {});

    const wf =
        \\{"nodes":{"analyze":{"type":"task"},"new_node":{"type":"task"}},"edges":[]}
    ;

    const migrated = migrateCompletedNodes(alloc, &completed, wf);
    try std.testing.expect(migrated);
    try std.testing.expect(completed.get("analyze") != null);
    try std.testing.expect(completed.get("__start__") != null);
    try std.testing.expect(completed.get("old_node") == null);
}

test "migrateCompletedNodes: no changes needed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var completed = std.StringHashMap(void).init(alloc);
    try completed.put("analyze", {});

    const wf =
        \\{"nodes":{"analyze":{"type":"task"}},"edges":[]}
    ;

    const migrated = migrateCompletedNodes(alloc, &completed, wf);
    try std.testing.expect(!migrated);
}

test "serializeRouteResultsWithVersion: includes version" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var route_results = std.StringHashMap([]const u8).init(alloc);

    const result = try serializeRouteResultsWithVersion(alloc, &route_results, 5);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "workflow_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "5") != null);
}

test "serializeRouteResultsWithVersion: null version, empty routes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    var route_results = std.StringHashMap([]const u8).init(alloc);

    const result = try serializeRouteResultsWithVersion(alloc, &route_results, null);
    try std.testing.expect(result == null);
}

test "engine: workflow version stored in checkpoint metadata" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    const wf =
        \\{"version":2,"nodes":{"t1":{"type":"transform","updates":"{\"result\":\"done\"}"}},"edges":[["__start__","t1"],["t1","__end__"]],"schema":{"result":{"type":"string","reducer":"last_value"}}}
    ;

    try store.createRunWithState("r1", null, wf, "{}", "{}");
    try store.updateRunStatus("r1", "running", null);

    var engine = Engine.init(&store, allocator, 500);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const run_row = (try store.getRun(arena.allocator(), "r1")).?;
    try engine.processRun(arena.allocator(), run_row);

    // Check that checkpoint has workflow_version in metadata
    const latest_cp = (try store.getLatestCheckpoint(arena.allocator(), "r1")).?;
    try std.testing.expect(latest_cp.metadata_json != null);
    try std.testing.expect(std.mem.indexOf(u8, latest_cp.metadata_json.?, "workflow_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, latest_cp.metadata_json.?, "2") != null);
}

test "OrchestratorEvent: eventKindString returns correct strings" {
    try std.testing.expectEqualStrings("run.started", OrchestratorEvent.eventKindString(.run_started));
    try std.testing.expectEqualStrings("run.completed", OrchestratorEvent.eventKindString(.run_completed));
    try std.testing.expectEqualStrings("run.failed", OrchestratorEvent.eventKindString(.run_failed));
    try std.testing.expectEqualStrings("run.interrupted", OrchestratorEvent.eventKindString(.run_interrupted));
    try std.testing.expectEqualStrings("run.cancelled", OrchestratorEvent.eventKindString(.run_cancelled));
    try std.testing.expectEqualStrings("step.started", OrchestratorEvent.eventKindString(.step_started));
    try std.testing.expectEqualStrings("step.completed", OrchestratorEvent.eventKindString(.step_completed));
    try std.testing.expectEqualStrings("step.failed", OrchestratorEvent.eventKindString(.step_failed));
    try std.testing.expectEqualStrings("step.retrying", OrchestratorEvent.eventKindString(.step_retrying));
    try std.testing.expectEqualStrings("checkpoint.created", OrchestratorEvent.eventKindString(.checkpoint_created));
    try std.testing.expectEqualStrings("state.injected", OrchestratorEvent.eventKindString(.state_injected));
}

test "OrchestratorEvent: toJson serializes correctly" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ev = OrchestratorEvent{
        .event_type = .run_started,
        .run_id = "run-123",
        .step_id = null,
        .node_name = "analyze",
        .timestamp_ms = 1700000000000,
        .metadata_json = null,
    };

    const json_str = ev.toJson(arena.allocator());
    try std.testing.expect(json_str != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str.?, "run.started") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str.?, "run-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str.?, "analyze") != null);
}

test "engine: validateConfig returns false with no workers" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var engine = Engine.init(&store, allocator, 500);
    try std.testing.expect(!engine.validateConfig());
}

test "engine: validateConfig returns true with registered workers" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertWorker("w1", "http://localhost:9000", "", "webhook", null, "[]", 5, "config");
    var engine = Engine.init(&store, allocator, 500);
    try std.testing.expect(engine.validateConfig());
}

test "generateMermaid: simple chain" {
    const allocator = std.testing.allocator;
    const wf =
        \\{"nodes":{"analyze":{"type":"task"},"review":{"type":"task"}},"edges":[["__start__","analyze"],["analyze","review"],["review","__end__"]]}
    ;
    const result = try generateMermaid(allocator, wf);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "graph TD") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "__start__((Start))") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "__end__((End))") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "analyze[analyze") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "__start__ --> analyze") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "review --> __end__") != null);
}

test "generateMermaid: route node with conditional edges" {
    const allocator = std.testing.allocator;
    const wf =
        \\{"nodes":{"decide":{"type":"route"},"approve":{"type":"task"},"reject":{"type":"task"}},"edges":[["__start__","decide"],["decide:yes","approve"],["decide:no","reject"],["approve","__end__"],["reject","__end__"]]}
    ;
    const result = try generateMermaid(allocator, wf);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "decide{decide") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "decide -->|yes| approve") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "decide -->|no| reject") != null);
}

test "generateMermaid: node type shapes" {
    const allocator = std.testing.allocator;
    const wf =
        \\{"nodes":{"t":{"type":"transform"},"i":{"type":"interrupt"},"s":{"type":"send"},"sg":{"type":"subgraph"}},"edges":[["__start__","t"],["t","__end__"]]}
    ;
    const result = try generateMermaid(allocator, wf);
    defer allocator.free(result);

    // transform uses rounded parens
    try std.testing.expect(std.mem.indexOf(u8, result, "t(t\\ntransform)") != null);
    // interrupt uses parallelogram
    try std.testing.expect(std.mem.indexOf(u8, result, "i[/i\\ninterrupt/]") != null);
    // send uses double brackets
    try std.testing.expect(std.mem.indexOf(u8, result, "s[[s\\nsend]]") != null);
    // subgraph uses rectangle
    try std.testing.expect(std.mem.indexOf(u8, result, "sg[sg\\nsubgraph]") != null);
}

test "processUiMessages: broadcasts events" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var hub = sse_mod.SseHub.init(alloc);
    defer hub.deinit();

    const queue = hub.getOrCreateQueue("run1");

    const response =
        \\{"response":"ok","ui_messages":[{"id":"p1","name":"ProgressBar","props":{"progress":75}},{"id":"old","remove":true}]}
    ;
    processUiMessages(&hub, alloc, "run1", "step1", response);

    const events = queue.drain(alloc);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("ui_message", events[0].event_type);
    try std.testing.expectEqualStrings("ui_message_delete", events[1].event_type);
    // First event should contain step_id
    try std.testing.expect(std.mem.indexOf(u8, events[0].data, "step1") != null);
}

test "processStreamMessages: broadcasts message events" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var hub = sse_mod.SseHub.init(alloc);
    defer hub.deinit();

    const queue = hub.getOrCreateQueue("run1");

    const response =
        \\{"response":"done","stream_messages":[{"role":"assistant","content":"Starting..."},{"role":"tool","content":"Found 3 issues","tool":"lint"}]}
    ;
    processStreamMessages(&hub, alloc, "run1", "step1", "task", response);

    const events = queue.drain(alloc);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("message", events[0].event_type);
    try std.testing.expectEqualStrings("message", events[1].event_type);
    // Should contain step context
    try std.testing.expect(std.mem.indexOf(u8, events[0].data, "step1") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[0].data, "task") != null);
    try std.testing.expect(std.mem.indexOf(u8, events[1].data, "tool") != null);
}

test "applyUiMessagesToState: creates __ui_messages" {
    const allocator = std.testing.allocator;
    const state = "{}";
    const response =
        \\{"response":"ok","ui_messages":[{"id":"p1","name":"ProgressBar"}]}
    ;
    const result = try applyUiMessagesToState(allocator, state, response);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "__ui_messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ProgressBar") != null);
}
