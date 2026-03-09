/// Tracker Thread — pull-mode agent that polls NullTickets, claims tasks,
/// manages subprocess lifecycles, and heartbeats leases.
///
/// Each tick:
///   1. Heartbeat all active leases
///   2. Detect stalled subprocesses
///   3. Drive running task state machines
///   4. Reconcile running tasks with NullTickets state
///   5. Poll NullTickets and claim new tasks (respecting concurrency limits)
///   6. Clean expired cooldowns
const std = @import("std");
const log = std.log.scoped(.tracker);

const config = @import("config.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
const subprocess_mod = @import("subprocess.zig");
const workspace_mod = @import("workspace.zig");
const workflow_loader = @import("workflow_loader.zig");
const tracker_client = @import("tracker_client.zig");
const templates = @import("templates.zig");

// ── RunningTask ─────────────────────────────────────────────────────

pub const RunningTask = struct {
    task_id: []const u8,
    task_title: []const u8,
    task_identifier: []const u8,
    task_json: []const u8,
    pipeline_id: []const u8,
    agent_role: []const u8,
    lease_id: []const u8,
    lease_token: []const u8,
    run_id: []const u8,
    workspace_path: []const u8,
    execution_mode: []const u8,
    subprocess: ?subprocess_mod.SubprocessInfo,
    started_at_ms: i64,
    last_activity_ms: i64,
    task_version: i64,
    current_turn: u32,
    max_turns: u32,
    state: types.TrackerTaskState,
    health_retries: u32 = 0,
};

// ── TrackerState ────────────────────────────────────────────────────

pub const TrackerState = struct {
    mutex: std.Thread.Mutex,
    running: std.StringArrayHashMapUnmanaged(RunningTask),
    completed_count: u64,
    failed_count: u64,
    cooldowns: std.StringArrayHashMapUnmanaged(i64),

    pub fn init() TrackerState {
        return .{
            .mutex = .{},
            .running = .{},
            .completed_count = 0,
            .failed_count = 0,
            .cooldowns = .{},
        };
    }

    pub fn deinit(self: *TrackerState, allocator: std.mem.Allocator) void {
        // Free all duped keys and owned strings in running map
        for (self.running.keys(), self.running.values()) |key, task| {
            allocator.free(task.task_id);
            allocator.free(task.task_title);
            allocator.free(task.task_identifier);
            allocator.free(task.task_json);
            allocator.free(task.pipeline_id);
            allocator.free(task.lease_id);
            allocator.free(task.lease_token);
            allocator.free(task.run_id);
            allocator.free(task.workspace_path);
            allocator.free(key);
        }
        self.running.deinit(allocator);

        // Free all duped keys in cooldowns map
        for (self.cooldowns.keys()) |key| {
            allocator.free(key);
        }
        self.cooldowns.deinit(allocator);
    }

    pub fn runningCount(self: *const TrackerState) u32 {
        return @intCast(self.running.count());
    }

    pub fn countByPipeline(self: *const TrackerState, pipeline_id: []const u8) u32 {
        var count: u32 = 0;
        for (self.running.values()) |task| {
            if (std.mem.eql(u8, task.pipeline_id, pipeline_id)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn countByRole(self: *const TrackerState, role: []const u8) u32 {
        var count: u32 = 0;
        for (self.running.values()) |task| {
            if (std.mem.eql(u8, task.agent_role, role)) {
                count += 1;
            }
        }
        return count;
    }

    pub fn isInCooldown(self: *const TrackerState, task_id: []const u8) bool {
        const until = self.cooldowns.get(task_id) orelse return false;
        return ids.nowMs() < until;
    }
};

// ── canClaimMore ────────────────────────────────────────────────────

pub fn canClaimMore(
    state: *const TrackerState,
    concurrency: config.ConcurrencyConfig,
    pipeline_id: []const u8,
    role: []const u8,
) bool {
    // Check global limit
    if (state.runningCount() >= concurrency.max_concurrent_tasks) {
        return false;
    }

    // Check per_pipeline limit
    if (concurrency.per_pipeline) |pp| {
        if (pp == .object) {
            if (pp.object.get(pipeline_id)) |limit_val| {
                if (limit_val == .integer) {
                    const limit: u32 = @intCast(limit_val.integer);
                    if (state.countByPipeline(pipeline_id) >= limit) {
                        return false;
                    }
                }
            }
        }
    }

    // Check per_role limit
    if (concurrency.per_role) |pr| {
        if (pr == .object) {
            if (pr.object.get(role)) |limit_val| {
                if (limit_val == .integer) {
                    const limit: u32 = @intCast(limit_val.integer);
                    if (state.countByRole(role) >= limit) {
                        return false;
                    }
                }
            }
        }
    }

    return true;
}

// ── Tracker ─────────────────────────────────────────────────────────

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    cfg: config.TrackerConfig,
    state: TrackerState,
    workflows: workflow_loader.WorkflowMap,
    shutdown: *std.atomic.Value(bool),
    last_heartbeat_ms: i64,
    used_ports: std.AutoArrayHashMapUnmanaged(u16, void),

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: config.TrackerConfig,
        workflows: workflow_loader.WorkflowMap,
        shutdown: *std.atomic.Value(bool),
    ) Tracker {
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .state = TrackerState.init(),
            .workflows = workflows,
            .shutdown = shutdown,
            .last_heartbeat_ms = 0,
            .used_ports = .{},
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.shutdownSubprocesses();
        self.used_ports.deinit(self.allocator);
        self.state.deinit(self.allocator);
    }

    /// Free owned string fields of a RunningTask (duped in startTask).
    /// Does NOT free agent_role (cfg_arena) or execution_mode (string literal).
    fn freeRunningTaskStrings(self: *Tracker, task: RunningTask) void {
        self.allocator.free(task.task_id);
        self.allocator.free(task.task_title);
        self.allocator.free(task.task_identifier);
        self.allocator.free(task.task_json);
        self.allocator.free(task.pipeline_id);
        self.allocator.free(task.lease_id);
        self.allocator.free(task.lease_token);
        self.allocator.free(task.run_id);
        self.allocator.free(task.workspace_path);
    }

    /// Allocate a free port starting from base_port. Returns null if no port found within 1000 range.
    pub fn allocatePort(self: *Tracker) ?u16 {
        const base = self.cfg.subprocess.base_port;
        var port: u16 = base;
        while (port < base +| 1000) : (port += 1) {
            if (!self.used_ports.contains(port)) {
                self.used_ports.put(self.allocator, port, {}) catch return null;
                return port;
            }
        }
        return null;
    }

    /// Release a previously allocated port.
    pub fn releasePort(self: *Tracker, port: u16) void {
        _ = self.used_ports.swapRemove(port);
    }

    /// Thread entry point — run the poll loop until shutdown is requested.
    pub fn run(self: *Tracker) void {
        log.info("tracker started (poll_interval={d}ms, agent_id={s})", .{
            self.cfg.poll_interval_ms,
            self.cfg.agent_id,
        });

        const poll_ns: u64 = @as(u64, self.cfg.poll_interval_ms) * std.time.ns_per_ms;

        while (!self.shutdown.load(.acquire)) {
            self.tick() catch |err| {
                log.err("tracker tick error: {}", .{err});
            };
            std.Thread.sleep(poll_ns);
        }

        log.info("tracker shutting down, killing subprocesses", .{});
        self.shutdownSubprocesses();
        log.info("tracker stopped (completed={d}, failed={d})", .{
            self.state.completed_count,
            self.state.failed_count,
        });
    }

    /// Single tick of the tracker loop.
    fn tick(self: *Tracker) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const tick_alloc = arena.allocator();

        self.heartbeatAll(tick_alloc);
        self.detectStalls(tick_alloc);
        self.driveRunningTasks(tick_alloc);
        self.reconcile(tick_alloc);
        self.pollAndClaim(tick_alloc);
        self.cleanCooldowns();
    }

    /// Heartbeat all active leases. If a heartbeat fails, kill the subprocess
    /// and remove the task from running state.
    fn heartbeatAll(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        const now = ids.nowMs();

        // Only heartbeat at the configured interval
        if (now - self.last_heartbeat_ms < @as(i64, @intCast(self.cfg.heartbeat_interval_ms))) {
            return;
        }
        self.last_heartbeat_ms = now;

        // Collect keys of tasks whose heartbeat fails
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, *task| {
            var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
            const new_expiry = client.heartbeat(task.lease_id, task.lease_token) catch null;
            if (new_expiry == null) {
                log.warn("heartbeat failed for task {s} (lease {s}), removing", .{ key, task.lease_id });
                // Kill subprocess if present
                if (task.subprocess) |*sub| {
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                }
                to_remove.append(tick_alloc, key) catch continue;
            }
        }

        // Remove failed heartbeat tasks and free owned strings
        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
    }

    /// Detect stalled subprocesses. If stalled, report failure to NullTickets,
    /// kill the subprocess, remove from running, and increment failed_count.
    fn detectStalls(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, *task| {
            if (task.subprocess) |*sub| {
                if (subprocess_mod.isStalled(sub, @as(i64, @intCast(self.cfg.stall_timeout_ms)))) {
                    log.warn("task {s} stalled (no activity for {d}ms), failing", .{
                        key,
                        self.cfg.stall_timeout_ms,
                    });

                    // Report failure to NullTickets
                    var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
                    _ = client.failRun(task.run_id, "subprocess stalled", task.lease_token, null) catch {};

                    // Kill subprocess
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }

                    self.state.mutex.lock();
                    self.state.failed_count += 1;
                    self.state.mutex.unlock();
                    to_remove.append(tick_alloc, key) catch continue;
                }
            }
        }

        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
    }

    /// Poll NullTickets for each workflow's claim_roles and claim available tasks.
    fn pollAndClaim(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        const base_url = self.cfg.url orelse return;

        for (self.workflows.values()) |workflow| {
            for (workflow.claim_roles) |role| {
                if (!canClaimMore(&self.state, self.cfg.concurrency, workflow.pipeline_id, role)) {
                    continue;
                }

                var client = tracker_client.TrackerClient.init(tick_alloc, base_url, self.cfg.api_token);
                const claim_result = client.claim(
                    self.cfg.agent_id,
                    role,
                    @as(i64, @intCast(self.cfg.lease_ttl_ms)),
                ) catch |err| {
                    log.warn("claim failed for role {s}: {}", .{ role, err });
                    continue;
                };

                const claim = claim_result orelse continue;

                // Skip if in cooldown
                if (self.state.isInCooldown(claim.task.id)) {
                    log.debug("task {s} in cooldown, skipping", .{claim.task.id});
                    continue;
                }

                // Skip if already running
                if (self.state.running.contains(claim.task.id)) {
                    log.debug("task {s} already running, skipping", .{claim.task.id});
                    continue;
                }

                self.startTask(claim, &workflow, role) catch |err| {
                    log.warn("failed to start task {s}: {}", .{ claim.task.id, err });
                };
            }
        }
    }

    /// Set up workspace and create a RunningTask entry for a claimed task.
    /// Claim fields are duped with self.allocator since the tick arena is freed after tick().
    fn startTask(
        self: *Tracker,
        claim: tracker_client.ClaimResponse,
        workflow: *const workflow_loader.WorkflowDef,
        role: []const u8,
    ) !void {
        const now = ids.nowMs();

        // Create workspace
        const ws = workspace_mod.Workspace.create(
            self.allocator,
            self.cfg.workspace.root,
            claim.task.id,
        ) catch |err| {
            log.warn("workspace creation failed for task {s}: {}", .{ claim.task.id, err });
            return err;
        };
        errdefer self.allocator.free(ws.path);

        // Run after_create hook if workspace was freshly created
        if (ws.created) {
            if (self.cfg.workspace.hooks.after_create) |hook| {
                const ok = workspace_mod.runHook(
                    self.allocator,
                    hook,
                    ws.path,
                    @as(u64, self.cfg.workspace.hook_timeout_ms),
                ) catch false;
                if (!ok) {
                    log.warn("after_create hook failed for task {s}", .{claim.task.id});
                }
            }
        }

        // Run before_run hook
        if (self.cfg.workspace.hooks.before_run) |hook| {
            const ok = workspace_mod.runHook(
                self.allocator,
                hook,
                ws.path,
                @as(u64, self.cfg.workspace.hook_timeout_ms),
            ) catch false;
            if (!ok) {
                log.warn("before_run hook failed for task {s}", .{claim.task.id});
            }
        }

        const execution_mode_str: []const u8 = switch (workflow.execution) {
            .subprocess => "subprocess",
            .dispatch => "dispatch",
        };

        // Dupe claim fields with long-lived allocator (tick arena freed after tick())
        const owned_task_id = try self.allocator.dupe(u8, claim.task.id);
        errdefer self.allocator.free(owned_task_id);
        const owned_title = try self.allocator.dupe(u8, claim.task.title);
        errdefer self.allocator.free(owned_title);
        const owned_identifier = try self.allocator.dupe(u8, claim.task.stage);
        errdefer self.allocator.free(owned_identifier);
        const owned_task_json = try self.allocator.dupe(u8, claim.task.task_json);
        errdefer self.allocator.free(owned_task_json);
        const owned_pipeline = try self.allocator.dupe(u8, claim.task.pipeline_id);
        errdefer self.allocator.free(owned_pipeline);
        const owned_lease_id = try self.allocator.dupe(u8, claim.lease_id);
        errdefer self.allocator.free(owned_lease_id);
        const owned_lease_token = try self.allocator.dupe(u8, claim.lease_token);
        errdefer self.allocator.free(owned_lease_token);
        const owned_run_id = try self.allocator.dupe(u8, claim.run.id);
        errdefer self.allocator.free(owned_run_id);

        // Dupe the task_id for use as the map key
        const key = try self.allocator.dupe(u8, claim.task.id);
        errdefer self.allocator.free(key);

        const running_task = RunningTask{
            .task_id = owned_task_id,
            .task_title = owned_title,
            .task_identifier = owned_identifier,
            .task_json = owned_task_json,
            .pipeline_id = owned_pipeline,
            .agent_role = role, // from workflow, lives in cfg_arena
            .lease_id = owned_lease_id,
            .lease_token = owned_lease_token,
            .run_id = owned_run_id,
            .workspace_path = ws.path, // allocated with self.allocator via Workspace.create
            .execution_mode = execution_mode_str, // string literal
            .subprocess = null,
            .started_at_ms = now,
            .last_activity_ms = now,
            .task_version = claim.task.task_version,
            .current_turn = 0,
            .max_turns = workflow.subprocess.max_turns,
            .state = .workspace_setup,
        };

        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        try self.state.running.put(self.allocator, key, running_task);

        log.info("started task {s} (pipeline={s}, role={s}, mode={s})", .{
            owned_task_id,
            owned_pipeline,
            role,
            execution_mode_str,
        });
    }

    /// Remove expired cooldown entries.
    fn cleanCooldowns(self: *Tracker) void {
        const now = ids.nowMs();

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        for (self.state.cooldowns.keys(), self.state.cooldowns.values()) |key, until| {
            if (now >= until) {
                to_remove.append(self.allocator, key) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.state.cooldowns.fetchSwapRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    /// Drive each running task through its state machine.
    fn driveRunningTasks(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        // Collect task IDs under lock to avoid race with API reader thread
        var task_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer task_ids.deinit(tick_alloc);

        self.state.mutex.lock();
        for (self.state.running.keys()) |key| {
            task_ids.append(tick_alloc, key) catch continue;
        }
        self.state.mutex.unlock();

        for (task_ids.items) |task_id| {
            const task = self.state.running.getPtr(task_id) orelse continue;
            switch (task.state) {
                .workspace_setup => self.driveSpawning(tick_alloc, task),
                .spawning => self.driveHealthCheck(tick_alloc, task),
                .running => self.driveRunning(tick_alloc, task),
                .completing => self.driveCompleting(tick_alloc, task),
                .completed => self.driveCompleted(tick_alloc, task),
                .failed => self.driveFailed(tick_alloc, task),
                else => {},
            }
        }

        // Remove tasks marked for removal (state == removing)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            if (task.state == .removing) {
                to_remove.append(tick_alloc, key) catch continue;
            }
        }

        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
    }

    /// Reconcile running tasks with NullTickets state.
    /// If task was deleted, reassigned, or pipeline changed, kill and clean up.
    fn reconcile(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        const base_url = self.cfg.url orelse return;

        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, *task| {
            // Only reconcile tasks that are actively running
            if (task.state != .running and task.state != .workspace_setup and task.state != .spawning) continue;

            var client = tracker_client.TrackerClient.init(tick_alloc, base_url, self.cfg.api_token);
            const task_info = client.getTask(task.task_id) catch continue;
            if (task_info == null) {
                log.warn("task {s} not found in NullTickets, removing", .{task.task_id});
                if (task.subprocess) |*sub| {
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                    self.releasePort(sub.port);
                }
                self.state.mutex.lock();
                self.state.failed_count += 1;
                self.state.mutex.unlock();
                to_remove.append(tick_alloc, key) catch continue;
                continue;
            }

            const info = task_info.?;
            defer {
                tick_alloc.free(info.id);
                tick_alloc.free(info.title);
                tick_alloc.free(info.description);
                tick_alloc.free(info.stage);
                tick_alloc.free(info.pipeline_id);
                tick_alloc.free(info.metadata_json);
                tick_alloc.free(info.task_json);
            }

            // If pipeline changed, task was reassigned
            if (!std.mem.eql(u8, info.pipeline_id, task.pipeline_id)) {
                log.warn("task {s} pipeline changed, removing", .{task.task_id});
                if (task.subprocess) |*sub| {
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                    self.releasePort(sub.port);
                }
                self.state.mutex.lock();
                self.state.failed_count += 1;
                self.state.mutex.unlock();
                to_remove.append(tick_alloc, key) catch continue;
                continue;
            }

            if (!std.mem.eql(u8, info.stage, task.task_identifier)) {
                log.info("task {s} stage changed externally from {s} to {s}, stopping local execution", .{
                    task.task_id,
                    task.task_identifier,
                    info.stage,
                });
                self.finishAfterExternalTransition(task);
                continue;
            }

            self.replaceOwnedString(&task.task_title, info.title) catch {};
            self.replaceOwnedString(&task.task_json, info.task_json) catch {};
            task.task_version = info.task_version;
        }

        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
    }

    /// workspace_setup → spawning (subprocess) or running (dispatch).
    /// Spawns NullClaw and transitions to spawning for async health check.
    fn driveSpawning(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        if (std.mem.eql(u8, task.execution_mode, "dispatch")) {
            task.state = .running;
            self.driveRunning(tick_alloc, task);
            return;
        }

        const port = self.allocatePort() orelse {
            log.err("no free port for task {s}", .{task.task_id});
            task.state = .failed;
            return;
        };

        const child = subprocess_mod.spawnNullClaw(
            tick_alloc,
            self.cfg.subprocess.command,
            self.cfg.subprocess.args,
            port,
            task.workspace_path,
        ) catch |err| {
            log.err("failed to spawn NullClaw for task {s}: {}", .{ task.task_id, err });
            self.releasePort(port);
            task.state = .failed;
            return;
        };

        task.subprocess = subprocess_mod.SubprocessInfo{
            .task_id = task.task_id,
            .lease_id = task.lease_id,
            .lease_token = task.lease_token,
            .workspace_path = task.workspace_path,
            .pipeline_id = task.pipeline_id,
            .agent_role = task.agent_role,
            .port = port,
            .child = child,
            .current_turn = 0,
            .max_turns = task.max_turns,
            .started_at_ms = task.started_at_ms,
            .last_activity_ms = ids.nowMs(),
            .state = .starting,
            .last_output = null,
            .run_id = task.run_id,
            .task_title = task.task_title,
            .task_identifier = task.task_identifier,
            .execution_mode = task.execution_mode,
        };

        // Post agent_started event
        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        const event_data = std.fmt.allocPrint(tick_alloc, "{{\"port\":{d}}}", .{port}) catch "{}";
        _ = client.postEvent(task.run_id, "agent_started", event_data, task.lease_token) catch {};

        // Transition to spawning — health check will be done non-blocking in driveHealthCheck
        task.state = .spawning;
        task.health_retries = 0;
        task.last_activity_ms = ids.nowMs();
    }

    /// spawning: non-blocking health check, one attempt per tick.
    /// After max retries → failed. On success → running.
    fn driveHealthCheck(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        const sub = &(task.subprocess orelse {
            task.state = .failed;
            return;
        });

        // Try one health check attempt (non-blocking, no retries)
        const healthy = subprocess_mod.waitForHealth(tick_alloc, sub.port, 1);

        if (healthy) {
            log.info("NullClaw healthy for task {s} on port {d}", .{ task.task_id, sub.port });
            task.state = .running;
            task.last_activity_ms = ids.nowMs();
            return;
        }

        task.health_retries += 1;
        if (task.health_retries >= self.cfg.subprocess.health_check_retries) {
            log.err("NullClaw health check failed for task {s} on port {d} after {d} retries", .{
                task.task_id,
                sub.port,
                task.health_retries,
            });
            if (sub.child) |*ch| {
                subprocess_mod.killSubprocess(ch);
            }
            self.releasePort(sub.port);
            task.subprocess = null;
            task.state = .failed;
        }
    }

    /// running: send prompt, check NullTickets state after response
    fn driveRunning(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        if (std.mem.eql(u8, task.execution_mode, "dispatch")) {
            self.driveDispatch(tick_alloc, task);
            return;
        }

        const sub = &(task.subprocess orelse {
            task.state = .failed;
            return;
        });

        // Render prompt
        const prompt: ?[]const u8 = if (task.current_turn == 0) blk: {
            const workflow = self.workflows.get(task.pipeline_id) orelse {
                log.err("no workflow for pipeline {s}", .{task.pipeline_id});
                task.state = .failed;
                break :blk null;
            };
            const tmpl = workflow.prompt_template orelse {
                log.err("no prompt_template for pipeline {s}", .{task.pipeline_id});
                task.state = .failed;
                break :blk null;
            };
            const ctx = templates.Context{
                .input_json = task.task_json,
                .step_outputs = &.{},
                .item = null,
                .task_json = task.task_json,
            };
            break :blk templates.render(tick_alloc, tmpl, ctx) catch |err| {
                log.err("template render failed for task {s}: {s}", .{ task.task_id, @errorName(err) });
                task.state = .failed;
                break :blk null;
            };
        } else blk: {
            break :blk self.cfg.subprocess.continuation_prompt;
        };

        if (prompt == null) return;

        // Send prompt via POST /webhook
        const response = subprocess_mod.sendPrompt(tick_alloc, sub.port, prompt.?) catch |err| {
            log.err("sendPrompt failed for task {s}: {s}", .{ task.task_id, @errorName(err) });
            task.state = .failed;
            return;
        };

        task.current_turn += 1;
        task.last_activity_ms = ids.nowMs();
        sub.last_activity_ms = ids.nowMs();
        sub.current_turn = task.current_turn;

        // Post turn_completed event
        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        const turn_data = std.fmt.allocPrint(tick_alloc, "{{\"turn\":{d}}}", .{task.current_turn}) catch "{}";
        _ = client.postEvent(task.run_id, "turn_completed", turn_data, task.lease_token) catch {};

        // Check NullTickets for task state change
        const task_info = client.getTask(task.task_id) catch null;
        if (task_info) |info| {
            defer {
                tick_alloc.free(info.id);
                tick_alloc.free(info.title);
                tick_alloc.free(info.description);
                tick_alloc.free(info.stage);
                tick_alloc.free(info.pipeline_id);
                tick_alloc.free(info.metadata_json);
                tick_alloc.free(info.task_json);
            }
            if (!std.mem.eql(u8, info.stage, task.task_identifier)) {
                log.info("task {s} stage changed externally from {s} to {s}, stopping local execution", .{ task.task_id, task.task_identifier, info.stage });
                self.finishAfterExternalTransition(task);
                return;
            }
            self.replaceOwnedString(&task.task_title, info.title) catch {};
            self.replaceOwnedString(&task.task_json, info.task_json) catch {};
            task.task_version = info.task_version;
        }

        // response (if any) is allocated with tick_alloc and freed at end of tick — do not store
        _ = response;

        if (task.current_turn >= task.max_turns) {
            log.warn("task {s} reached max_turns ({d}), failing", .{ task.task_id, task.max_turns });
            task.state = .failed;
            return;
        }
    }

    /// Dispatch execution path
    fn driveDispatch(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        const workflow = self.workflows.get(task.pipeline_id) orelse {
            log.err("no workflow for pipeline {s}", .{task.pipeline_id});
            task.state = .failed;
            return;
        };

        const tmpl = workflow.prompt_template orelse {
            log.err("no prompt_template for dispatch pipeline {s}", .{task.pipeline_id});
            task.state = .failed;
            return;
        };

        const ctx = templates.Context{
            .input_json = task.task_json,
            .step_outputs = &.{},
            .item = null,
            .task_json = task.task_json,
        };

        const rendered = templates.render(tick_alloc, tmpl, ctx) catch |err| {
            log.err("template render failed for dispatch task {s}: {s}", .{ task.task_id, @errorName(err) });
            task.state = .failed;
            return;
        };

        // TODO: Wire actual dispatch.zig call using workflow.dispatch.worker_tags and protocol
        log.warn("dispatch execution not yet implemented for task {s} ({d} bytes rendered), failing", .{ task.task_id, rendered.len });
        task.state = .failed;
    }

    /// completing: run after_run hook, call transition, kill subprocess
    fn driveCompleting(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        if (self.cfg.workspace.hooks.after_run) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        const trigger = self.resolveSuccessTrigger(tick_alloc, task) catch |err| {
            log.warn("failed to resolve success trigger for task {s}: {s}", .{ task.task_id, @errorName(err) });
            task.state = .failed;
            return;
        };

        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        const ok = client.transition(
            task.run_id,
            trigger,
            task.lease_token,
            null,
            task.task_identifier,
            task.task_version,
        ) catch |err| {
            log.warn("transition failed for task {s}: {s}", .{ task.task_id, @errorName(err) });
            task.state = .failed;
            return;
        };
        if (!ok) {
            log.warn("transition rejected for task {s} with trigger {s}", .{ task.task_id, trigger });
            task.state = .failed;
            return;
        }

        if (task.subprocess) |*sub| {
            if (sub.child) |*child| {
                subprocess_mod.killSubprocess(child);
            }
            self.releasePort(sub.port);
        }

        task.state = .completed;
    }

    /// completed: run before_remove hook, remove workspace, increment counter, mark for removal
    fn driveCompleted(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        _ = tick_alloc;

        if (self.cfg.workspace.hooks.before_remove) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        const ws = workspace_mod.Workspace{
            .root = self.cfg.workspace.root,
            .task_id = task.task_id,
            .path = task.workspace_path,
            .created = true,
        };
        ws.remove();

        self.state.mutex.lock();
        self.state.completed_count += 1;
        self.state.mutex.unlock();
        task.state = .removing;
    }

    /// failed: call failRun, run after_run hook, kill subprocess, remove workspace, mark for removal
    fn driveFailed(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        _ = client.failRun(task.run_id, "execution failed", task.lease_token, null) catch {};

        if (self.cfg.workspace.hooks.after_run) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        if (task.subprocess) |*sub| {
            if (sub.child) |*child| {
                subprocess_mod.killSubprocess(child);
            }
            self.releasePort(sub.port);
        }

        const ws = workspace_mod.Workspace{
            .root = self.cfg.workspace.root,
            .task_id = task.task_id,
            .path = task.workspace_path,
            .created = true,
        };
        ws.remove();

        self.state.mutex.lock();
        self.state.failed_count += 1;
        self.state.mutex.unlock();
        task.state = .removing;
    }

    /// Kill all running subprocesses (called during shutdown).
    fn shutdownSubprocesses(self: *Tracker) void {
        for (self.state.running.values()) |*task| {
            if (task.subprocess) |*sub| {
                if (sub.child) |*child| {
                    log.info("killing subprocess for task {s}", .{task.task_id});
                    subprocess_mod.killSubprocess(child);
                }
            }
        }
    }

    fn replaceOwnedString(self: *Tracker, target: *[]const u8, value: []const u8) !void {
        const duped = try self.allocator.dupe(u8, value);
        self.allocator.free(target.*);
        target.* = duped;
    }

    fn finishAfterExternalTransition(self: *Tracker, task: *RunningTask) void {
        if (task.subprocess) |*sub| {
            if (sub.child) |*child| {
                subprocess_mod.killSubprocess(child);
            }
            self.releasePort(sub.port);
            task.subprocess = null;
        }
        task.state = .completed;
    }

    fn resolveSuccessTrigger(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) ![]const u8 {
        if (self.workflows.get(task.pipeline_id)) |workflow| {
            if (workflow.on_success.transition_to.len > 0) {
                return workflow.on_success.transition_to;
            }
        }

        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        const info = (try client.getTask(task.task_id)) orelse return error.MissingSuccessTrigger;
        if (info.available_transitions.len == 1) {
            return info.available_transitions[0].trigger;
        }
        return error.MissingSuccessTrigger;
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "TrackerState init and counts" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 0), state.runningCount());
    try std.testing.expectEqual(@as(u64, 0), state.completed_count);
    try std.testing.expectEqual(@as(u64, 0), state.failed_count);
    try std.testing.expectEqual(@as(u32, 0), state.countByPipeline("any"));
    try std.testing.expectEqual(@as(u32, 0), state.countByRole("any"));
}

test "canClaimMore respects global limit max=0" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    const concurrency = config.ConcurrencyConfig{
        .max_concurrent_tasks = 0,
        .per_pipeline = null,
        .per_role = null,
    };

    try std.testing.expect(!canClaimMore(&state, concurrency, "pipe-1", "coder"));
}

test "canClaimMore respects global limit max=10 empty state" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    const concurrency = config.ConcurrencyConfig{
        .max_concurrent_tasks = 10,
        .per_pipeline = null,
        .per_role = null,
    };

    try std.testing.expect(canClaimMore(&state, concurrency, "pipe-1", "coder"));
}

test "TrackerState countByPipeline and countByRole" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    const now = ids.nowMs();

    // Insert two tasks with different pipelines/roles
    // Owned fields must be duped since deinit frees them
    const key1 = try allocator.dupe(u8, "task-001");
    try state.running.put(allocator, key1, RunningTask{
        .task_id = try allocator.dupe(u8, "task-001"),
        .task_title = try allocator.dupe(u8, "Task 1"),
        .task_identifier = try allocator.dupe(u8, "T-1"),
        .task_json = try allocator.dupe(u8, "{\"id\":\"task-001\"}"),
        .pipeline_id = try allocator.dupe(u8, "pipeline-a"),
        .agent_role = "coder",
        .lease_id = try allocator.dupe(u8, "lease-1"),
        .lease_token = try allocator.dupe(u8, "token-1"),
        .run_id = try allocator.dupe(u8, "run-1"),
        .workspace_path = try allocator.dupe(u8, "/tmp/ws1"),
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .task_version = 1,
        .current_turn = 0,
        .max_turns = 10,
        .state = .running,
    });

    const key2 = try allocator.dupe(u8, "task-002");
    try state.running.put(allocator, key2, RunningTask{
        .task_id = try allocator.dupe(u8, "task-002"),
        .task_title = try allocator.dupe(u8, "Task 2"),
        .task_identifier = try allocator.dupe(u8, "T-2"),
        .task_json = try allocator.dupe(u8, "{\"id\":\"task-002\"}"),
        .pipeline_id = try allocator.dupe(u8, "pipeline-a"),
        .agent_role = "reviewer",
        .lease_id = try allocator.dupe(u8, "lease-2"),
        .lease_token = try allocator.dupe(u8, "token-2"),
        .run_id = try allocator.dupe(u8, "run-2"),
        .workspace_path = try allocator.dupe(u8, "/tmp/ws2"),
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .task_version = 1,
        .current_turn = 0,
        .max_turns = 10,
        .state = .running,
    });

    const key3 = try allocator.dupe(u8, "task-003");
    try state.running.put(allocator, key3, RunningTask{
        .task_id = try allocator.dupe(u8, "task-003"),
        .task_title = try allocator.dupe(u8, "Task 3"),
        .task_identifier = try allocator.dupe(u8, "T-3"),
        .task_json = try allocator.dupe(u8, "{\"id\":\"task-003\"}"),
        .pipeline_id = try allocator.dupe(u8, "pipeline-b"),
        .agent_role = "coder",
        .lease_id = try allocator.dupe(u8, "lease-3"),
        .lease_token = try allocator.dupe(u8, "token-3"),
        .run_id = try allocator.dupe(u8, "run-3"),
        .workspace_path = try allocator.dupe(u8, "/tmp/ws3"),
        .execution_mode = "dispatch",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .task_version = 1,
        .current_turn = 0,
        .max_turns = 20,
        .state = .running,
    });

    try std.testing.expectEqual(@as(u32, 3), state.runningCount());
    try std.testing.expectEqual(@as(u32, 2), state.countByPipeline("pipeline-a"));
    try std.testing.expectEqual(@as(u32, 1), state.countByPipeline("pipeline-b"));
    try std.testing.expectEqual(@as(u32, 0), state.countByPipeline("pipeline-c"));
    try std.testing.expectEqual(@as(u32, 2), state.countByRole("coder"));
    try std.testing.expectEqual(@as(u32, 1), state.countByRole("reviewer"));
    try std.testing.expectEqual(@as(u32, 0), state.countByRole("deployer"));
}

test "TrackerState isInCooldown" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    // Not in cooldown by default
    try std.testing.expect(!state.isInCooldown("task-x"));

    // Add a cooldown far in the future
    const future_key = try allocator.dupe(u8, "task-future");
    try state.cooldowns.put(allocator, future_key, ids.nowMs() + 999_999);
    try std.testing.expect(state.isInCooldown("task-future"));

    // Add a cooldown in the past
    const past_key = try allocator.dupe(u8, "task-past");
    try state.cooldowns.put(allocator, past_key, 0);
    try std.testing.expect(!state.isInCooldown("task-past"));
}

test "canClaimMore at global limit returns false" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    const now = ids.nowMs();

    // Fill up to global max of 1
    const key = try allocator.dupe(u8, "task-fill");
    try state.running.put(allocator, key, RunningTask{
        .task_id = try allocator.dupe(u8, "task-fill"),
        .task_title = try allocator.dupe(u8, "Fill"),
        .task_identifier = try allocator.dupe(u8, "F-1"),
        .task_json = try allocator.dupe(u8, "{\"id\":\"task-fill\"}"),
        .pipeline_id = try allocator.dupe(u8, "pipe"),
        .agent_role = "coder",
        .lease_id = try allocator.dupe(u8, "l"),
        .lease_token = try allocator.dupe(u8, "t"),
        .run_id = try allocator.dupe(u8, "r"),
        .workspace_path = try allocator.dupe(u8, "/tmp"),
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .task_version = 1,
        .current_turn = 0,
        .max_turns = 10,
        .state = .running,
    });

    const concurrency = config.ConcurrencyConfig{
        .max_concurrent_tasks = 1,
        .per_pipeline = null,
        .per_role = null,
    };

    try std.testing.expect(!canClaimMore(&state, concurrency, "pipe", "coder"));
}

test "TrackerState mutex can be locked and unlocked" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    state.mutex.lock();
    try std.testing.expectEqual(@as(u32, 0), state.runningCount());
    state.mutex.unlock();
}

test "Tracker allocatePort returns unique ports" {
    const allocator = std.testing.allocator;
    var shutdown = std.atomic.Value(bool).init(false);
    const workflows = workflow_loader.WorkflowMap{};

    var tracker_inst = Tracker.init(allocator, config.TrackerConfig{}, workflows, &shutdown);
    defer tracker_inst.deinit();

    const port1 = tracker_inst.allocatePort();
    try std.testing.expectEqual(@as(u16, 9200), port1.?);

    const port2 = tracker_inst.allocatePort();
    try std.testing.expectEqual(@as(u16, 9201), port2.?);

    tracker_inst.releasePort(9200);

    const port3 = tracker_inst.allocatePort();
    try std.testing.expectEqual(@as(u16, 9200), port3.?);
}
