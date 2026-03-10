# Symphony Port Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port key OpenAI Symphony orchestrator features into NullBoiler's Zig architecture.

**Architecture:** Extend existing template engine with conditional blocks, enhance tracker's multi-turn continuation with per-workflow prompts and template rendering, add per-state concurrency as 4th axis, startup workspace cleanup, retry-with-backoff semantics, and 4 quality example workflow files adapted from Symphony's prompts. Priority-based task sorting is NullTickets server-side responsibility (claim API returns one task at a time).

**Tech Stack:** Zig 0.15.2, SQLite (existing), NullClaw subprocess protocol (existing)

**Spec:** `docs/superpowers/specs/2026-03-09-symphony-port-design.md`

---

## Chunk 1: Template Engine — Conditional Blocks

### Task 1: Add `attempt` field to template Context

**Files:**
- Modify: `src/templates.zig:16-30` (Context struct)
- Modify: `src/templates.zig:84-131` (resolveExpression)

- [ ] **Step 1: Write failing test for `attempt` variable rendering**

Add to end of test block in `src/templates.zig`:

```zig
test "render attempt variable" {
    const allocator = std.testing.allocator;
    const template = "Attempt: {{attempt}}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Attempt: 3", result);
}

test "render attempt variable when null" {
    const allocator = std.testing.allocator;
    const template = "Attempt: {{attempt}}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Attempt: ", result);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -A 2 "attempt"`
Expected: Compilation error — `attempt` field not found in Context

- [ ] **Step 3: Add `attempt` field to Context and resolve it**

In `src/templates.zig`, add field to Context struct (after `task_json`):

```zig
attempt: ?u32 = null,
```

In `resolveExpression`, add handling before the `input.` check (around line 113):

```zig
if (std.mem.eql(u8, expression, "attempt")) {
    if (ctx.attempt) |a| {
        return std.fmt.allocPrint(allocator, "{d}", .{a}) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, "") catch return error.OutOfMemory;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep -E "(attempt|PASS|FAIL)"`
Expected: Both `attempt` tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/templates.zig
git commit -m "feat(templates): add attempt variable to template context"
```

---

### Task 2: Add conditional block parsing to template engine

**Files:**
- Modify: `src/templates.zig:46-80` (render function)

The conditional block syntax is `{% if <expr> %}...{% else %}...{% endif %}`. Processing happens BEFORE `{{expression}}` substitution. The parser strips/keeps blocks based on truthiness, then the existing expression renderer handles `{{}}`.

- [ ] **Step 1: Write failing tests for conditional blocks**

Add to end of test block in `src/templates.zig`:

```zig
test "conditional block with truthy value" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry #{{attempt}}{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Retry #3", result);
}

test "conditional block with falsy value strips content" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry #{{attempt}}{% endif %}Done";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Done", result);
}

test "conditional block with else branch" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry{% else %}First run{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("First run", result);
}

test "conditional block with task.description truthy" {
    const allocator = std.testing.allocator;
    const template = "{% if task.description %}Desc: {{task.description}}{% else %}No description{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{\"description\": \"Fix bug\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Desc: Fix bug", result);
}

test "conditional block with task.description falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if task.description %}Desc: {{task.description}}{% else %}No description{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .task_json = "{}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("No description", result);
}

test "nested conditional blocks" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Retry{% if task.description %}: {{task.description}}{% endif %}{% else %}New{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 2,
        .task_json = "{\"description\": \"Fix it\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Retry: Fix it", result);
}

test "conditional block with false string is falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if input.enabled %}ON{% else %}OFF{% endif %}";
    const ctx = Context{
        .input_json = "{\"enabled\": false}",
        .step_outputs = &.{},
        .item = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("OFF", result);
}

test "conditional block with null string is falsy" {
    const allocator = std.testing.allocator;
    const template = "{% if input.val %}YES{% else %}NO{% endif %}";
    const ctx = Context{
        .input_json = "{\"val\": null}",
        .step_outputs = &.{},
        .item = null,
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("NO", result);
}

test "multiple consecutive conditional blocks" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}A{% endif %}{% if task.title %}B{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 1,
        .task_json = "{\"title\": \"x\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("AB", result);
}

test "unterminated conditional block returns error" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}content";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 3,
    };
    const result = render(allocator, template, ctx);
    try std.testing.expectError(error.UnterminatedExpression, result);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "(conditional|PASS|FAIL)"`
Expected: FAIL — `{% if` not parsed, literal text returned

- [ ] **Step 3: Implement conditional block preprocessing**

Add a new function `processConditionals` in `src/templates.zig` before the `render` function. Then modify `render` to call it first.

Add new error variant to `RenderError`:
```zig
pub const RenderError = error{
    UnterminatedExpression,
    UnknownExpression,
    InputFieldNotFound,
    StepNotFound,
    ItemNotAvailable,
    InvalidInputJson,
    OutOfMemory,
};
```

Add new function before `render`:

```zig
/// Evaluate whether an expression is truthy in the given context.
/// Truthy = resolves to non-null, non-empty, non-"false", non-"null" value.
fn isTruthy(allocator: std.mem.Allocator, expression: []const u8, ctx: Context) bool {
    const value = resolveExpression(allocator, expression, ctx) catch return false;
    defer allocator.free(value);
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "null")) return false;
    return true;
}

/// Process {% if expr %}...{% else %}...{% endif %} blocks recursively.
/// Returns the template with conditional blocks resolved (stripped or kept).
fn processConditionals(allocator: std.mem.Allocator, template: []const u8, ctx: Context) RenderError![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var pos: usize = 0;
    while (pos < template.len) {
        // Find next {% if
        if (std.mem.indexOfPos(u8, template, pos, "{%")) |tag_start| {
            // Append literal text before the tag
            result.appendSlice(allocator, template[pos..tag_start]) catch return error.OutOfMemory;

            // Find closing %}
            const tag_end_marker = std.mem.indexOfPos(u8, template, tag_start + 2, "%}") orelse
                return error.UnterminatedExpression;
            const tag_end = tag_end_marker + 2;

            // Extract tag content and trim
            const tag_content = std.mem.trim(u8, template[tag_start + 2 .. tag_end_marker], " \t\n\r");

            if (std.mem.startsWith(u8, tag_content, "if ")) {
                const expression = std.mem.trim(u8, tag_content[3..], " \t\n\r");

                // Find matching {% else %} and {% endif %}, respecting nesting
                var depth: usize = 1;
                var scan = tag_end;
                var else_pos: ?usize = null;
                var endif_pos: ?usize = null;
                var endif_end: usize = undefined;

                while (scan < template.len) {
                    if (std.mem.indexOfPos(u8, template, scan, "{%")) |inner_tag| {
                        const inner_end_marker = std.mem.indexOfPos(u8, template, inner_tag + 2, "%}") orelse
                            return error.UnterminatedExpression;
                        const inner_end = inner_end_marker + 2;
                        const inner_content = std.mem.trim(u8, template[inner_tag + 2 .. inner_end_marker], " \t\n\r");

                        if (std.mem.startsWith(u8, inner_content, "if ")) {
                            depth += 1;
                        } else if (std.mem.eql(u8, inner_content, "endif")) {
                            depth -= 1;
                            if (depth == 0) {
                                endif_pos = inner_tag;
                                endif_end = inner_end;
                                break;
                            }
                        } else if (std.mem.eql(u8, inner_content, "else") and depth == 1) {
                            else_pos = inner_tag;
                        }
                        scan = inner_end;
                    } else {
                        break;
                    }
                }

                if (endif_pos == null) return error.UnterminatedExpression;

                const truthy = isTruthy(allocator, expression, ctx);

                if (truthy) {
                    // Keep the if-branch content
                    const if_content = if (else_pos) |ep|
                        template[tag_end..ep]
                    else
                        template[tag_end..endif_pos.?];
                    // Recursively process nested conditionals
                    const processed = try processConditionals(allocator, if_content, ctx);
                    defer allocator.free(processed);
                    result.appendSlice(allocator, processed) catch return error.OutOfMemory;
                } else {
                    // Keep the else-branch content (if any)
                    if (else_pos) |ep| {
                        const else_tag_end_marker = std.mem.indexOfPos(u8, template, ep + 2, "%}") orelse
                            return error.UnterminatedExpression;
                        const else_tag_end = else_tag_end_marker + 2;
                        const else_content = template[else_tag_end..endif_pos.?];
                        const processed = try processConditionals(allocator, else_content, ctx);
                        defer allocator.free(processed);
                        result.appendSlice(allocator, processed) catch return error.OutOfMemory;
                    }
                    // No else branch = strip everything
                }

                pos = endif_end;
            } else {
                // Unknown tag, keep as literal
                result.appendSlice(allocator, template[tag_start..tag_end]) catch return error.OutOfMemory;
                pos = tag_end;
            }
        } else {
            // No more tags, append rest
            result.appendSlice(allocator, template[pos..]) catch return error.OutOfMemory;
            break;
        }
    }

    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}
```

Modify the `render` function to preprocess conditionals first:

```zig
pub fn render(allocator: std.mem.Allocator, template: []const u8, ctx: Context) RenderError![]const u8 {
    // Phase 1: Process conditional blocks
    const preprocessed = try processConditionals(allocator, template, ctx);
    defer allocator.free(preprocessed);

    // Phase 2: Resolve {{expression}} substitutions (existing code)
    // Change the existing loop to operate on `preprocessed` instead of `template`
    // All ArrayList usage must use std.ArrayListUnmanaged(u8) = .empty pattern
    // with allocator passed to appendSlice(allocator, ...) and toOwnedSlice(allocator)
```

The existing loop body stays the same but iterates over `preprocessed` instead of `template`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | grep -c "PASS"`
Expected: All template tests pass including new conditional tests

- [ ] **Step 5: Commit**

```bash
git add src/templates.zig
git commit -m "feat(templates): add conditional block support (if/else/endif)"
```

---

## Chunk 2: Per-Workflow Continuation Prompts & Template-Rendered Continuations

### Task 3: Add `continuation_prompt` to WorkflowDef's SubprocessConfig

**Files:**
- Modify: `src/workflow_loader.zig:10-15` (SubprocessConfig struct)

- [ ] **Step 1: Write failing test for continuation_prompt parsing**

Add test in `src/workflow_loader.zig`:

```zig
test "parse workflow with continuation_prompt" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "id": "test-wf",
        \\  "pipeline_id": "pipeline-test",
        \\  "claim_roles": ["dev"],
        \\  "execution": "subprocess",
        \\  "subprocess": {
        \\    "command": "nullclaw",
        \\    "max_turns": 10,
        \\    "continuation_prompt": "Continue: attempt #{{attempt}}"
        \\  },
        \\  "prompt_template": "Do {{task.title}}"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(WorkflowDef, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Continue: attempt #{{attempt}}", parsed.value.subprocess.continuation_prompt.?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "continuation_prompt"`
Expected: Compilation error — field not found

- [ ] **Step 3: Add `continuation_prompt` field to SubprocessConfig**

In `src/workflow_loader.zig` SubprocessConfig struct (line 10-15), add:

```zig
continuation_prompt: ?[]const u8 = null,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep "continuation_prompt"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/workflow_loader.zig
git commit -m "feat(workflow): add continuation_prompt to SubprocessConfig"
```

---

### Task 4: Use per-workflow continuation_prompt and template-render it with `attempt`

**Files:**
- Modify: `src/tracker.zig:730-817` (driveRunning function)

- [ ] **Step 1: Write failing test for per-workflow continuation prompt usage**

This is an integration behavior — test via the template rendering path. Add test in `src/templates.zig`:

```zig
test "render continuation prompt with attempt" {
    const allocator = std.testing.allocator;
    const template = "{% if attempt %}Continuation: retry #{{attempt}}. Resume from current state.{% else %}First run. {{task.title}}{% endif %}";
    const ctx = Context{
        .input_json = "{}",
        .step_outputs = &.{},
        .item = null,
        .attempt = 2,
        .task_json = "{\"title\": \"Fix login\"}",
    };
    const result = try render(allocator, template, ctx);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("Continuation: retry #2. Resume from current state.", result);
}
```

- [ ] **Step 2: Run test to verify it passes** (should pass with Task 1+2 changes)

Run: `zig build test 2>&1 | grep "continuation prompt"`
Expected: PASS

- [ ] **Step 3: Modify driveRunning to use per-workflow continuation_prompt and template-render it**

In `src/tracker.zig`, modify `driveRunning` (line 730-817). Replace the prompt resolution block (lines 742-766):

```zig
// Render prompt
const workflow = self.workflows.get(task.pipeline_id) orelse {
    log.err("no workflow for pipeline {s}", .{task.pipeline_id});
    task.state = .failed;
    return;
};

const prompt: ?[]const u8 = if (task.current_turn == 0) blk: {
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
        .attempt = null,
    };
    break :blk templates.render(tick_alloc, tmpl, ctx) catch |err| {
        log.err("template render failed for task {s}: {s}", .{ task.task_id, @errorName(err) });
        task.state = .failed;
        break :blk null;
    };
} else blk: {
    // Continuation turn: use per-workflow prompt, fall back to global default
    const cont_tmpl = workflow.subprocess.continuation_prompt orelse self.cfg.subprocess.continuation_prompt;
    const ctx = templates.Context{
        .input_json = task.task_json,
        .step_outputs = &.{},
        .item = null,
        .task_json = task.task_json,
        .attempt = task.current_turn,
    };
    break :blk templates.render(tick_alloc, cont_tmpl, ctx) catch |err| {
        log.err("continuation template render failed for task {s}: {s}", .{ task.task_id, @errorName(err) });
        task.state = .failed;
        break :blk null;
    };
};
```

Key changes:
1. Workflow lookup moved before the if/else (needed by both branches)
2. First turn: `attempt = null`
3. Continuation turn: uses `workflow.subprocess.continuation_prompt` with fallback to `self.cfg.subprocess.continuation_prompt`
4. Continuation prompt is now template-rendered (was raw string before)
5. `attempt` set to `task.current_turn` for continuation turns

- [ ] **Step 4: Run all tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add src/tracker.zig src/templates.zig
git commit -m "feat(tracker): template-render continuation prompts with attempt variable"
```

---

## Chunk 3: Per-State Concurrency Limits

### Task 5: Add `per_state` to ConcurrencyConfig

**Files:**
- Modify: `src/config.zig:31-35` (ConcurrencyConfig struct)

- [ ] **Step 1: Write failing test**

Add test in `src/config.zig`:

```zig
test "parse concurrency config with per_state" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "max_concurrent_tasks": 10,
        \\  "per_state": {"in_progress": 5, "rework": 2}
        \\}
    ;
    const parsed = try std.json.parseFromSlice(ConcurrencyConfig, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.per_state != null);
    try std.testing.expect(parsed.value.per_state.? == .object);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "per_state"`
Expected: Compilation error — field not found

- [ ] **Step 3: Add `per_state` field**

In `src/config.zig` ConcurrencyConfig (line 31-35), add after `per_role`:

```zig
per_state: ?std.json.Value = null,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep "per_state"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): add per_state concurrency limit field"
```

---

### Task 6: Add `countByState` to TrackerState and enforce in `canClaimMore`

**Files:**
- Modify: `src/tracker.zig:27-47` (RunningTask — needs `task_state` field)
- Modify: `src/tracker.zig:51-119` (TrackerState — add countByState)
- Modify: `src/tracker.zig:123-163` (canClaimMore — add per_state check)

- [ ] **Step 1: Write failing tests**

Add tests in `src/tracker.zig`:

```zig
test "TrackerState countByState" {
    var state = TrackerState.init();
    defer state.deinit(std.testing.allocator);

    // Insert a task with task_state "in_progress"
    var task1 = makeTestRunningTask("task-001", "pipeline-a", "coder");
    task1.task_state = "in_progress";
    state.running.putNoClobber(std.testing.allocator, try std.testing.allocator.dupe(u8, "task-001"), task1) catch unreachable;

    try std.testing.expectEqual(@as(u32, 1), state.countByState("in_progress"));
    try std.testing.expectEqual(@as(u32, 0), state.countByState("rework"));

    // Cleanup
    const entry = state.running.fetchSwapRemove("task-001").?;
    std.testing.allocator.free(entry.key);
}

test "canClaimMore respects per_state limit" {
    var state = TrackerState.init();
    defer state.deinit(std.testing.allocator);

    // Insert task in "in_progress" state
    var task1 = makeTestRunningTask("task-001", "pipeline-a", "coder");
    task1.task_state = "in_progress";
    state.running.putNoClobber(std.testing.allocator, try std.testing.allocator.dupe(u8, "task-001"), task1) catch unreachable;
    defer {
        const entry = state.running.fetchSwapRemove("task-001").?;
        std.testing.allocator.free(entry.key);
    }

    // per_state limit: in_progress=1
    const per_state_json = "{\"in_progress\": 1}";
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, per_state_json, .{});
    defer parsed.deinit();

    const concurrency = config.ConcurrencyConfig{
        .max_concurrent_tasks = 10,
        .per_state = parsed.value,
    };

    // Should reject — 1 task in "in_progress" already, limit is 1
    try std.testing.expect(!canClaimMore(&state, concurrency, "pipeline-b", "dev", "in_progress"));
    // Different state should be fine
    try std.testing.expect(canClaimMore(&state, concurrency, "pipeline-b", "dev", "rework"));
}
```

Note: `canClaimMore` signature needs a new `task_state` parameter. Also need a helper `makeTestRunningTask` if not already present — reuse the pattern from existing tests (lines 1116-1198).

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | grep -E "(countByState|per_state)"`
Expected: Compilation errors

- [ ] **Step 3: Add `task_state` field to RunningTask**

In `src/tracker.zig` RunningTask struct (line 27-47), add after `task_identifier`:

```zig
task_state: []const u8,
```

> **Clarification:** `task_identifier` stores the NullTickets stage name at claim time (used for external transition detection in `driveRunning`). `task_state` is the same value but used specifically for per-state concurrency counting. They are set from the same source (`claim.task.stage`) but serve different purposes — `task_identifier` is used for change detection, `task_state` is used for concurrency limit checks.

Update all places that construct RunningTask (in `startTask`, around line 486) to include `task_state` from the claim response (`claim.task.stage`). Also update `freeRunningTaskStrings` to free it.

- [ ] **Step 4: Add `countByState` method to TrackerState**

After `countByRole` (line 105-113):

```zig
pub fn countByState(self: *const TrackerState, state_name: []const u8) u32 {
    var count: u32 = 0;
    for (self.running.values()) |task| {
        if (std.mem.eql(u8, task.task_state, state_name)) count += 1;
    }
    return count;
}
```

- [ ] **Step 5: Modify `canClaimMore` to accept `task_state` and check `per_state`**

Change signature at line 123:

```zig
pub fn canClaimMore(state: *const TrackerState, concurrency: config.ConcurrencyConfig, pipeline_id: []const u8, role: []const u8, task_state: []const u8) bool {
```

Add per_state check after per_role check (around line 160):

```zig
if (concurrency.per_state) |ps| {
    if (ps == .object) {
        if (ps.object.get(task_state)) |limit_val| {
            if (limit_val == .integer) {
                const limit: u32 = @intCast(limit_val.integer);
                if (state.countByState(task_state) >= limit) return false;
            }
        }
    }
}
```

- [ ] **Step 6: Update all call sites of `canClaimMore`**

In `pollAndClaim` (around line 370), pass the task's state from the NullTickets response:

```zig
if (!canClaimMore(&self.state, self.cfg.concurrency, pipeline_id, role, task_stage)) continue;
```

Where `task_stage` comes from the candidate task's current stage field.

- [ ] **Step 7: Run all tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/tracker.zig src/config.zig
git commit -m "feat(tracker): add per-state concurrency limits (4th axis)"
```

---

## Chunk 4: Startup Workspace Cleanup & Retry Semantics

> **Note on priority sorting:** The NullTickets claim API (`/leases/claim`) returns one task at a time — priority-based selection is a server-side NullTickets responsibility. NullBoiler's `TaskInfo` already has a `priority` field for downstream use, but sorting candidates client-side is not applicable to the current claim-based architecture.

### Task 7: Add `cleanAll` to workspace.zig

**Files:**
- Modify: `src/workspace.zig` (add cleanAll function)

- [ ] **Step 1: Write failing test**

Add test in `src/workspace.zig`:

```zig
test "cleanAll removes all subdirectories" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // Create some fake workspace dirs
    try tmp.dir.makeDir("task-001");
    try tmp.dir.makeDir("task-002");

    cleanAll(root);

    // Verify they're gone
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir("task-001", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir("task-002", .{}));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "cleanAll"`
Expected: Compilation error — function not found

- [ ] **Step 3: Implement `cleanAll`**

Add in `src/workspace.zig` after the `remove` function:

```zig
/// Remove all subdirectories under the workspace root.
/// Used for startup cleanup — workspaces are ephemeral and will be recreated by hooks.
pub fn cleanAll(root: []const u8) void {
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        log.warn("workspace: cannot open root {s} for cleanup: {}", .{ root, err });
        return;
    };
    defer dir.close();

    var iter = dir.iterate();
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (names.items) |name| std.heap.page_allocator.free(@constCast(name));
        names.deinit(std.heap.page_allocator);
    }

    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            names.append(std.heap.page_allocator, std.heap.page_allocator.dupe(u8, entry.name) catch continue) catch continue;
        }
    }

    for (names.items) |name| {
        dir.deleteTree(name) catch |err| {
            log.warn("workspace: failed to clean {s}/{s}: {}", .{ root, name, err });
            continue;
        };
        log.info("workspace: cleaned up {s}/{s}", .{ root, name });
    }

    if (names.items.len > 0) {
        log.info("workspace: startup cleanup removed {d} workspace(s)", .{names.items.len});
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep "cleanAll"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/workspace.zig
git commit -m "feat(workspace): add cleanAll for startup cleanup"
```

---

### Task 8: Call cleanAll on tracker thread startup

**Files:**
- Modify: `src/tracker.zig:235-257` (run function, before first tick)

- [ ] **Step 1: Add cleanAll call at start of tracker `run()`**

In `src/tracker.zig`, at the beginning of the `run()` function (line 235), after the log message but before the main loop, add:

```zig
// Startup cleanup: remove all stale workspaces from previous run
workspace_mod.cleanAll(self.cfg.workspace.root);
```

Make sure `workspace` module is imported. Check existing imports at top of file — if `workspace` is already imported as `workspace_mod`, use that. Otherwise add the import.

- [ ] **Step 2: Run all tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add src/tracker.zig
git commit -m "feat(tracker): clean all workspaces on startup"
```

---

### Task 9: Add retry semantics to workflow definitions and tracker

**Files:**
- Modify: `src/workflow_loader.zig:22-36` (add RetryConfig, extend WorkflowDef and TransitionConfig)
- Modify: `src/tracker.zig:1000-1025` (driveFailed — implement retry with backoff)

- [ ] **Step 1: Write failing test for RetryConfig parsing**

Add test in `src/workflow_loader.zig`:

```zig
test "parse workflow with retry config" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "id": "retry-wf",
        \\  "pipeline_id": "pipeline-retry",
        \\  "claim_roles": ["dev"],
        \\  "execution": "subprocess",
        \\  "retry": {
        \\    "max_attempts": 3,
        \\    "backoff_base_ms": 10000,
        \\    "backoff_max_ms": 300000
        \\  },
        \\  "on_failure": {
        \\    "transition_to": "failed",
        \\    "retry": true
        \\  }
        \\}
    ;
    const parsed = try std.json.parseFromSlice(WorkflowDef, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.retry != null);
    try std.testing.expectEqual(@as(u32, 3), parsed.value.retry.?.max_attempts);
    try std.testing.expect(parsed.value.on_failure.retry);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep "retry config"`
Expected: Compilation error

- [ ] **Step 3: Add RetryConfig struct and extend WorkflowDef/TransitionConfig**

In `src/workflow_loader.zig`:

Add new struct after TransitionConfig:

```zig
pub const RetryConfig = struct {
    max_attempts: u32 = 3,
    backoff_base_ms: u32 = 10000,
    backoff_max_ms: u32 = 300000,
};
```

Add `retry` field to TransitionConfig:

```zig
pub const TransitionConfig = struct {
    transition_to: []const u8 = "",
    retry: bool = false,
};
```

Add `retry` field to WorkflowDef (after `on_failure`):

```zig
retry: ?RetryConfig = null,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | grep "retry config"`
Expected: PASS

- [ ] **Step 5: Change cooldowns to CooldownEntry for attempt tracking**

In `src/tracker.zig`, change the cooldowns type. Replace `i64` with `CooldownEntry`:

```zig
pub const CooldownEntry = struct {
    expires_at: i64,
    attempt_count: u32,
};
```

Change `TrackerState`:
```zig
cooldowns: std.StringArrayHashMapUnmanaged(CooldownEntry),
```

Update `isInCooldown`:
```zig
pub fn isInCooldown(self: *const TrackerState, task_id: []const u8) bool {
    const entry = self.cooldowns.get(task_id) orelse return false;
    return ids.nowMs() < entry.expires_at;
}
```

Add `getAttemptCount`:
```zig
pub fn getAttemptCount(self: *const TrackerState, task_id: []const u8) u32 {
    const entry = self.cooldowns.get(task_id) orelse return 1;
    return entry.attempt_count;
}
```

Update `cleanCooldowns` to check `entry.expires_at` instead of the raw value.

Update `startTask` to set `attempt_count` from cooldowns:
```zig
// In startTask, when creating RunningTask:
.attempt_count = self.state.getAttemptCount(claim.task.id),
```

- [ ] **Step 6: Add `attempt_count` to RunningTask**

In `src/tracker.zig` RunningTask struct, add:

```zig
attempt_count: u32 = 1,
```

- [ ] **Step 7: Implement retry logic in driveFailed**

Modify `driveFailed` in `src/tracker.zig` (line 1000-1025). Before transitioning to failed, check if retry is configured:

```zig
fn driveFailed(self: *Tracker, tick_alloc: std.mem.Allocator, task: *RunningTask) void {
    const workflow = self.workflows.get(task.pipeline_id);

    // Check if retry is configured
    if (workflow) |wf| {
        if (wf.on_failure.retry) {
            const retry_cfg = wf.retry orelse workflow_loader.RetryConfig{};
            if (task.attempt_count < retry_cfg.max_attempts) {
                // Calculate backoff: min(base * 2^(attempt-1), max)
                const shift: u5 = @intCast(@min(task.attempt_count - 1, 20));
                const backoff: u32 = @min(retry_cfg.backoff_base_ms << shift, retry_cfg.backoff_max_ms);
                const cooldown_until = ids.nowMs() + @as(i64, backoff);

                // Kill subprocess and release port
                if (task.subprocess) |*sub| {
                    subprocess_mod.killSubprocess(&sub.child.?);
                    self.releasePort(sub.port);
                }
                // Remove workspace
                var ws = workspace_mod.Workspace{ .root = self.cfg.workspace.root, .task_id = task.task_id, .path = task.workspace_path, .created = false };
                ws.remove();

                // Add to cooldown with attempt tracking
                const key = self.allocator.dupe(u8, task.task_id) catch {
                    task.state = .removing;
                    return;
                };
                self.state.cooldowns.put(self.allocator, key, .{
                    .expires_at = cooldown_until,
                    .attempt_count = task.attempt_count + 1,
                }) catch {};

                log.info("task {s} failed, scheduling retry #{d} in {d}ms", .{ task.task_id, task.attempt_count + 1, backoff });
                self.state.failed_count += 1;
                task.state = .removing;
                return;
            }
        }
    }

    // Original failure path (no retry or max attempts reached)
    var client = tracker_client.TrackerClient.init(tick_alloc, self.cfg.url orelse "", self.cfg.api_token);
    _ = client.failRun(task.run_id, "execution failed", task.lease_token, null) catch {};
    // ... rest of existing cleanup
}
```

- [ ] **Step 7: Run all tests**

Run: `zig build test`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/tracker.zig src/workflow_loader.zig
git commit -m "feat(tracker): add retry with exponential backoff for failed tasks"
```

---

## Chunk 5: Example Workflows with Quality Prompts

> **Note:** Example workflows go in `workflows/examples/` for documentation purposes. The existing `loadWorkflows` only reads direct children of the workflows directory, not subdirectories. These examples serve as templates users copy into their `workflows/` directory.

### Task 10: Create feature-dev.json example workflow

**Files:**
- Create: `workflows/examples/feature-dev.json`

- [ ] **Step 1: Create the file**

```json
{
  "id": "feature-dev",
  "pipeline_id": "pipeline-feature-dev",
  "claim_roles": ["developer", "coder"],
  "execution": "subprocess",
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 20,
    "turn_timeout_ms": 600000,
    "continuation_prompt": "{% if attempt %}The task is still in an active state (attempt #{{attempt}}).\n\nContinuation instructions:\n- Resume from the current workspace state instead of restarting from scratch.\n- Do not repeat already-completed investigation or validation unless needed for new code changes.\n- Check your previous work and continue from where you left off.\n- If blocked by missing permissions or secrets, report the blocker and stop.{% endif %}"
  },
  "prompt_template": "You are working on a NullTickets task `{{task.identifier}}`\n\n{% if attempt %}Continuation context:\n- This is retry attempt #{{attempt}} because the task is still in an active state.\n- Resume from the current workspace state instead of restarting from scratch.\n- Do not repeat already-completed investigation or validation unless needed for new code changes.\n{% endif %}\n\nTask context:\nIdentifier: {{task.identifier}}\nTitle: {{task.title}}\n\nDescription:\n{% if task.description %}{{task.description}}{% else %}No description provided.{% endif %}\n\nInstructions:\n\n1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.\n2. Only stop early for a true blocker (missing required auth/permissions/secrets).\n3. Final message must report completed actions and blockers only.\n\nWork only in the provided workspace. Do not touch any other path.\n\nWorkflow:\n\n1. Start by understanding the full scope of the task from the title and description.\n2. Plan your approach before writing code. Break the task into concrete steps.\n3. Reproduce the current behavior first (for bugs) or understand existing code (for features).\n4. Implement changes incrementally with tests.\n5. Run the project's test suite after each meaningful change.\n6. Commit changes with clear, conventional commit messages.\n7. Push to a feature branch and create a pull request.\n8. Verify all CI checks pass before considering the task complete.\n\nQuality bar:\n- Code follows existing project conventions and style.\n- Tests cover the changed behavior.\n- No unrelated changes included.\n- Commit history is clean and logical.",
  "retry": {
    "max_attempts": 3,
    "backoff_base_ms": 10000,
    "backoff_max_ms": 300000
  },
  "on_success": {
    "transition_to": "human-review"
  },
  "on_failure": {
    "transition_to": "failed",
    "retry": true
  }
}
```

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('workflows/examples/feature-dev.json'))"`
Expected: No output (valid JSON)

- [ ] **Step 3: Commit**

```bash
git add workflows/examples/feature-dev.json
git commit -m "docs: add feature-dev example workflow with quality prompts"
```

---

### Task 11: Create code-review.json example workflow

**Files:**
- Create: `workflows/examples/code-review.json`

- [ ] **Step 1: Create the file**

```json
{
  "id": "code-review",
  "pipeline_id": "pipeline-code-review",
  "claim_roles": ["reviewer"],
  "execution": "subprocess",
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 10,
    "turn_timeout_ms": 300000,
    "continuation_prompt": "{% if attempt %}Review is still in progress (attempt #{{attempt}}).\nCheck if there are remaining files or aspects you haven't reviewed yet.\nDo not repeat already-completed review steps.{% endif %}"
  },
  "prompt_template": "You are reviewing code for NullTickets task `{{task.identifier}}`\n\n{% if attempt %}Continuation: this is attempt #{{attempt}}. Resume from where you left off.{% endif %}\n\nTask context:\nIdentifier: {{task.identifier}}\nTitle: {{task.title}}\n\nDescription:\n{% if task.description %}{{task.description}}{% else %}No description provided.{% endif %}\n\nReview instructions:\n\n1. This is an unattended code review session.\n2. Examine all changed files in the workspace.\n3. Check for:\n   - Correctness: Does the code do what the task requires?\n   - Security: Are there injection, XSS, or other OWASP top 10 vulnerabilities?\n   - Performance: Any obvious N+1 queries, unbounded loops, or memory leaks?\n   - Style: Does the code follow existing project conventions?\n   - Tests: Are there adequate tests for the changes?\n   - Edge cases: Are error paths and boundary conditions handled?\n4. Run the project's test suite and report results.\n5. Provide a structured review with:\n   - Summary of changes\n   - Issues found (critical, major, minor)\n   - Suggestions for improvement\n   - Overall assessment (approve, request changes, or block)\n6. If changes are needed, describe them specifically with file paths and line numbers.\n7. Only stop early for a true blocker (missing required auth/permissions/secrets).\n\nWork only in the provided workspace. Do not modify code unless explicitly part of the review task.",
  "on_success": {
    "transition_to": "reviewed"
  },
  "on_failure": {
    "transition_to": "review-failed"
  }
}
```

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('workflows/examples/code-review.json'))"`

- [ ] **Step 3: Commit**

```bash
git add workflows/examples/code-review.json
git commit -m "docs: add code-review example workflow with quality prompts"
```

---

### Task 12: Create bug-fix.json example workflow

**Files:**
- Create: `workflows/examples/bug-fix.json`

- [ ] **Step 1: Create the file**

```json
{
  "id": "bug-fix",
  "pipeline_id": "pipeline-bug-fix",
  "claim_roles": ["developer", "coder"],
  "execution": "subprocess",
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 15,
    "turn_timeout_ms": 600000,
    "continuation_prompt": "{% if attempt %}Bug fix is still in progress (attempt #{{attempt}}).\nResume from the current workspace state. Your previous investigation context is preserved.\nDo not re-investigate issues you have already identified.\nFocus on completing the fix and verification.{% endif %}"
  },
  "prompt_template": "You are fixing a bug reported in NullTickets task `{{task.identifier}}`\n\n{% if attempt %}Continuation context:\n- This is retry attempt #{{attempt}}.\n- Resume from the current workspace state instead of restarting from scratch.\n- Your previous investigation results are preserved in the workspace.\n{% endif %}\n\nBug report:\nIdentifier: {{task.identifier}}\nTitle: {{task.title}}\n\nDescription:\n{% if task.description %}{{task.description}}{% else %}No description provided.{% endif %}\n\nBug fix workflow:\n\n1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.\n2. Only stop early for a true blocker (missing required auth/permissions/secrets).\n\nPhase 1 — Reproduce:\n- Read the bug report carefully. Identify the expected vs actual behavior.\n- Find the relevant code paths.\n- Write a failing test that reproduces the bug. Run it to confirm it fails.\n- If you cannot reproduce, document what you tried and why it did not reproduce.\n\nPhase 2 — Root cause:\n- Trace the execution path that leads to the bug.\n- Identify the root cause, not just the symptom.\n- Document your findings before making changes.\n\nPhase 3 — Fix:\n- Make the minimal change that fixes the root cause.\n- Avoid unrelated refactoring or cleanup.\n- Ensure the failing test now passes.\n- Run the full test suite to check for regressions.\n\nPhase 4 — Verify:\n- Confirm the fix addresses the original bug report.\n- Verify no new test failures were introduced.\n- Commit with a clear message referencing the bug.\n- Push to a feature branch and create a pull request.\n\nQuality bar:\n- The fix is minimal and targeted.\n- A regression test exists for the bug.\n- No unrelated changes.\n- All tests pass.",
  "retry": {
    "max_attempts": 3,
    "backoff_base_ms": 15000,
    "backoff_max_ms": 300000
  },
  "on_success": {
    "transition_to": "human-review"
  },
  "on_failure": {
    "transition_to": "failed",
    "retry": true
  }
}
```

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('workflows/examples/bug-fix.json'))"`

- [ ] **Step 3: Commit**

```bash
git add workflows/examples/bug-fix.json
git commit -m "docs: add bug-fix example workflow with quality prompts"
```

---

### Task 13: Create pr-land.json example workflow

**Files:**
- Create: `workflows/examples/pr-land.json`

- [ ] **Step 1: Create the file**

```json
{
  "id": "pr-land",
  "pipeline_id": "pipeline-pr-land",
  "claim_roles": ["developer", "merger"],
  "execution": "subprocess",
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 25,
    "turn_timeout_ms": 600000,
    "continuation_prompt": "{% if attempt %}PR landing is still in progress (attempt #{{attempt}}).\nCheck current PR status, CI results, and review comments.\nResume the landing process from where you left off.{% endif %}"
  },
  "prompt_template": "You are landing a pull request for NullTickets task `{{task.identifier}}`\n\n{% if attempt %}Continuation: attempt #{{attempt}}. Check current PR and CI state before proceeding.{% endif %}\n\nTask context:\nIdentifier: {{task.identifier}}\nTitle: {{task.title}}\n\nDescription:\n{% if task.description %}{{task.description}}{% else %}No description provided.{% endif %}\n\nPR landing workflow:\n\n1. This is an unattended orchestration session. Do not ask a human to perform follow-up actions.\n2. Only stop early for a true blocker (missing required auth/permissions/secrets).\n\nPhase 1 — Pre-flight:\n- Identify the PR for the current branch.\n- Check mergeability and conflicts against main.\n- If conflicts exist, merge origin/main and resolve them.\n- Ensure all review comments (human and automated) are addressed.\n\nPhase 2 — Review feedback:\n- Gather feedback from all channels:\n  - Top-level PR comments.\n  - Inline review comments.\n  - Review summaries and states.\n- Treat every actionable reviewer comment as blocking until:\n  - Code/test/docs updated to address it, OR\n  - Explicit, justified pushback reply is posted.\n- After addressing feedback, push updates and re-run validation.\n\nPhase 3 — CI watch:\n- Wait for all CI checks to complete.\n- If checks fail, pull logs, diagnose the issue, and fix it.\n- Commit fixes, push, and re-watch checks.\n- Use judgment to identify flaky failures — if a failure is clearly a flake (e.g., timeout on one platform only), you may proceed.\n\nPhase 4 — Merge:\n- When all checks are green and review feedback is addressed:\n  - Squash-merge the PR using the PR title and body.\n  - Do not enable auto-merge.\n- After merge is complete, confirm the merge was successful.\n\nGuardrails:\n- Do not use --force; only use --force-with-lease when history was rewritten.\n- Do not merge while review comments are outstanding.\n- Keep PR title and description reflecting the full scope of changes.\n- If blocked by auth/permissions, report the exact error and stop.",
  "on_success": {
    "transition_to": "done"
  },
  "on_failure": {
    "transition_to": "merge-failed",
    "retry": true
  },
  "retry": {
    "max_attempts": 5,
    "backoff_base_ms": 30000,
    "backoff_max_ms": 300000
  }
}
```

- [ ] **Step 2: Verify JSON is valid**

Run: `python3 -c "import json; json.load(open('workflows/examples/pr-land.json'))"`

- [ ] **Step 3: Commit**

```bash
git add workflows/examples/pr-land.json
git commit -m "docs: add pr-land example workflow with quality prompts"
```

---

### Task 14: Final integration test and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Run full test suite**

Run: `zig build test`
Expected: All tests pass, no memory leaks (std.testing.allocator checks)

- [ ] **Step 2: Run build**

Run: `zig build`
Expected: Clean build, no warnings

- [ ] **Step 3: Verify all example workflows parse correctly**

Run: `for f in workflows/examples/*.json; do python3 -c "import json; json.load(open('$f')); print(f'OK: $f')"; done`
Expected: OK for all 4 files

- [ ] **Step 4: Final commit if any loose changes**

```bash
git status
# If any uncommitted changes remain, commit them
```
