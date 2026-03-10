# Symphony Port to NullBoiler — Design Spec

**Date:** 2026-03-09
**Status:** Approved
**Reference:** openai/symphony (reference/symphony/)

## Goal

Port key orchestration features from OpenAI Symphony into NullBoiler's Zig architecture, adapted for NullClaw (agent runtime), NullTickets (ticket manager), and NullHub (UI).

## In Scope

1. **Conditional template blocks** — `{% if %}`, `{% else %}`, `{% endif %}` in template engine
2. **Multi-turn continuation sessions** — persistent NullClaw process with continuation prompts
3. **Per-state concurrency limits** — 4th axis added to existing 3-axis concurrency
4. **Dispatch priority sorting** — priority, created_at, identifier ordering
5. **Startup workspace cleanup** — clean all workspaces on tracker thread start
6. **Retry semantics** — exponential backoff for failed tasks in pull-mode
7. **Example workflows with quality prompts** — 4 adapted workflow files

## Out of Scope

- Token accounting (handled by NullClaw/NullHub)
- Reconciliation loop (lease expiry sufficient)
- Hot config reload (restart is cheap)
- WORKFLOW.md format (staying on JSON)
- Skills as separate system (prompts live in workflows)
- Full Liquid template engine (only if/else)

---

## 1. Template Engine — Conditional Blocks

**File:** `src/templates.zig`

Add parsing of conditional blocks:

```
{% if <expression> %}...{% else %}...{% endif %}
```

Where `<expression>` is an existing template expression path (e.g., `attempt`, `task.description`, `item`). Truthiness: not null, not empty string, not "false", not "null".

Nested if blocks supported. `{% else %}` is optional.

Example:
```
{% if attempt %}
Continuation: retry attempt #{{attempt}}, resume from current state.
{% else %}
First run. Full task context below.
{% endif %}

Task: {{task.title}}
{% if task.description %}
Description: {{task.description}}
{% else %}
No description provided.
{% endif %}
```

Render flow: resolve conditionals first (strip/keep blocks), then resolve `{{expressions}}` as currently.

## 2. Multi-Turn Continuation Sessions

**Files:** `src/subprocess.zig`, `src/tracker.zig`, `src/workflow_loader.zig`

### Workflow JSON extension

```json
{
  "subprocess": {
    "command": "nullclaw",
    "args": ["--single-task"],
    "max_turns": 20,
    "turn_timeout_ms": 600000,
    "continuation_prompt": "Task is still active. Resume from current workspace state. Do not repeat completed work."
  }
}
```

### Session lifecycle

1. **Turn 1:** render `prompt_template` with `attempt = null`, send to NullClaw
2. **Turn N>1:** if NullClaw still alive and task active, send `continuation_prompt` with `attempt = N`
3. **End:** max_turns reached, or NullClaw returned success/failure, or stall detected

### Changes in subprocess.zig

- `sendPrompt()` gains turn awareness — track turn number
- Add `turn_count` field to subprocess state
- Health check between turns (already exists)

### Changes in tracker.zig RunningTask

- New field `turn_count: u32`
- In `running` state: after NullClaw response, check if task still active. If yes and turns < max, send continuation prompt
- Continuation prompt rendered through template engine with `attempt` in context

## 3. Per-State Concurrency Limits

**Files:** `src/config.zig`, `src/tracker.zig`

### Config extension

```json
{
  "tracker": {
    "concurrency": {
      "max_concurrent_tasks": 10,
      "per_pipeline": {"code-review": 5},
      "per_role": {"coder": 5},
      "per_state": {"in_progress": 5, "rework": 2}
    }
  }
}
```

### Logic

On claim, check 4 axes: global + per_pipeline + per_role + per_state. `per_state` checked against `task.state` from NullTickets response. Same `canAcceptTask()` pattern in `tracker.zig`.

## 4. Dispatch Priority Sorting

**Responsibility:** NullTickets server-side.

The NullTickets claim API (`/leases/claim`) returns one task at a time — the server decides which task to assign based on priority, created date, and identifier. NullBoiler's `TaskInfo` already has a `priority` field for downstream use, but client-side sorting is not applicable to the claim-based architecture. No NullBoiler changes needed.

## 5. Startup Workspace Cleanup

**Files:** `src/workspace.zig`, `src/tracker.zig`

On tracker thread start, before first poll:

```
workspace.cleanAll(workspace_root)
```

Delete all subdirectories under `workspace.root`. Hooks will recreate on next claim.

## 6. Retry Semantics

**File:** `src/workflow_loader.zig`, `src/tracker.zig`

### Workflow JSON extension

```json
{
  "retry": {
    "max_attempts": 3,
    "backoff_base_ms": 10000,
    "backoff_max_ms": 300000
  },
  "on_failure": {"transition_to": "failed", "retry": true}
}
```

When `on_failure.retry: true`, on failure place task in retry queue with exponential backoff (`min(base * 2^(attempt-1), max)`) instead of immediate transition. Extend existing cooldown mechanism in tracker.

## 7. Example Workflows

**Directory:** `workflows/examples/`

Four workflow files adapted from Symphony prompts:

- **`code-review.json`** — code review with quality prompt
- **`feature-dev.json`** — feature development (clone, implement, test, PR)
- **`bug-fix.json`** — bug investigation and fix
- **`pr-land.json`** — PR merge with CI watching

Each example includes:
- Subprocess mode with NullClaw
- Adapted prompt template (NullTickets fields: `{{task.title}}`, `{{task.description}}`, etc.)
- Continuation prompt for multi-turn
- Workspace hooks (git clone, install deps)
- Retry semantics
- Conditional blocks (`{% if attempt %}`, `{% if task.description %}`)

---

## Files Changed

```
src/templates.zig       — conditional blocks parser
src/subprocess.zig      — turn tracking, continuation sends
src/tracker.zig         — per-state concurrency, priority sort, startup cleanup, multi-turn driving
src/config.zig          — per_state concurrency config, retry config
src/workflow_loader.zig — continuation_prompt, retry fields
src/workspace.zig       — cleanAll()
workflows/examples/     — 4 example workflow files (new)
```

No new database migrations required.
