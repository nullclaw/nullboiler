# Pull-Mode Execution Engine Design

**Date:** 2026-03-06
**Status:** Approved
**Scope:** Complete the pull-mode execution engine — multi-turn NullClaw sessions, dispatch execution, reconciliation, cleanup.

## Context

NullBoiler's pull-mode has a working skeleton: config loading, workflow loading, claim loop, workspace creation, heartbeat, stall detection, concurrency control, and observability API endpoints. However, the execution engine is missing — claimed tasks are never actually executed. This design closes that gap.

### Ecosystem Context

| Component | Role in pull-mode |
|---|---|
| NullTickets | Owns task state, pipeline FSM, leases, retry policy, usage storage |
| NullClaw | AI agent runtime — spawned per task as HTTP gateway, multi-turn sessions via `/webhook` |
| NullBoiler | Orchestrator — polls NullTickets, spawns NullClaw, drives multi-turn loop, transitions runs |
| NullHub | Process supervisor + dashboard — manages NullBoiler process, can display tracker API data |

### Key Protocol: NullClaw Integration

NullClaw uses HTTP webhook protocol (not JSON-RPC like Codex):
1. Spawn `nullclaw gateway --port <port>` with cwd = workspace
2. Wait for `GET /health` → 200
3. `POST /webhook` with `{"message": "prompt"}` → `{"status": "ok", "response": "...", "thread_events": [...]}`
4. Same process = same session (conversation history preserved across turns)
5. One NullClaw process per task (full isolation)
6. NullClaw reads its own global config (`~/.nullclaw/config.json`) for providers/models

### Key Protocol: NullTickets Integration

- Claim: `POST /leases/claim` → task + run + lease
- Heartbeat: `POST /leases/{id}/heartbeat` with Bearer lease_token
- Transition: `POST /runs/{id}/transition` with trigger + optional usage JSON
- Fail: `POST /runs/{id}/fail` with error + optional usage JSON
- Events: `POST /runs/{id}/events` with kind + data JSON
- Task check: `GET /tasks/{id}` → current stage, pipeline_id
- NullTickets owns retry logic (max_attempts, retry_delay_ms, dead_letter_stage)

## Design Decisions

1. **Multi-turn sessions** — NullBoiler keeps NullClaw alive across turns (up to max_turns), sending continuation prompts. This preserves conversation context.
2. **Task completion via NullTickets state** — After each turn, check `GET /tasks/{id}`. If stage changed or terminal → done. If same stage + turns left → continue.
3. **One NullClaw per task** — Spawn separate process on free port. No pairing needed (require_pairing=false or single-session). Kill on completion.
4. **Global NullClaw config** — NullBoiler only passes `--port` and sets cwd. LLM providers/models configured by operator in NullClaw's config.

## Architecture

### Tick Loop (updated)

```
tick():
  1. heartbeatAll()        — extend leases (existing)
  2. detectStalls()        — kill timed-out agents (existing)
  3. pollAndClaim()        — claim new tasks (existing, transitions to workspace_setup)
  4. driveRunningTasks()   — NEW: state machine for each running task
  5. reconcile()           — NEW: verify tasks vs NullTickets state
  6. cleanCooldowns()      — expire cooldowns (existing)
```

### Task State Machine

```
workspace_setup → spawning → running → completing → completed
                     ↓          ↓
                   failed     failed
```

| State | Action |
|---|---|
| `workspace_setup` | Already handled by `startTask()`. Transition to `spawning` |
| `spawning` | Pick free port. Spawn `nullclaw gateway --port <port>`. Wait for `/health` (10 retries, 500ms). On success → `running`. On failure → `failed` |
| `running` | Render prompt (turn 1) or continuation prompt (turn 2+). `POST /webhook`. Update `last_activity_ms`, increment `current_turn`. Check task state in NullTickets. If terminal/changed → `completing`. If same + turns left → stay `running`. If max_turns → `failed` |
| `completing` | Run `after_run` hook. Call `POST /runs/{id}/transition` with trigger from `on_success` + usage. Kill NullClaw. Transition to `completed` |
| `completed` | Run `before_remove` hook. Remove workspace. Remove from running map. Increment `completed_count` |
| `failed` | Call `POST /runs/{id}/fail` with reason + usage. Run `after_run` hook. Kill NullClaw. Remove workspace. Remove from running map. Increment `failed_count` |

### Subprocess Lifecycle

```
1. Allocate port: start from 9200, scan for unused (track in-use ports)
2. Spawn: nullclaw gateway --port <port>  (cwd = workspace_path)
3. Health wait: GET http://127.0.0.1:<port>/health (10 retries, 500ms between)
4. Turn 1:
   - Render workflow.prompt_template with task_json context
   - POST http://127.0.0.1:<port>/webhook {"message": rendered_prompt}
   - Parse response: extract response text + thread_events
5. After each turn:
   - Update last_activity_ms = now
   - current_turn += 1
   - GET /tasks/{task_id} from NullTickets
   - Decision:
     a) Task in terminal stage → go to completing
     b) Task stage changed (agent self-transitioned) → go to completing
     c) Same stage + current_turn < max_turns → continuation turn
     d) Same stage + current_turn >= max_turns → go to failed
6. Turn 2+:
   - Send continuation prompt: "Continue working on this task. Previous response context is preserved in your session."
   - Same POST /webhook flow
7. On completion/failure:
   - Kill NullClaw process (SIGTERM → wait → SIGKILL)
   - Release port from tracking
```

### Dispatch Execution Path

For `execution: "dispatch"` workflows (no subprocess):
1. Render prompt template with task_json context
2. Find worker via existing `dispatch.zig` using workflow's `worker_tags` and `protocol`
3. Dispatch rendered prompt as payload
4. On worker response → `POST /runs/{id}/transition`
5. On worker failure → `POST /runs/{id}/fail`
6. No workspace creation, no NullClaw process

### Reconciliation

Each tick, for each running task:
1. `GET /tasks/{task_id}` from NullTickets
2. If task stage is terminal (per pipeline definition) → kill subprocess, cleanup, remove
3. If task reassigned to different agent → kill subprocess, cleanup, remove

### Usage Forwarding

NullClaw response includes `thread_events` with tool summaries. NullBoiler:
- Extracts available metrics from response
- Passes as `usage` JSON in transition/fail calls to NullTickets
- NullTickets stores `usage_json` durably per run

### Event Posting

During multi-turn loop, post progress to NullTickets:
- After each turn: `POST /runs/{id}/events` with `kind: "turn_completed"`, `data: {turn: N}`
- On subprocess spawn: `POST /runs/{id}/events` with `kind: "agent_started"`, `data: {port: N, pid: N}`

### Thread Safety

Add `std.Thread.Mutex` to `TrackerState`:
- Lock in all tracker write paths (heartbeat removal, stall removal, add/remove running tasks, counter increments)
- Lock in all API read handlers (`handleTrackerStatus`, `handleTrackerTasks`, `handleTrackerTaskDetail`)
- Lock scope: minimal (just around map/counter access, not during HTTP calls)

### Port Allocation

Simple in-memory tracker:
- `used_ports: std.AutoArrayHashMap(u16, void)` on Tracker
- `allocatePort()`: scan from `base_port` (default 9200) upward, skip used, return first free
- `releasePort(port)`: remove from set
- Base port configurable in `TrackerConfig`

## Configuration

New fields in `TrackerConfig`:

```json
{
  "tracker": {
    "subprocess": {
      "command": "nullclaw",
      "args": ["gateway"],
      "base_port": 9200,
      "health_check_retries": 10,
      "continuation_prompt": "Continue working on this task. Your previous context is preserved."
    }
  }
}
```

## New & Changed Files

### Changed files:

| File | Change |
|---|---|
| `tracker.zig` | Add `driveRunningTasks()`, `reconcile()`, port allocator, state machine, mutex |
| `tracker_client.zig` | Add `postEvent()`. Update `transition()` and `failRun()` to accept usage JSON |
| `subprocess.zig` | No new functions needed (spawn, health, sendPrompt, kill already exist). Update `sendPrompt` to use `/webhook` path and parse response |
| `config.zig` | Move `SubprocessDefaults` fields into `TrackerConfig.subprocess`, add `base_port`, `health_check_retries`, `continuation_prompt` |
| `api.zig` | Add mutex locking in tracker handlers. Add `POST /tracker/refresh` |
| `main.zig` | No changes needed |

### Unchanged:
- `engine.zig` — push-mode DAG execution unchanged
- `dispatch.zig` — used as-is for dispatch workflows
- `store.zig` — pull-mode uses in-memory state
- `workspace.zig` — hooks already work, `remove()` already implemented
- `workflow_loader.zig` — already loads all needed fields
- `templates.zig` — already handles `task.*` variables
- `types.zig` — TrackerTaskState already has all needed states
