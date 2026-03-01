# Advanced Step Types Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add 8 new step types (loop, sub_workflow, wait, router, transform, saga, debate, group_chat), graph cycles, and worker handoff to NullBoiler — achieving full orchestration parity with top vendors.

**Architecture:** Extend the existing engine tick loop with new step handlers. Each new step type follows the same pattern: add enum value to StepType, add handler in engine.zig, add store methods as needed, add tests. Schema changes go in a new migration file (002). New API endpoints for signal and chat transcript.

**Tech Stack:** Zig 0.15.2, SQLite (vendored), existing HTTP server

**Design doc:** `docs/plans/2026-03-01-nullboiler-advanced-step-types-design.md`

---

## Task 1: Schema Migration + Type Extensions

**Files:**
- Create: `src/migrations/002_advanced_steps.sql`
- Modify: `src/types.zig:49-67` (StepType enum)
- Modify: `src/store.zig:61-120` (migration loading)

**Step 1: Create the migration file**

Create `src/migrations/002_advanced_steps.sql`:

```sql
-- Migration 002: Advanced step types support

-- Cycle tracking for graph loops
CREATE TABLE IF NOT EXISTS cycle_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    cycle_key TEXT NOT NULL,
    iteration_count INTEGER NOT NULL DEFAULT 0,
    max_iterations INTEGER NOT NULL DEFAULT 10,
    PRIMARY KEY (run_id, cycle_key)
);

-- Group chat message history
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL REFERENCES steps(id),
    round INTEGER NOT NULL,
    role TEXT NOT NULL,
    worker_id TEXT,
    message TEXT NOT NULL,
    ts_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_step ON chat_messages(step_id, round);

-- Saga compensation state
CREATE TABLE IF NOT EXISTS saga_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    saga_step_id TEXT NOT NULL REFERENCES steps(id),
    body_step_id TEXT NOT NULL,
    compensation_step_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    PRIMARY KEY (run_id, saga_step_id, body_step_id)
);

-- Sub-workflow tracking: link parent step to child run
ALTER TABLE steps ADD COLUMN child_run_id TEXT REFERENCES runs(id);

-- Iteration tracking for loops and cycles
ALTER TABLE steps ADD COLUMN iteration_index INTEGER DEFAULT 0;
```

**Step 2: Add new enum values to StepType**

In `src/types.zig`, extend the `StepType` enum (currently at line 49) to add 8 new values:

```zig
pub const StepType = enum {
    task,
    fan_out,
    map,
    condition,
    approval,
    reduce,
    // Advanced step types
    loop,
    sub_workflow,
    wait,
    router,
    transform,
    saga,
    debate,
    group_chat,

    pub fn toString(self: StepType) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StepType {
        return std.meta.stringToEnum(StepType, s);
    }
};
```

**Step 3: Load the new migration in store.zig**

In `src/store.zig`, after the existing migration execution, add a second `@embedFile` for the new migration:

```zig
const migration_002 = @embedFile("migrations/002_advanced_steps.sql");
```

Execute it the same way as `001_init.sql` — using `sqlite3_exec` with the embedded SQL.

**Step 4: Run tests**

Run: `zig build test`
Expected: All existing 70 tests still pass (schema is additive, no breaking changes).

**Step 5: Commit**

```bash
git add src/migrations/002_advanced_steps.sql src/types.zig src/store.zig
git commit -m "feat: schema migration and type extensions for advanced step types"
```

---

## Task 2: Store Methods for New Tables

**Files:**
- Modify: `src/store.zig`

**Step 1: Add cycle_state CRUD methods**

Add to `src/store.zig`:

```zig
// ── Cycle State ─────────────────────────────────────────────────────

pub fn getCycleState(self: *Self, allocator: std.mem.Allocator, run_id: []const u8, cycle_key: []const u8) !?struct { iteration_count: i64, max_iterations: i64 } {
    // SELECT iteration_count, max_iterations FROM cycle_state WHERE run_id = ? AND cycle_key = ?
}

pub fn upsertCycleState(self: *Self, run_id: []const u8, cycle_key: []const u8, iteration_count: i64, max_iterations: i64) !void {
    // INSERT OR REPLACE INTO cycle_state (run_id, cycle_key, iteration_count, max_iterations) VALUES (?, ?, ?, ?)
}
```

**Step 2: Add chat_messages CRUD methods**

```zig
// ── Chat Messages ───────────────────────────────────────────────────

pub fn insertChatMessage(self: *Self, run_id: []const u8, step_id: []const u8, round: i64, role: []const u8, worker_id: ?[]const u8, message: []const u8) !void {
    // INSERT INTO chat_messages (run_id, step_id, round, role, worker_id, message, ts_ms)
}

pub fn getChatMessages(self: *Self, allocator: std.mem.Allocator, step_id: []const u8) ![]ChatMessageRow {
    // SELECT * FROM chat_messages WHERE step_id = ? ORDER BY round, id
}
```

Add `ChatMessageRow` struct to `src/types.zig`:

```zig
pub const ChatMessageRow = struct {
    id: i64,
    run_id: []const u8,
    step_id: []const u8,
    round: i64,
    role: []const u8,
    worker_id: ?[]const u8,
    message: []const u8,
    ts_ms: i64,
};
```

**Step 3: Add saga_state CRUD methods**

```zig
// ── Saga State ──────────────────────────────────────────────────────

pub fn insertSagaState(self: *Self, run_id: []const u8, saga_step_id: []const u8, body_step_id: []const u8, compensation_step_id: ?[]const u8) !void {
    // INSERT INTO saga_state (run_id, saga_step_id, body_step_id, compensation_step_id, status)
}

pub fn updateSagaState(self: *Self, run_id: []const u8, saga_step_id: []const u8, body_step_id: []const u8, status: []const u8) !void {
    // UPDATE saga_state SET status = ? WHERE run_id = ? AND saga_step_id = ? AND body_step_id = ?
}

pub fn getSagaStates(self: *Self, allocator: std.mem.Allocator, run_id: []const u8, saga_step_id: []const u8) ![]SagaStateRow {
    // SELECT * FROM saga_state WHERE run_id = ? AND saga_step_id = ? ORDER BY rowid
}
```

Add `SagaStateRow` struct to `src/types.zig`:

```zig
pub const SagaStateRow = struct {
    run_id: []const u8,
    saga_step_id: []const u8,
    body_step_id: []const u8,
    compensation_step_id: ?[]const u8,
    status: []const u8,
};
```

**Step 4: Add sub-workflow helper**

```zig
pub fn updateStepChildRunId(self: *Self, step_id: []const u8, child_run_id: []const u8) !void {
    // UPDATE steps SET child_run_id = ? WHERE id = ?
}

pub fn getStepByChildRunId(self: *Self, allocator: std.mem.Allocator, child_run_id: []const u8) !?types.StepRow {
    // SELECT * FROM steps WHERE child_run_id = ?
}
```

**Step 5: Write tests for all new store methods**

Test each method with `:memory:` SQLite and `std.testing.allocator`:
- Insert + get cycle state, upsert behavior
- Insert + get chat messages, ordering by round
- Insert + update + get saga state
- Update + get step child_run_id

**Step 6: Run tests**

Run: `zig build test`
Expected: All tests pass (old + new).

**Step 7: Commit**

```bash
git add src/store.zig src/types.zig
git commit -m "feat: store methods for cycle_state, chat_messages, saga_state"
```

---

## Task 3: `transform` Step Type

The simplest new type — no worker dispatch, pure data transformation.

**Files:**
- Modify: `src/engine.zig`

**Step 1: Write failing test**

Add test in `src/engine.zig`:

```zig
test "transform step renders output_template without worker dispatch" {
    // Create a run with: task -> transform
    // task completes with output "hello"
    // transform has output_template: {"result": "{{steps.task1.output}}"}
    // After tick: transform should be completed with rendered output
}
```

**Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — transform handler not implemented.

**Step 3: Implement executeTransformStep**

In `src/engine.zig`, add handler and wire it into the step type dispatch:

```zig
fn executeTransformStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // 1. Get output_template from workflow_json
    const output_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "output_template");

    // 2. Build template context (same as task)
    const ctx = try buildTemplateContext(alloc, run_row, step, self.store);

    // 3. Render template
    const rendered = try templates.render(alloc, output_template, ctx);

    // 4. Wrap as output and mark completed — no worker dispatch
    const output = try wrapOutput(alloc, rendered);
    try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);

    // 5. Fire callback
    callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, output);
    try self.store.insertEvent(run_row.id, step.id, "step.completed", output);
}
```

Add to the step type dispatch (around line 108):
```zig
} else if (std.mem.eql(u8, step_type, "transform")) {
    try self.executeTransformStep(alloc, run_row, step);
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/engine.zig
git commit -m "feat: transform step type — pure data transformation"
```

---

## Task 4: `wait` Step Type + Signal API

**Files:**
- Modify: `src/engine.zig`
- Modify: `src/api.zig`

**Step 1: Write failing tests**

```zig
test "wait step with duration_ms completes after time elapses" {
    // Create run with wait step: duration_ms = 100
    // First tick: step should be set to "running" with started_at_ms
    // After 100ms + tick: step should be completed with {"waited_ms": N}
}

test "wait step with signal stays waiting until signal received" {
    // Create run with wait step: signal = "deploy"
    // Tick: step should be "waiting_approval" (reusing status for signal wait)
    // Stays waiting across ticks
}
```

**Step 2: Implement executeWaitStep**

```zig
fn executeWaitStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // Check for signal mode
    const signal = getStepField(alloc, run_row.workflow_json, step.def_step_id, "signal") catch null;
    if (signal != null) {
        // Set to waiting_approval (reuse existing status for external signal wait)
        try self.store.updateStepStatus(step.id, "waiting_approval", null, null, null, step.attempt);
        try self.store.insertEvent(run_row.id, step.id, "step.waiting_signal", "{}");
        callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.waiting_signal", run_row.id, step.id, "{}");
        return;
    }

    // Check for duration_ms mode
    const duration_str = getStepField(alloc, run_row.workflow_json, step.def_step_id, "duration_ms") catch null;
    const until_str = getStepField(alloc, run_row.workflow_json, step.def_step_id, "until_ms") catch null;

    const now = ids.nowMs();

    if (duration_str) |d| {
        const duration = std.fmt.parseInt(i64, d, 10) catch 0;
        // If step has started_at_ms, check if duration has elapsed
        if (step.started_at_ms) |started| {
            if (now - started >= duration) {
                const waited = now - started;
                const output = try std.fmt.allocPrint(alloc, "{{\"waited_ms\":{d}}}", .{waited});
                try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
                return;
            }
            // Not yet — stay running
            return;
        }
        // First time seeing this step — mark running with started_at_ms
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        // TODO: set started_at_ms (need store method)
        return;
    }

    if (until_str) |u| {
        const until = std.fmt.parseInt(i64, u, 10) catch 0;
        if (now >= until) {
            const output = try std.fmt.allocPrint(alloc, "{{\"waited_ms\":{d}}}", .{now - (step.started_at_ms orelse now)});
            try self.store.updateStepStatus(step.id, "completed", null, output, null, step.attempt);
            return;
        }
        if (step.started_at_ms == null) {
            try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        }
        return;
    }
}
```

**Step 3: Add signal API endpoint**

In `src/api.zig`, add route for `POST /runs/{id}/steps/{step_id}/signal`:

```zig
fn handleSignalStep(ctx: *Context, run_id: []const u8, step_id: []const u8, body: []const u8) HttpResponse {
    // 1. Get step, verify status is "waiting_approval"
    // 2. Parse body for signal name and data
    // 3. Update step to "completed" with output: {"signal": name, "data": {...}}
    // 4. Insert event "step.signaled"
    // 5. Return 200
}
```

Wire into router alongside approve/reject (around line 74 of api.zig):
```zig
// POST /runs/{id}/steps/{step_id}/signal
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/engine.zig src/api.zig
git commit -m "feat: wait step type with duration, timestamp, and signal modes"
```

---

## Task 5: `router` Step Type

**Files:**
- Modify: `src/engine.zig`

**Step 1: Write failing test**

```zig
test "router step routes to matching target and skips others" {
    // Create run with: classify -> router -> [fix_bug, implement_feature, refactor]
    // classify output contains "bug"
    // Router has routes: {"bug": "fix_bug", "feature": "implement_feature", "refactor": "refactor_code"}
    // After tick: fix_bug should be ready, others skipped
}

test "router step uses default when no match" {
    // classify output contains "unknown"
    // default = "fix_bug"
    // After tick: fix_bug ready, others skipped
}
```

**Step 2: Implement executeRouterStep**

```zig
fn executeRouterStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // 1. Get dependency output (like condition step)
    const deps = try self.store.getStepDeps(alloc, step.id);
    if (deps.len == 0) return;
    const dep_step = try self.store.getStep(alloc, deps[0]);
    const dep_output = extractOutputField(dep_step.output_json orelse "");

    // 2. Parse routes from workflow_json
    // routes is a JSON object: {"key1": "target1", "key2": "target2"}
    const routes_json = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "routes");
    const default_target = getStepField(alloc, run_row.workflow_json, step.def_step_id, "default") catch null;

    // 3. Find matching route (first key that dep_output contains)
    var matched_target: ?[]const u8 = null;
    // Parse routes_json as object, iterate keys
    // For each key: if dep_output contains key -> matched_target = value
    // If no match: matched_target = default_target

    // 4. If matched: skip all other route targets
    const all_steps = try self.store.getStepsByRun(alloc, run_row.id);
    // For each route value that != matched_target: skipStepByDefId
    // Mark self completed with output: {"routed_to": matched_target}

    // 5. If no match and no default: fail
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig
git commit -m "feat: router step type — dynamic N-way routing"
```

---

## Task 6: `loop` Step Type

**Files:**
- Modify: `src/engine.zig`
- Modify: `src/store.zig` (if new queries needed)

**Step 1: Write failing tests**

```zig
test "loop step creates child steps and iterates until exit_condition" {
    // Loop with body: ["code", "test"], max_iterations: 3
    // exit_condition: "steps.test.output contains PASS"
    // First iteration: code completes, test output = "FAIL"
    // Second iteration: code completes, test output = "PASS"
    // Loop should complete after 2 iterations
}

test "loop step stops at max_iterations" {
    // Same setup but exit_condition never matches
    // Should complete after max_iterations with last output
}
```

**Step 2: Implement executeLoopStep**

This is the most complex new handler. The loop step:

1. On first encounter (no children exist): create child steps for body[0] with iteration_index=0
2. Each tick: check if current iteration's body steps are all done
3. If done: evaluate exit_condition against last body step's output
4. If condition met or max_iterations reached: mark loop completed
5. If not: create new child step instances for next iteration (iteration_index++)

```zig
fn executeLoopStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    const max_iterations_str = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "max_iterations");
    const max_iterations = std.fmt.parseInt(i64, max_iterations_str, 10) catch 10;
    const exit_condition = getStepField(alloc, run_row.workflow_json, step.def_step_id, "exit_condition") catch null;
    const body_json = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "body");
    // Parse body as JSON array of step def IDs

    // Get current children
    const children = try self.store.getChildSteps(alloc, step.id);

    if (children.len == 0) {
        // First iteration: create child steps for body[0] with iteration_index=0
        // First body step is "ready", rest are "pending" with deps on previous
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        // Create children...
        return;
    }

    // Find current iteration index (max iteration_index among children)
    var current_iteration: i64 = 0;
    for (children) |child| {
        if (child.iteration_index != null and child.iteration_index.? > current_iteration) {
            current_iteration = child.iteration_index.?;
        }
    }

    // Check if all children in current iteration are terminal
    var all_done = true;
    var last_output: ?[]const u8 = null;
    for (children) |child| {
        if (child.iteration_index != null and child.iteration_index.? == current_iteration) {
            const status = types.StepStatus.fromString(child.status);
            if (status != .completed and status != .failed and status != .skipped) {
                all_done = false;
                break;
            }
            if (status == .failed) {
                // Body step failed -> loop fails
                try self.store.updateStepStatus(step.id, "failed", null, null, child.error_text, step.attempt);
                return;
            }
            last_output = child.output_json;
        }
    }

    if (!all_done) return; // Wait for current iteration

    // Evaluate exit condition
    if (exit_condition) |cond| {
        if (last_output) |out| {
            const output_text = extractOutputField(out);
            if (std.mem.indexOf(u8, output_text, cond) != null) {
                // Condition met — loop complete
                try self.store.updateStepStatus(step.id, "completed", null, last_output, null, step.attempt);
                callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, last_output orelse "{}");
                return;
            }
        }
    }

    // Check max iterations
    if (current_iteration + 1 >= max_iterations) {
        // Max reached — complete with last output
        try self.store.updateStepStatus(step.id, "completed", null, last_output, null, step.attempt);
        return;
    }

    // Start next iteration: create new child steps with iteration_index + 1
    // ... (similar to first iteration creation but with incremented index)
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig src/store.zig
git commit -m "feat: loop step type — iterative repetition with exit condition"
```

---

## Task 7: `sub_workflow` Step Type

**Files:**
- Modify: `src/engine.zig`
- Modify: `src/api.zig` (reuse run creation logic)

**Step 1: Write failing test**

```zig
test "sub_workflow step creates child run and completes when child completes" {
    // Parent run with: task1 -> sub_workflow -> task3
    // sub_workflow has inline workflow with one task step
    // After ticks: sub_workflow should create child run
    // When child run completes: sub_workflow step should complete with child's output
}
```

**Step 2: Implement executeSubWorkflowStep**

```zig
fn executeSubWorkflowStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // Check if child run already exists (step.child_run_id)
    if (step.child_run_id) |child_run_id| {
        // Poll child run status
        const child_run = self.store.getRun(alloc, child_run_id) catch return;
        if (child_run == null) return;

        if (std.mem.eql(u8, child_run.?.status, "completed")) {
            // Get child run's final step output
            const child_steps = try self.store.getStepsByRun(alloc, child_run_id);
            var final_output: ?[]const u8 = null;
            for (child_steps) |cs| {
                if (std.mem.eql(u8, cs.status, "completed")) final_output = cs.output_json;
            }
            try self.store.updateStepStatus(step.id, "completed", null, final_output, null, step.attempt);
            callbacks.fireCallbacks(alloc, run_row.callbacks_json, "step.completed", run_row.id, step.id, final_output orelse "{}");
        } else if (std.mem.eql(u8, child_run.?.status, "failed")) {
            try self.store.updateStepStatus(step.id, "failed", null, null, child_run.?.error_text, step.attempt);
        }
        // Still running — wait
        return;
    }

    // First time: create child run
    // 1. Get nested workflow definition from workflow_json
    // 2. Get input_mapping, render it using parent template context
    // 3. Create new run (insert into runs table) with nested workflow + mapped input
    // 4. Create child run's steps (same logic as handleCreateRun in api.zig)
    // 5. Store child_run_id on the step
    // 6. Mark step as "running"
}
```

**Important:** Extract the step/dep creation logic from `handleCreateRun` in api.zig into a shared function that both the API handler and the engine can call. Put this in a new function like `createRunSteps(store, alloc, run_id, workflow_json, input_json)`.

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig src/api.zig src/store.zig
git commit -m "feat: sub_workflow step type — workflow composition"
```

---

## Task 8: `debate` Step Type

**Files:**
- Modify: `src/engine.zig`

**Step 1: Write failing test**

```zig
test "debate step dispatches to N workers then judge" {
    // Create run with debate step: count=3, worker_tags=["reviewer"], judge_tags=["senior"]
    // Mock: fan_out to 3 children, all complete
    // Then judge step dispatched
    // Output: judge's response
}
```

**Step 2: Implement executeDebateStep**

The debate step is internally implemented as fan_out + reduce, but managed within a single step:

```zig
fn executeDebateStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // Phase 1: Fan out to reviewers (creates children like fan_out)
    const children = try self.store.getChildSteps(alloc, step.id);

    if (children.len == 0) {
        // Create N child task steps for the debate participants
        const count_str = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "count");
        const count = std.fmt.parseInt(i64, count_str, 10) catch 3;
        const prompt_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "prompt_template");

        // Build template context and render prompt
        const ctx = try buildTemplateContext(alloc, run_row, step, self.store);
        const rendered = try templates.render(alloc, prompt_template, ctx);

        // Create child steps
        for (0..@intCast(count)) |i| {
            const child_id = ids.generateId();
            const child_def_id = try std.fmt.allocPrint(alloc, "{s}_participant_{d}", .{step.def_step_id, i});
            try self.store.insertStep(&child_id, run_row.id, child_def_id, "task", "ready", try wrapOutput(alloc, rendered), 1, step.timeout_ms, step.id, @intCast(i));
        }
        try self.store.updateStepStatus(step.id, "running", null, null, null, step.attempt);
        return;
    }

    // Check if all children completed
    var all_done = true;
    var responses = std.ArrayList([]const u8).init(alloc);
    for (children) |child| {
        if (!std.mem.eql(u8, child.status, "completed") and !std.mem.eql(u8, child.status, "skipped")) {
            all_done = false;
            break;
        }
        if (child.output_json) |o| try responses.append(extractOutputField(o));
    }
    if (!all_done) return;

    // Phase 2: Dispatch to judge
    // Check if we already dispatched the judge (look for a child with def_step_id ending in "_judge")
    var judge_done = false;
    for (children) |child| {
        if (std.mem.endsWith(u8, child.def_step_id, "_judge")) {
            if (std.mem.eql(u8, child.status, "completed")) {
                // Judge done — debate complete
                try self.store.updateStepStatus(step.id, "completed", null, child.output_json, null, step.attempt);
                judge_done = true;
            } else if (std.mem.eql(u8, child.status, "failed")) {
                try self.store.updateStepStatus(step.id, "failed", null, null, child.error_text, step.attempt);
                judge_done = true;
            }
            break;
        }
    }
    if (judge_done) return;

    // Create judge child step
    const judge_template = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "judge_template");
    const serialized = try serializeStringArray(alloc, responses.items);
    // Replace {{debate_responses}} in judge_template
    // Create judge child step with rendered template
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig
git commit -m "feat: debate step type — committee voting with judge"
```

---

## Task 9: `group_chat` Step Type + Chat API

**Files:**
- Modify: `src/engine.zig`
- Modify: `src/api.zig` (chat transcript endpoint)

**Step 1: Write failing test**

```zig
test "group_chat step runs multiple rounds until exit_condition" {
    // Create run with group_chat: 2 participants, max_rounds=3, exit_condition="CONSENSUS"
    // Round 1: both participants respond
    // Round 2: one responds with "CONSENSUS REACHED"
    // Step completes with chat transcript
}
```

**Step 2: Implement executeGroupChatStep**

```zig
fn executeGroupChatStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    const max_rounds_str = try getStepField(alloc, run_row.workflow_json, step.def_step_id, "max_rounds");
    const max_rounds = std.fmt.parseInt(i64, max_rounds_str, 10) catch 5;
    const exit_condition = getStepField(alloc, run_row.workflow_json, step.def_step_id, "exit_condition") catch null;

    // Get existing messages for this step
    const messages = try self.store.getChatMessages(alloc, step.id);

    // Determine current round
    var current_round: i64 = 0;
    for (messages) |m| {
        if (m.round > current_round) current_round = m.round;
    }

    // Parse participants from workflow_json
    // participants is an array: [{"tags": [...], "role": "..."}, ...]

    // Check: are all participants' responses in for current_round?
    // If not all responded: dispatch to remaining participants
    // If all responded:
    //   Check exit_condition against responses
    //   If met or current_round >= max_rounds: complete with transcript
    //   Else: start next round with round_template + chat_history

    // For each dispatch: store response in chat_messages table
}
```

**Step 3: Add chat transcript API**

In `src/api.zig`, add `GET /runs/{id}/steps/{step_id}/chat`:

```zig
fn handleGetChatTranscript(ctx: *Context, _: []const u8, step_id: []const u8) HttpResponse {
    const messages = ctx.store.getChatMessages(ctx.allocator, step_id) catch {
        return jsonResponse(ctx.allocator, 500, "{\"error\":\"internal error\"}");
    };
    // Serialize messages to JSON array
    // Return 200 with messages
}
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/engine.zig src/api.zig
git commit -m "feat: group_chat step type — multi-turn deliberation"
```

---

## Task 10: `saga` Step Type

**Files:**
- Modify: `src/engine.zig`

**Step 1: Write failing tests**

```zig
test "saga step executes body sequentially and completes on success" {
    // Saga with body: [provision, deploy, verify]
    // All succeed -> saga completes
}

test "saga step runs compensation in reverse on failure" {
    // Saga with body: [provision, deploy, verify]
    // compensations: {provision: deprovision, deploy: rollback}
    // deploy fails -> runs rollback then deprovision in reverse order
    // saga marks failed with compensation info
}
```

**Step 2: Implement executeSagaStep**

```zig
fn executeSagaStep(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, step: types.StepRow) !void {
    // Parse body and compensations from workflow_json
    // Get saga state from saga_state table

    // If no saga state exists: initialize
    //   Create saga_state entries for each body step
    //   Create first body step as child, mark "ready"
    //   Mark saga "running"

    // Check current state:
    //   If in forward mode:
    //     If current body step completed: advance to next, or complete saga if all done
    //     If current body step failed: enter compensation mode
    //   If in compensation mode:
    //     Run compensation steps in reverse order for completed body steps
    //     When all compensations done: mark saga failed with compensation report

    // Output on failure: {"failed_at": "deploy", "compensated": ["deploy", "provision"]}
    // Output on success: last body step's output
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig
git commit -m "feat: saga step type — ordered compensation on failure"
```

---

## Task 11: Graph Cycles Support

**Files:**
- Modify: `src/engine.zig`
- Modify: `src/api.zig` (cycle detection at run creation)

**Step 1: Write failing tests**

```zig
test "graph cycle: condition routes back to earlier step, creates new instances" {
    // code -> test -> check(condition) -> code (cycle) or done
    // First iteration: test output = "FAIL", check routes back to code
    // Engine creates new step instances for code, test, check
    // Second iteration: test output = "PASS", check routes to done
    // Run completes
}

test "graph cycle respects max_cycle_iterations" {
    // Same setup but test always returns "FAIL"
    // max_cycle_iterations = 3
    // Run fails after 3 iterations with "cycle limit exceeded"
}
```

**Step 2: Implement cycle detection in condition/router steps**

When `condition` or `router` step routes to an already-completed step (backward edge):

```zig
// In executeConditionStep / executeRouterStep:
// After determining target:
//   If target step already has status "completed" or "skipped":
//     This is a cycle! Check cycle_state table
//     If iteration_count >= max_iterations: fail run
//     Else: create new step instances for the cycle body, increment cycle iteration
```

**Step 3: Add cycle detection helper**

```zig
fn handleCycleBack(self: *Engine, alloc: std.mem.Allocator, run_row: types.RunRow, target_def_id: []const u8, all_steps: []types.StepRow) !bool {
    // 1. Check if target step is already completed
    // 2. If so: build cycle_key from the path
    // 3. Check/update cycle_state in DB
    // 4. Create new step instances for the cycle body
    // 5. Return true if cycle was handled
}
```

**Step 4: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 5: Commit**

```bash
git add src/engine.zig src/api.zig src/store.zig
git commit -m "feat: graph cycle support with iteration limits"
```

---

## Task 12: Worker Handoff

**Files:**
- Modify: `src/engine.zig`

**Step 1: Write failing test**

```zig
test "worker handoff re-dispatches to different worker" {
    // Task step dispatched to worker A
    // Worker A responds with: {"output": "...", "handoff_to": {"tags": ["specialist"], "message": "..."}}
    // Engine re-dispatches to worker matching ["specialist"]
    // Final output is from worker B
}

test "worker handoff chain limit" {
    // Each worker keeps handing off
    // After 5 handoffs: step fails with "handoff chain limit exceeded"
}
```

**Step 2: Extend task step dispatch to detect handoff**

In `executeTaskStep`, after receiving `DispatchResult`:

```zig
// After successful dispatch:
// Parse result.output as JSON
// Check for "handoff_to" field
// If present:
//   Extract tags and message
//   Check handoff_count (stored in step metadata or error_text field)
//   If handoff_count >= 5: fail step
//   Else: select new worker by tags, dispatch with handoff message
//   Store intermediate output as event
//   Loop or recurse (bounded by chain limit)
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/engine.zig
git commit -m "feat: worker handoff — agent-to-agent transfer"
```

---

## Task 13: Wire New Step Types into API Router

**Files:**
- Modify: `src/api.zig`

**Step 1: Update handleCreateRun**

The `handleCreateRun` function already parses step types from workflow JSON. Ensure the new step types are accepted (no validation rejection). The engine handles them in the tick loop.

Additional validation to add:
- `loop` must have `body` and `max_iterations`
- `sub_workflow` must have `workflow`
- `wait` must have one of `duration_ms`, `until_ms`, or `signal`
- `router` must have `routes`
- `saga` must have `body`
- `debate` must have `count` and `judge_template`
- `group_chat` must have `participants` and `max_rounds`

**Step 2: Add signal and chat routes to router**

In the `handleRequest` function, add:
```
POST /runs/{id}/steps/{step_id}/signal -> handleSignalStep
GET /runs/{id}/steps/{step_id}/chat -> handleGetChatTranscript
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/api.zig
git commit -m "feat: API routing for new step types, signal, and chat endpoints"
```

---

## Task 14: Template Extensions

**Files:**
- Modify: `src/templates.zig`

**Step 1: Add new template expressions**

Add support for:
- `{{debate_responses}}` — array of debate participant responses
- `{{chat_history}}` — formatted chat transcript
- `{{role}}` — current participant's role in group_chat

These are additional context fields passed via the existing `Context` struct. Extend `Context` with optional fields:

```zig
pub const Context = struct {
    input_json: []const u8,
    step_outputs: []const StepOutput,
    item: ?[]const u8,
    // New fields:
    debate_responses: ?[]const u8,  // JSON array string
    chat_history: ?[]const u8,      // formatted chat transcript
    role: ?[]const u8,              // group_chat participant role
};
```

Update `render()` to resolve these new expressions.

**Step 2: Write tests for new expressions**

```zig
test "render debate_responses expression" {
    // template: "Pick best:\n{{debate_responses}}"
    // ctx.debate_responses = "[\"resp1\", \"resp2\"]"
    // Expected: "Pick best:\n[\"resp1\", \"resp2\"]"
}

test "render chat_history expression" {
    // template: "Previous:\n{{chat_history}}\nYour role: {{role}}"
    // ctx.chat_history = "Architect: ...\nSecurity: ..."
    // ctx.role = "Frontend Dev"
}
```

**Step 3: Run tests**

Run: `zig build test`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add src/templates.zig
git commit -m "feat: template expressions for debate_responses, chat_history, role"
```

---

## Task 15: E2E Tests for New Step Types

**Files:**
- Modify: `tests/test_e2e.sh`
- Modify: `tests/mock_worker.py` (if needed)

**Step 1: Add transform step test**

```bash
# Submit workflow: task -> transform
# Verify transform step completes with rendered output
```

**Step 2: Add wait step test**

```bash
# Submit workflow with wait step: duration_ms = 500
# Poll until run completes (should take ~500ms)
# Verify step output has waited_ms field
```

**Step 3: Add router step test**

```bash
# Submit: classify -> router -> [target_a, target_b]
# Verify correct routing
```

**Step 4: Add signal step test**

```bash
# Submit workflow with wait signal step
# POST signal to the step
# Verify run completes
```

**Step 5: Add loop step test (with mock workers)**

```bash
# Submit loop workflow with mock worker
# Verify multiple iterations
```

**Step 6: Run all tests**

Run: `zig build && bash tests/test_e2e.sh`
Expected: All tests pass.

**Step 7: Commit**

```bash
git add tests/test_e2e.sh tests/mock_worker.py
git commit -m "test: e2e tests for advanced step types"
```

---

## Task 16: Update Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `config.example.json` (if new config fields)

**Step 1: Update CLAUDE.md**

Add the 8 new step types to the step types section. Update the module map if any new files were created. Add notes about graph cycles and worker handoff.

**Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with advanced step types"
```

---

## Dependency Graph

```
Task 1 (schema + types)
  +-- Task 2 (store methods)
       +-- Task 3 (transform)
       +-- Task 4 (wait + signal API)
       +-- Task 5 (router)
       +-- Task 6 (loop)
       +-- Task 7 (sub_workflow)
       +-- Task 8 (debate)
       +-- Task 9 (group_chat + chat API)
       +-- Task 10 (saga)
       +-- Task 11 (graph cycles)
       +-- Task 12 (worker handoff)
  +-- Task 13 (API router wiring) — depends on 3-12
  +-- Task 14 (template extensions) — depends on 8, 9
  +-- Task 15 (e2e tests) — depends on 13, 14
  +-- Task 16 (docs) — depends on 15
```

## Critical Path

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15 → 16

Tasks 3-12 can run in parallel after Task 2 (they're independent step type implementations). Task 13 depends on all of them. Task 14 depends on 8+9. Task 15 depends on 13+14.

## Parallelization Opportunities

After Task 2, these groups can run in parallel:
- **Group A:** Tasks 3, 4, 5 (simpler: transform, wait, router)
- **Group B:** Tasks 6, 7 (medium: loop, sub_workflow)
- **Group C:** Tasks 8, 9 (medium: debate, group_chat)
- **Group D:** Tasks 10, 11, 12 (complex: saga, cycles, handoff)
