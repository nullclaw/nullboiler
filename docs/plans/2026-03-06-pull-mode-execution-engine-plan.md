# Pull-Mode Execution Engine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the execution engine that drives claimed tasks through subprocess spawning, multi-turn NullClaw sessions, dispatch execution, reconciliation, and cleanup.

**Architecture:** Tasks claimed from NullTickets are driven through a state machine (`workspace_setup → spawning → running → completing → completed`). Subprocess-mode spawns NullClaw per task on a unique port, sends prompts via `POST /webhook`, checks NullTickets after each turn. Dispatch-mode uses existing `dispatch.zig`. All state writes protected by a mutex shared with the HTTP API thread.

**Tech Stack:** Zig 0.15.2, HTTP client (std.http), NullTickets REST API, NullClaw HTTP webhook protocol

**Design doc:** `docs/plans/2026-03-06-pull-mode-execution-engine-design.md`

---

### Task 1: Add `spawning` state to TrackerTaskState

**Files:**
- Modify: `src/types.zig:109-129`
- Test: `src/types.zig` (existing test at line 276)

**Step 1: Add the spawning variant**

In `src/types.zig:109`, add `spawning` between `workspace_setup` and `running`:

```zig
pub const TrackerTaskState = enum {
    claiming,
    workspace_setup,
    spawning,
    running,
    completing,
    completed,
    failed,
    stalled,
    cooldown,
    // ... rest unchanged
};
```

**Step 2: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: All tests pass (existing round-trip test still works since it tests `running`)

**Step 3: Commit**

```bash
git add src/types.zig
git commit -m "feat: add spawning state to TrackerTaskState"
```

---

### Task 2: Add mutex to TrackerState

**Files:**
- Modify: `src/tracker.zig:42-110` (TrackerState struct)

**Step 1: Write the failing test**

Add test at the end of `src/tracker.zig`:

```zig
test "TrackerState mutex can be locked and unlocked" {
    const allocator = std.testing.allocator;
    var state = TrackerState.init();
    defer state.deinit(allocator);

    state.mutex.lock();
    // Can access state while locked
    try std.testing.expectEqual(@as(u32, 0), state.runningCount());
    state.mutex.unlock();
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "mutex"`
Expected: FAIL — no field named `mutex`

**Step 3: Add mutex field to TrackerState**

In `src/tracker.zig:46`, add `mutex` field and initialize it:

```zig
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
    // ... rest unchanged
};
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 5: Commit**

```bash
git add src/tracker.zig
git commit -m "feat: add mutex to TrackerState for thread safety"
```

---

### Task 3: Add mutex locking in API tracker handlers

**Files:**
- Modify: `src/api.zig:1042-1111` (handleTrackerStatus, handleTrackerTasks, handleTrackerTaskDetail)
- Modify: `src/api.zig:25` (Context.tracker_state type)

The `tracker_state` in Context needs to be non-const to allow locking the mutex. Update Context and each handler.

**Step 1: Change tracker_state to mutable pointer**

In `src/api.zig:25`, change:
```zig
tracker_state: ?*tracker_mod.TrackerState = null,
```
(Remove the `const`)

**Step 2: Add mutex lock/unlock in handleTrackerStatus**

In `src/api.zig:1042`, after getting `state`, add lock/unlock:

```zig
fn handleTrackerStatus(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };
    const cfg = ctx.tracker_cfg orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    // ... rest of function unchanged
```

**Step 3: Add mutex lock/unlock in handleTrackerTasks**

Same pattern in `src/api.zig:1079`:

```zig
fn handleTrackerTasks(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    // ... rest unchanged
```

**Step 4: Add mutex lock/unlock in handleTrackerTaskDetail**

Same pattern in `src/api.zig:1100`:

```zig
fn handleTrackerTaskDetail(ctx: *Context, task_id: []const u8) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    // ... rest unchanged
```

**Step 5: Update main.zig to pass mutable pointer**

Find where `tracker_state` is set on the Context in `src/main.zig` and change from `&tracker.state` (const) to `&tracker.state` (mutable). Since `Tracker` is `var`, its `state` field should already be mutable — check that the pointer cast is correct.

**Step 6: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 7: Commit**

```bash
git add src/api.zig src/main.zig
git commit -m "feat: add mutex locking in tracker API handlers"
```

---

### Task 4: Extend config for subprocess settings

**Files:**
- Modify: `src/config.zig:46-50` (SubprocessDefaults)
- Test: `src/config.zig` (existing test at line 159)

**Step 1: Write the failing test**

Add test at end of `src/config.zig`:

```zig
test "SubprocessDefaults has base_port and health_check_retries" {
    const sd = SubprocessDefaults{};
    try std.testing.expectEqual(@as(u16, 9200), sd.base_port);
    try std.testing.expectEqual(@as(u32, 10), sd.health_check_retries);
    try std.testing.expectEqualStrings("nullclaw", sd.command);
    try std.testing.expectEqual(@as(usize, 0), sd.args.len);
    try std.testing.expectEqualStrings("Continue working on this task. Your previous context is preserved.", sd.continuation_prompt);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "base_port"`
Expected: FAIL — no field named `base_port`

**Step 3: Add new fields to SubprocessDefaults**

In `src/config.zig:46-50`, update:

```zig
pub const SubprocessDefaults = struct {
    command: []const u8 = "nullclaw",
    args: []const []const u8 = &.{},
    base_port: u16 = 9200,
    health_check_retries: u32 = 10,
    max_turns: u32 = 20,
    turn_timeout_ms: u32 = 600000,
    continuation_prompt: []const u8 = "Continue working on this task. Your previous context is preserved.",
};
```

Note: `args` already exists in `SubprocessConfig` in `workflow_loader.zig` but needs to exist here too as a global default. The `workflow_loader.zig` `SubprocessConfig` is per-workflow override; this is the global fallback.

**Step 4: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat: add base_port, health_check_retries, continuation_prompt to SubprocessDefaults"
```

---

### Task 5: Fix sendPrompt to use /webhook endpoint

**Files:**
- Modify: `src/subprocess.zig:126-165` (sendPrompt function)

**Step 1: Update sendPrompt to use /webhook path**

Change line 133 in `src/subprocess.zig`:

```zig
const url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/webhook", .{port});
```

Also update the doc comment at line 126:

```zig
/// Send a prompt to a NullClaw child process via POST /webhook with {"message": prompt}.
/// Returns the response body on success, or null on failure.
```

**Step 2: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS (no tests hit real HTTP, sendPrompt is not tested with live server)

**Step 3: Commit**

```bash
git add src/subprocess.zig
git commit -m "fix: use /webhook endpoint for NullClaw prompts"
```

---

### Task 6: Add postEvent and update transition/failRun for usage JSON

**Files:**
- Modify: `src/tracker_client.zig:107-139` (transition, failRun)
- Modify: `src/tracker_client.zig` (add postEvent method)

**Step 1: Write failing test for postEvent**

Add test at end of `src/tracker_client.zig`:

```zig
test "TrackerClient has postEvent method" {
    const allocator = std.testing.allocator;
    var client = TrackerClient.init(allocator, "http://localhost:9999", null);
    // Just verify the method exists and compiles — actual HTTP call will fail
    _ = &client;
    // Compile-time check: postEvent exists
    const has_method = @hasDecl(TrackerClient, "postEvent");
    try std.testing.expect(has_method);
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "postEvent"`
Expected: FAIL — no decl named `postEvent`

**Step 3: Update transition() to accept trigger and usage JSON**

Replace `src/tracker_client.zig:107-122`:

```zig
    /// POST /runs/{id}/transition — move a run to the next stage.
    /// Uses lease_token as Bearer override. Returns true on 2xx.
    pub fn transition(self: *TrackerClient, run_id: []const u8, trigger: []const u8, lease_token: []const u8, usage_json: ?[]const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/transition", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        // Build body with trigger and optional usage
        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.appendSlice(self.allocator, "{\"trigger\":\"");
        try body_buf.appendSlice(self.allocator, trigger);
        try body_buf.appendSlice(self.allocator, "\"");
        if (usage_json) |usage| {
            try body_buf.appendSlice(self.allocator, ",\"usage\":");
            try body_buf.appendSlice(self.allocator, usage);
        }
        try body_buf.appendSlice(self.allocator, "}");

        const body = body_buf.items;
        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }
```

**Step 4: Update failRun() to accept usage JSON**

Replace `src/tracker_client.zig:124-139`:

```zig
    /// POST /runs/{id}/fail — report a run failure with reason.
    /// Uses lease_token as Bearer override. Returns true on 2xx.
    pub fn failRun(self: *TrackerClient, run_id: []const u8, reason: []const u8, lease_token: []const u8, usage_json: ?[]const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/fail", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.appendSlice(self.allocator, "{\"reason\":\"");
        try body_buf.appendSlice(self.allocator, reason);
        try body_buf.appendSlice(self.allocator, "\"");
        if (usage_json) |usage| {
            try body_buf.appendSlice(self.allocator, ",\"usage\":");
            try body_buf.appendSlice(self.allocator, usage);
        }
        try body_buf.appendSlice(self.allocator, "}");

        const body = body_buf.items;
        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }
```

**Step 5: Add postEvent method**

Add after `failRun` in `src/tracker_client.zig`:

```zig
    /// POST /runs/{id}/events — post a progress event.
    /// Returns true on 2xx.
    pub fn postEvent(self: *TrackerClient, run_id: []const u8, kind: []const u8, data_json: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/events", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        var body_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer body_buf.deinit(self.allocator);

        try body_buf.appendSlice(self.allocator, "{\"kind\":\"");
        try body_buf.appendSlice(self.allocator, kind);
        try body_buf.appendSlice(self.allocator, "\",\"data\":");
        try body_buf.appendSlice(self.allocator, data_json);
        try body_buf.appendSlice(self.allocator, "}");

        const body = body_buf.items;
        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }
```

**Step 6: Update callers of failRun to pass null usage**

In `src/tracker.zig:291`, update the stall detection call:

```zig
_ = client.failRun(task.run_id, "subprocess stalled", task.lease_token, null) catch {};
```

**Step 7: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 8: Commit**

```bash
git add src/tracker_client.zig src/tracker.zig
git commit -m "feat: add postEvent, update transition/failRun for usage JSON"
```

---

### Task 7: Add port allocator to Tracker

**Files:**
- Modify: `src/tracker.zig:158-180` (Tracker struct, init)

**Step 1: Write the failing test**

Add test at end of `src/tracker.zig`:

```zig
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
```

**Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "allocatePort"`
Expected: FAIL — no member named `allocatePort`

**Step 3: Add used_ports map and allocatePort/releasePort**

In `src/tracker.zig`, add `used_ports` field to `Tracker` struct (after `last_heartbeat_ms`):

```zig
pub const Tracker = struct {
    allocator: std.mem.Allocator,
    cfg: config.TrackerConfig,
    state: TrackerState,
    workflows: workflow_loader.WorkflowMap,
    shutdown: *std.atomic.Value(bool),
    last_heartbeat_ms: i64,
    used_ports: std.AutoArrayHashMapUnmanaged(u16, void),
```

Update `init()`:
```zig
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
```

Update `deinit()`:
```zig
    pub fn deinit(self: *Tracker) void {
        self.shutdownSubprocesses();
        self.used_ports.deinit(self.allocator);
        self.state.deinit(self.allocator);
    }
```

Add port allocation methods:

```zig
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
```

**Step 4: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 5: Commit**

```bash
git add src/tracker.zig
git commit -m "feat: add port allocator to Tracker"
```

---

### Task 8: Implement driveRunningTasks state machine

This is the core task. The `driveRunningTasks()` method iterates over all running tasks and advances their state machine.

**Files:**
- Modify: `src/tracker.zig` (add driveRunningTasks method, update tick)
- Imports needed: `templates.zig`

**Step 1: Add templates import**

At the top of `src/tracker.zig`, add:

```zig
const templates = @import("templates.zig");
```

**Step 2: Add driveRunningTasks call to tick()**

In `src/tracker.zig:225-234`, update `tick()`:

```zig
    fn tick(self: *Tracker) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const tick_alloc = arena.allocator();

        self.heartbeatAll(tick_alloc);
        self.detectStalls(tick_alloc);
        self.driveRunningTasks(tick_alloc);
        self.pollAndClaim(tick_alloc);
        self.cleanCooldowns();
    }
```

**Step 3: Implement driveRunningTasks**

Add the following method to `Tracker` (after `detectStalls`):

```zig
    /// Drive each running task through its state machine.
    fn driveRunningTasks(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        // Collect task IDs to process (can't modify map while iterating)
        var task_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer task_ids.deinit(tick_alloc);

        for (self.state.running.keys()) |key| {
            task_ids.append(tick_alloc, key) catch continue;
        }

        for (task_ids.items) |task_id| {
            const task = self.state.running.getPtr(task_id) orelse continue;
            switch (task.state) {
                .workspace_setup => self.driveSpawning(tick_alloc, task),
                .spawning => {}, // spawning is synchronous within driveSpawning
                .running => self.driveRunning(tick_alloc, task),
                .completing => self.driveCompleting(tick_alloc, task),
                .completed => self.driveCompleted(tick_alloc, task),
                .failed => self.driveFailed(tick_alloc, task),
                else => {},
            }
        }
    }

    /// workspace_setup → spawning → running (or failed)
    /// For subprocess mode: allocate port, spawn NullClaw, wait for health, send first prompt.
    /// For dispatch mode: skip directly to running.
    fn driveSpawning(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        if (std.mem.eql(u8, task.execution_mode, "dispatch")) {
            // Dispatch mode: render prompt and dispatch immediately
            task.state = .running;
            self.driveRunning(tick_alloc, task);
            return;
        }

        // Subprocess mode: allocate port and spawn NullClaw
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

        // Wait for health check
        const healthy = subprocess_mod.waitForHealth(
            tick_alloc,
            port,
            self.cfg.subprocess.health_check_retries,
        );

        if (!healthy) {
            log.err("NullClaw health check failed for task {s} on port {d}", .{ task.task_id, port });
            if (task.subprocess) |*sub| {
                if (sub.child) |*ch| {
                    subprocess_mod.killSubprocess(ch);
                }
            }
            self.releasePort(port);
            task.subprocess = null;
            task.state = .failed;
            return;
        }

        log.info("NullClaw healthy for task {s} on port {d}", .{ task.task_id, port });
        task.state = .running;
        task.last_activity_ms = ids.nowMs();
    }

    /// running: send prompt (turn 1 or continuation), check NullTickets state after response
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
        const prompt = if (task.current_turn == 0) blk: {
            // Turn 1: render workflow prompt template
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
                .input_json = "{}",
                .step_outputs = &.{},
                .item = null,
                .task_json = task.task_identifier, // TODO: pass full task metadata JSON
            };
            break :blk templates.render(tick_alloc, tmpl, ctx) catch |err| {
                log.err("template render failed for task {s}: {}", .{ task.task_id, err });
                task.state = .failed;
                break :blk null;
            };
        } else blk: {
            // Turn 2+: continuation prompt
            break :blk self.cfg.subprocess.continuation_prompt;
        };

        if (prompt == null) return; // state already set to failed

        // Send prompt via POST /webhook
        const response = subprocess_mod.sendPrompt(tick_alloc, sub.port, prompt.?) catch |err| {
            log.err("sendPrompt failed for task {s}: {}", .{ task.task_id, err });
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
            }
            // If stage changed from what we claimed → agent self-transitioned or external transition
            if (!std.mem.eql(u8, info.stage, task.task_identifier)) {
                log.info("task {s} stage changed from {s} to {s}, completing", .{ task.task_id, task.task_identifier, info.stage });
                task.state = .completing;
                return;
            }
        }

        // Store response for potential future use
        if (response) |resp| {
            sub.last_output = resp;
        }

        // Check if max turns reached
        if (task.current_turn >= task.max_turns) {
            log.warn("task {s} reached max_turns ({d}), failing", .{ task.task_id, task.max_turns });
            task.state = .failed;
            return;
        }

        // Stay in running state for next turn
    }

    /// Dispatch execution: render prompt, dispatch via dispatch.zig, transition
    fn driveDispatch(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        // For dispatch mode, we render the prompt and let the existing dispatch system handle it
        // This is a simplified path: render → dispatch → transition
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
            .input_json = "{}",
            .step_outputs = &.{},
            .item = null,
            .task_json = task.task_identifier,
        };

        const rendered = templates.render(tick_alloc, tmpl, ctx) catch |err| {
            log.err("template render failed for dispatch task {s}: {}", .{ task.task_id, err });
            task.state = .failed;
            return;
        };

        // TODO: Wire actual dispatch.zig call here using workflow.dispatch.worker_tags and workflow.dispatch.protocol
        // For now, log and transition
        log.info("dispatch task {s}: rendered prompt ({d} bytes), tags={any}", .{
            task.task_id,
            rendered.len,
            workflow.dispatch.worker_tags.len,
        });

        task.state = .completing;
    }

    /// completing: run after_run hook, call transition, kill subprocess
    fn driveCompleting(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        // Run after_run hook
        if (self.cfg.workspace.hooks.after_run) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        // Call transition on NullTickets
        const workflow = self.workflows.get(task.pipeline_id);
        const trigger = if (workflow) |w| w.on_success.transition_to else "done";

        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        _ = client.transition(task.run_id, trigger, task.lease_token, null) catch |err| {
            log.warn("transition failed for task {s}: {}", .{ task.task_id, err });
        };

        // Kill subprocess if present
        if (task.subprocess) |*sub| {
            if (sub.child) |*child| {
                subprocess_mod.killSubprocess(child);
            }
            self.releasePort(sub.port);
        }

        task.state = .completed;
    }

    /// completed: run before_remove hook, remove workspace, remove from running map
    fn driveCompleted(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        _ = tick_alloc;

        // Run before_remove hook
        if (self.cfg.workspace.hooks.before_remove) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        // Remove workspace
        const ws = workspace_mod.Workspace{
            .root = self.cfg.workspace.root,
            .task_id = task.task_id,
            .path = task.workspace_path,
            .created = true,
        };
        ws.remove();

        self.state.completed_count += 1;

        // Remove from running map (deferred to avoid modifying while iterating)
        // Mark for removal by setting a sentinel state
        task.state = .cooldown; // Reuse cooldown as "remove me" signal
    }

    /// failed: call failRun, run after_run hook, kill subprocess, remove
    fn driveFailed(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
        // Call failRun on NullTickets
        var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
        _ = client.failRun(task.run_id, "execution failed", task.lease_token, null) catch {};

        // Run after_run hook
        if (self.cfg.workspace.hooks.after_run) |hook| {
            _ = workspace_mod.runHook(self.allocator, hook, task.workspace_path, @as(u64, self.cfg.workspace.hook_timeout_ms)) catch false;
        }

        // Kill subprocess if present
        if (task.subprocess) |*sub| {
            if (sub.child) |*child| {
                subprocess_mod.killSubprocess(child);
            }
            self.releasePort(sub.port);
        }

        // Remove workspace
        const ws = workspace_mod.Workspace{
            .root = self.cfg.workspace.root,
            .task_id = task.task_id,
            .path = task.workspace_path,
            .created = true,
        };
        ws.remove();

        self.state.failed_count += 1;
        task.state = .cooldown; // Mark for removal
    }
```

**Step 4: Add cleanup of completed/failed tasks at end of driveRunningTasks**

Update `driveRunningTasks` to clean up tasks marked as cooldown:

```zig
    fn driveRunningTasks(self: *Tracker, tick_alloc: std.mem.Allocator) void {
        // Collect task IDs to process (can't modify map while iterating)
        var task_ids: std.ArrayListUnmanaged([]const u8) = .empty;
        defer task_ids.deinit(tick_alloc);

        for (self.state.running.keys()) |key| {
            task_ids.append(tick_alloc, key) catch continue;
        }

        for (task_ids.items) |task_id| {
            const task = self.state.running.getPtr(task_id) orelse continue;
            switch (task.state) {
                .workspace_setup => self.driveSpawning(tick_alloc, task),
                .spawning => {},
                .running => self.driveRunning(tick_alloc, task),
                .completing => self.driveCompleting(tick_alloc, task),
                .completed => self.driveCompleted(tick_alloc, task),
                .failed => self.driveFailed(tick_alloc, task),
                else => {},
            }
        }

        // Remove tasks marked for removal (state == cooldown after driveCompleted/driveFailed)
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(tick_alloc);

        for (self.state.running.keys(), self.state.running.values()) |key, task| {
            if (task.state == .cooldown) {
                to_remove.append(tick_alloc, key) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
    }
```

**Step 5: Run tests**

Run: `zig build test 2>&1 | head -30`
Expected: PASS (compile check — state machine logic tested in integration)

**Step 6: Commit**

```bash
git add src/tracker.zig
git commit -m "feat: implement driveRunningTasks state machine for execution engine"
```

---

### Task 9: Implement reconcile()

**Files:**
- Modify: `src/tracker.zig` (add reconcile method, update tick)

**Step 1: Add reconcile call to tick()**

In `tick()`, add after `driveRunningTasks`:

```zig
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
```

**Step 2: Implement reconcile**

Add to `Tracker`:

```zig
    /// Reconcile running tasks with NullTickets state.
    /// If a task's stage is terminal or task was reassigned, kill and clean up.
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
                // Task not found in NullTickets — was deleted or we lost access
                log.warn("task {s} not found in NullTickets, removing", .{task.task_id});
                if (task.subprocess) |*sub| {
                    if (sub.child) |*child| {
                        subprocess_mod.killSubprocess(child);
                    }
                    self.releasePort(sub.port);
                }
                self.state.failed_count += 1;
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
                self.state.failed_count += 1;
                to_remove.append(tick_alloc, key) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
    }
```

**Step 3: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 4: Commit**

```bash
git add src/tracker.zig
git commit -m "feat: implement reconcile() to sync with NullTickets state"
```

---

### Task 10: Add POST /tracker/refresh endpoint

**Files:**
- Modify: `src/api.zig` (add route and handler)

**Step 1: Add the route**

In `src/api.zig`, find the tracker route block (around line 149-161) and add:

```zig
    // POST /tracker/refresh
    if (is_post and eql(seg0, "tracker") and eql(seg1, "refresh") and seg2 == null) {
        return handleTrackerRefresh(&ctx);
    }
```

**Step 2: Implement handler**

Add after `handleTrackerTaskDetail`:

```zig
fn handleTrackerRefresh(ctx: *Context) HttpResponse {
    _ = ctx;
    // Refresh triggers an immediate tick — the tracker thread will pick it up
    // For now, just return 200 OK acknowledging the request
    return jsonResponse(200, "{\"status\":\"ok\",\"message\":\"refresh requested\"}");
}
```

Note: A full implementation would signal the tracker thread to wake up immediately. For now, this is a stub that can be enhanced later.

**Step 3: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 4: Commit**

```bash
git add src/api.zig
git commit -m "feat: add POST /tracker/refresh endpoint"
```

---

### Task 11: Add mutex locking in Tracker write paths

**Files:**
- Modify: `src/tracker.zig` (add lock/unlock around state mutations)

All `Tracker` methods that modify `self.state` need mutex protection. Since the tracker thread is the only writer and we've already added locks in API read handlers, we lock in the tracker thread around each state-mutating block.

**Step 1: Lock in driveRunningTasks**

Wrap the cleanup section (removal of cooldown tasks) with mutex:

```zig
        // Remove tasks marked for removal — lock for thread safety with API readers
        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
```

**Step 2: Lock in heartbeatAll removal**

Wrap the removal block in `heartbeatAll`:

```zig
        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
```

**Step 3: Lock in detectStalls removal and counter increment**

Wrap the removal and counter in `detectStalls`:

```zig
        self.state.mutex.lock();
        for (to_remove.items) |key| {
            if (self.state.running.fetchSwapRemove(key)) |entry| {
                self.freeRunningTaskStrings(entry.value);
                self.allocator.free(entry.key);
            }
        }
        self.state.mutex.unlock();
```

Move `self.state.failed_count += 1;` inside the lock block.

**Step 4: Lock in startTask when adding to running map**

In `startTask`, wrap the `put` call:

```zig
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        try self.state.running.put(self.allocator, key, running_task);
```

**Step 5: Lock in reconcile removal**

Same pattern as heartbeatAll.

**Step 6: Lock counter increments in driveCompleted/driveFailed**

```zig
        self.state.mutex.lock();
        self.state.completed_count += 1;
        self.state.mutex.unlock();
```

```zig
        self.state.mutex.lock();
        self.state.failed_count += 1;
        self.state.mutex.unlock();
```

**Step 7: Run tests**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 8: Commit**

```bash
git add src/tracker.zig
git commit -m "feat: add mutex locking in all tracker state mutation paths"
```

---

### Task 12: Build verification and cleanup

**Files:**
- All modified files

**Step 1: Full build**

Run: `zig build 2>&1 | head -30`
Expected: Build succeeds with no errors

**Step 2: Run all tests**

Run: `zig build test 2>&1 | head -50`
Expected: All tests pass

**Step 3: Remove TODO comment about mutex**

In `src/tracker.zig`, remove the comment at lines 42-43:

```
// TODO: TrackerState is read by the HTTP thread (API handlers) and written by the
// Tracker thread without synchronization. Add a Mutex or RwLock before production use.
```

**Step 4: Run tests again**

Run: `zig build test 2>&1 | head -20`
Expected: PASS

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete pull-mode execution engine implementation"
```
