# Symphony Pull-Mode Integration Design

**Date:** 2026-03-05
**Status:** Approved
**Scope:** Port OpenAI Symphony orchestration patterns into NullBoiler as a pull-mode alongside existing push API.

## Context

OpenAI Symphony is a long-running orchestrator that polls an issue tracker (Linear), creates isolated workspaces per issue, and runs coding agent sessions with bounded concurrency and retry/recovery. NullBoiler already has a push-mode DAG orchestrator. This design adds a pull-mode that integrates with NullTickets (our issue tracker) to achieve similar capabilities.

### Ecosystem Mapping

| Symphony | Null Ecosystem |
|----------|---------------|
| Linear (issue tracker) | NullTickets |
| Status Dashboard | NullHub |
| Codex Agent | NullClaw |
| Orchestrator | NullBoiler (this project) |

## Design Decisions

1. **Pull-mode alongside push** — Tracker thread activates only when `config.tracker` is present. Push API unchanged.
2. **Hybrid execution** — Subprocess (spawn NullClaw per task) for isolated work, dispatch (existing workers) for lightweight tasks.
3. **Full shell hooks** — 4 configurable hooks (after_create, before_run, after_run, before_remove) executed in workspace context.
4. **JSON workflow files** — Workflow definitions in `workflows/` directory, consistent with existing JSON-based architecture.
5. **Three-axis concurrency** — Global + per-pipeline + per-role limits.

## Architecture

### Thread Model

```
Main thread:       HTTP accept loop (push API — unchanged)
Engine thread:     DAG tick loop (unchanged)
Tracker thread:    NEW — poll NullTickets → claim → workspace → spawn/dispatch
MQTT listener:     (unchanged, conditional)
Redis listener:    (unchanged, conditional)
```

### Tracker Thread Loop (every `poll_interval_ms`)

1. Check concurrency limits (global / per-pipeline / per-role)
2. `GET /ops/queue` — discover available work
3. `POST /leases/claim` — claim eligible tasks within limits
4. For each claimed task:
   - Create workspace (mkdir + `after_create` hook)
   - Load JSON workflow from `workflows/` directory
   - Run `before_run` hook
   - Execute: subprocess or dispatch (per workflow config)
5. Reconciliation: verify running tasks vs NullTickets state
6. Stall detection: kill timed-out agents
7. Heartbeat: extend leases for active tasks
8. Cleanup: `after_run` + `before_remove` for completed/terminal tasks

### In-Memory State

```zig
const TrackerState = struct {
    running: StringHashMap(RunningTask),
    completed: StringHashMap(i64),         // task_id → completed_at_ms
    retry_queue: StringHashMap(RetryEntry),
    claims: StringHashMap(ClaimInfo),       // task_id → lease_id, lease_token
};
```

## Configuration

New optional `tracker` section in `config.json`:

```json
{
  "tracker": {
    "url": "http://localhost:8070",
    "api_token": "nt_secret_token",
    "poll_interval_ms": 10000,
    "agent_id": "boiler-01",

    "concurrency": {
      "max_concurrent_tasks": 10,
      "per_pipeline": {
        "code-review": 5,
        "feature-dev": 3
      },
      "per_role": {
        "researcher": 3,
        "coder": 5
      }
    },

    "workspace": {
      "root": "/tmp/nullboiler-workspaces",
      "hooks": {
        "after_create": "git clone --depth 1 $REPO_URL .",
        "before_run": "npm install",
        "after_run": "git add -A && git commit -m 'agent work'",
        "before_remove": null
      },
      "hook_timeout_ms": 30000
    },

    "stall_timeout_ms": 300000,
    "lease_ttl_ms": 60000,
    "heartbeat_interval_ms": 30000,

    "workflows_dir": "workflows"
  }
}
```

If `tracker` is absent or null, the Tracker thread does not start.

## JSON Workflow Files

Files in `workflows/` directory. Each maps a pipeline to execution config:

### Subprocess execution (isolated workspace + NullClaw child process):

```json
{
  "id": "code-review",
  "pipeline_id": "pipeline-code-review",
  "claim_roles": ["reviewer"],
  "execution": "subprocess",

  "subprocess": {
    "command": "nullclaw",
    "args": ["--port", "0", "--single-task"],
    "max_turns": 20,
    "turn_timeout_ms": 600000
  },

  "prompt_template": "Review the code.\n\nTask: {{task.title}}\nDescription: {{task.description}}",

  "hooks": {
    "after_create": "git clone --depth 1 {{task.metadata.repo_url}} .",
    "before_run": "git checkout {{task.metadata.branch}}"
  },

  "on_success": {
    "transition_to": "reviewed",
    "artifact": {
      "name": "review-result",
      "source": "output"
    }
  },

  "on_failure": {
    "transition_to": "review-failed"
  }
}
```

### Dispatch execution (existing registered workers):

```json
{
  "id": "quick-analysis",
  "pipeline_id": "pipeline-triage",
  "claim_roles": ["analyst"],
  "execution": "dispatch",

  "dispatch": {
    "worker_tags": ["analysis"],
    "protocol": "webhook"
  },

  "prompt_template": "Analyze: {{task.title}}\n{{task.description}}",

  "on_success": {
    "transition_to": "analyzed"
  }
}
```

### Key behaviors:
- `execution: "subprocess"` — spawn NullClaw, create workspace, manage turns
- `execution: "dispatch"` — use existing dispatch to registered workers (no workspace)
- Per-workflow hooks override global `tracker.workspace.hooks`
- Template variables: `{{task.title}}`, `{{task.description}}`, `{{task.metadata.X}}`
- `on_success` / `on_failure` — auto transition in NullTickets + optional artifact save

## Subprocess Management (Multi-turn)

### Spawn:
1. Pick free port (or `--port 0` → NullClaw reports port via stdout)
2. Spawn `nullclaw --port <port> --single-task --workdir <workspace_path>`
3. Wait for health check (`GET /health`) — retry up to 5 seconds
4. NullClaw ready to accept tasks

### Multi-turn loop:
```
Turn 1: POST full prompt (rendered template + task context)
         → wait for response (with turn_timeout_ms)
         → get output

Turn 2+: POST continuation guidance
          → wait for response
          → get output

Loop until:
  - NullClaw returns "done" / terminal status
  - max_turns reached
  - stall_timeout_ms exceeded
  - Task moved to terminal state in NullTickets (reconciliation)
```

### Process tracking:
```zig
const SubprocessInfo = struct {
    pid: std.process.Child,
    port: u16,
    workspace_path: []const u8,
    task_id: []const u8,
    lease_id: []const u8,
    lease_token: []const u8,
    current_turn: u32,
    max_turns: u32,
    started_at_ms: i64,
    last_activity_ms: i64,
};
```

### Graceful shutdown:
- NullBoiler receives SIGTERM → send stop to each subprocess → wait grace period → SIGKILL
- Leases not renewed → NullTickets auto-releases tasks by TTL

## Reconciliation & Lease Management

### Heartbeat (every `heartbeat_interval_ms`):
- For each running task: `POST /leases/{id}/heartbeat` with lease_token
- If heartbeat returns 404/409 → lease expired/stolen → kill subprocess, remove from running

### Reconciliation (every poll tick):
1. Collect all running task_ids
2. `GET /tasks/{id}` for each — check current stage
3. Task in terminal stage → externally cancelled → kill subprocess, cleanup, remove
4. Task changed to unexpected stage → kill, remove

### Stall detection (every poll tick):
```
for each running task:
    elapsed = now - last_activity_ms
    if elapsed > stall_timeout_ms:
        kill subprocess
        POST /runs/{id}/fail (reason: "stall_timeout")
        add to retry cooldown
        cleanup
```

### Retry:
- Retry policy owned by NullTickets (task.retry_policy)
- NullBoiler calls `POST /runs/{id}/fail` — NullTickets creates new run if attempts remain
- NullBoiler adds task_id to cooldown (don't re-claim for N seconds)
- Exponential backoff: `min(base * 2^attempt, max_backoff)`

### Cleanup lifecycle:
- Task completed/failed → `after_run` hook → workspace kept
- Task terminal (done/cancelled) → `before_remove` hook → rm -rf workspace

## Observability API (for NullHub)

New endpoints in `api.zig`:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/tracker/status` | Full state: running, retry queue, completed, concurrency |
| GET | `/tracker/tasks` | Running tasks with details |
| GET | `/tracker/tasks/{task_id}` | Single task details (turns, events, lease) |
| GET | `/tracker/stats` | Aggregates: throughput, avg turn time, success/fail rate |

### `/tracker/status` response:

```json
{
  "mode": "pull",
  "running_count": 3,
  "max_concurrent": 10,
  "retry_queue_count": 1,
  "completed_count": 47,
  "concurrency": {
    "global": { "used": 3, "max": 10 },
    "per_pipeline": { "code-review": { "used": 2, "max": 5 } },
    "per_role": { "coder": { "used": 1, "max": 5 } }
  },
  "running": [
    {
      "task_id": "...",
      "task_identifier": "FEAT-123",
      "task_title": "Add login page",
      "pipeline_id": "feature-dev",
      "agent_role": "coder",
      "execution": "subprocess",
      "current_turn": 2,
      "max_turns": 20,
      "started_at_ms": 1709654400000,
      "last_activity_ms": 1709654500000,
      "workspace_path": "/tmp/.../FEAT-123",
      "subprocess_pid": 12345,
      "subprocess_port": 9201,
      "lease_id": "...",
      "lease_expires_ms": 1709654560000
    }
  ],
  "retry_queue": [
    {
      "task_id": "...",
      "task_identifier": "BUG-456",
      "reason": "stall_timeout",
      "attempt": 2,
      "next_attempt_ms": 1709654600000
    }
  ],
  "poll_interval_ms": 10000,
  "last_poll_ms": 1709654490000,
  "tracker_url": "http://localhost:8070"
}
```

## New & Changed Files

### New files:

| File | Role |
|------|------|
| `tracker.zig` | Tracker thread: poll loop, claim, reconciliation, stall detection, heartbeat |
| `tracker_client.zig` | HTTP client for NullTickets API |
| `workspace.zig` | Workspace lifecycle: create, hooks, cleanup, path sanitization, symlink protection |
| `subprocess.zig` | NullClaw subprocess: spawn, health wait, multi-turn loop, kill |
| `workflow_loader.zig` | Load and hot-reload JSON workflow files from `workflows/` |

### Changed files:

| File | Change |
|------|--------|
| `main.zig` | Spawn Tracker thread conditionally. Graceful shutdown for subprocesses |
| `config.zig` | New `TrackerConfig` struct |
| `templates.zig` | New variables: `{{task.title}}`, `{{task.description}}`, `{{task.metadata.X}}` |
| `types.zig` | New types: `TrackerState`, `SubprocessInfo`, `RunningTask`, `ClaimInfo` |
| `api.zig` | New `/tracker/*` observability endpoints |

### Unchanged:
- `engine.zig` — push-mode DAG execution unchanged
- `store.zig` — pull-mode uses in-memory state, not SQLite
- `dispatch.zig` — used as-is for `execution: "dispatch"` workflows
- `callbacks.zig`, `metrics.zig` — unchanged
