/// Tracker Thread — pull-mode agent that polls NullTickets, claims tasks,
/// manages subprocess lifecycles, and heartbeats leases.
///
/// Each tick:
///   1. Heartbeat all active leases
///   2. Detect stalled subprocesses
///   3. Poll NullTickets and claim new tasks (respecting concurrency limits)
///   4. Clean expired cooldowns
const std = @import("std");
const log = std.log.scoped(.tracker);

const config = @import("config.zig");
const types = @import("types.zig");
const ids = @import("ids.zig");
const subprocess_mod = @import("subprocess.zig");
const workspace_mod = @import("workspace.zig");
const workflow_loader = @import("workflow_loader.zig");
const tracker_client = @import("tracker_client.zig");

// ── RunningTask ─────────────────────────────────────────────────────

pub const RunningTask = struct {
    task_id: []const u8,
    task_title: []const u8,
    task_identifier: []const u8,
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
    current_turn: u32,
    max_turns: u32,
    state: types.TrackerTaskState,
};

// ── TrackerState ────────────────────────────────────────────────────

pub const TrackerState = struct {
    running: std.StringArrayHashMapUnmanaged(RunningTask),
    completed_count: u64,
    failed_count: u64,
    cooldowns: std.StringArrayHashMapUnmanaged(i64),

    pub fn init() TrackerState {
        return .{
            .running = .{},
            .completed_count = 0,
            .failed_count = 0,
            .cooldowns = .{},
        };
    }

    pub fn deinit(self: *TrackerState, allocator: std.mem.Allocator) void {
        // Free all duped keys in running map
        for (self.running.keys()) |key| {
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
        };
    }

    pub fn deinit(self: *Tracker) void {
        self.shutdownSubprocesses();
        self.state.deinit(self.allocator);
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

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
            const ok = client.heartbeat(task.lease_id, task.lease_token) catch false;
            if (!ok) {
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

        // Remove failed heartbeat tasks
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
    }

    /// Detect stalled subprocesses. If stalled, report failure to NullTickets,
    /// kill the subprocess, remove from running, and increment failed_count.
    fn detectStalls(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            if (task.subprocess) |*sub| {
                if (subprocess_mod.isStalled(sub, @as(i64, @intCast(self.cfg.stall_timeout_ms)))) {
                    log.warn("task {s} stalled (no activity for {d}ms), failing", .{
                        key,
                        self.cfg.stall_timeout_ms,
                    });

                    // Report failure to NullTickets
                    var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
                    _ = client.failRun(task.run_id, "subprocess stalled", task.lease_token) catch {};

                    // Kill subprocess
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }

                    self.state.failed_count += 1;
                    to_remove.append(tick_alloc, key) catch continue;
                }
            }
        }

        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.allocator.free(entry.key);
            }
        }
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

        // Dupe the task_id for use as the map key
        const key = try self.allocator.dupe(u8, claim.task.id);
        errdefer self.allocator.free(key);

        const running_task = RunningTask{
            .task_id = claim.task.id,
            .task_title = claim.task.title,
            .task_identifier = claim.task.stage,
            .pipeline_id = claim.task.pipeline_id,
            .agent_role = role,
            .lease_id = claim.lease_id,
            .lease_token = claim.lease_token,
            .run_id = claim.run.id,
            .workspace_path = ws.path,
            .execution_mode = execution_mode_str,
            .subprocess = null,
            .started_at_ms = now,
            .last_activity_ms = now,
            .current_turn = 0,
            .max_turns = workflow.subprocess.max_turns,
            .state = .workspace_setup,
        };

        try self.state.running.put(self.allocator, key, running_task);

        log.info("started task {s} (pipeline={s}, role={s}, mode={s})", .{
            claim.task.id,
            claim.task.pipeline_id,
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

    /// Kill all running subprocesses (called during shutdown).
    fn shutdownSubprocesses(self: *Tracker) void {
        for (self.state.running.values()) |task| {
            if (task.subprocess) |*sub| {
                if (sub.child) |*child| {
                    log.info("killing subprocess for task {s}", .{task.task_id});
                    subprocess_mod.killSubprocess(child);
                }
            }
        }
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
    const key1 = try allocator.dupe(u8, "task-001");
    try state.running.put(allocator, key1, RunningTask{
        .task_id = "task-001",
        .task_title = "Task 1",
        .task_identifier = "T-1",
        .pipeline_id = "pipeline-a",
        .agent_role = "coder",
        .lease_id = "lease-1",
        .lease_token = "token-1",
        .run_id = "run-1",
        .workspace_path = "/tmp/ws1",
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .current_turn = 0,
        .max_turns = 10,
        .state = .running,
    });

    const key2 = try allocator.dupe(u8, "task-002");
    try state.running.put(allocator, key2, RunningTask{
        .task_id = "task-002",
        .task_title = "Task 2",
        .task_identifier = "T-2",
        .pipeline_id = "pipeline-a",
        .agent_role = "reviewer",
        .lease_id = "lease-2",
        .lease_token = "token-2",
        .run_id = "run-2",
        .workspace_path = "/tmp/ws2",
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
        .current_turn = 0,
        .max_turns = 10,
        .state = .running,
    });

    const key3 = try allocator.dupe(u8, "task-003");
    try state.running.put(allocator, key3, RunningTask{
        .task_id = "task-003",
        .task_title = "Task 3",
        .task_identifier = "T-3",
        .pipeline_id = "pipeline-b",
        .agent_role = "coder",
        .lease_id = "lease-3",
        .lease_token = "token-3",
        .run_id = "run-3",
        .workspace_path = "/tmp/ws3",
        .execution_mode = "dispatch",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
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
        .task_id = "task-fill",
        .task_title = "Fill",
        .task_identifier = "F-1",
        .pipeline_id = "pipe",
        .agent_role = "coder",
        .lease_id = "l",
        .lease_token = "t",
        .run_id = "r",
        .workspace_path = "/tmp",
        .execution_mode = "subprocess",
        .subprocess = null,
        .started_at_ms = now,
        .last_activity_ms = now,
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
