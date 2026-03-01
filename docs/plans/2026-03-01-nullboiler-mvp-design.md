# NullBoiler MVP Design

## Overview

NullBoiler is a DAG-based workflow orchestrator for NullClaw bot agents. It owns **execution**, not tasks — tasks live in NullTracker. NullBoiler can also operate standalone without NullTracker.

**Stack:** Zig 0.15.2, SQLite, HTTP/1.1 REST API.

## Product Context

| Product | Owns | Role |
|---------|------|------|
| **NullTracker** | Tasks, epics, statuses, priorities, SLA, routing, audit | Task backlog & tracking |
| **NullBoiler** | Workflow execution, step scheduling, worker dispatch, artifacts | Orchestration engine |
| **NullClaw** | Single unit of work execution, tools, AI providers, memory | Worker agent |

**User stories:**
- "One bot needed" → NullClaw daemon + NullTracker. No NullBoiler.
- "Multiple agents / parallelism" → NullBoiler orchestrates NullClaw workers.
- "No tracker needed" → NullBoiler standalone, workflows via API.

## Architecture: Step-based DAG Engine

Workflow = directed acyclic graph of steps. Engine traverses the graph, runs ready steps in parallel, collects results, fires callbacks.

### Core Domain Model

**Workflow Definition** (JSON, submitted via API):
```json
{
  "steps": [
    {
      "id": "research",
      "type": "map",
      "worker_tags": ["researcher"],
      "items_from": "$.topics",
      "prompt_template": "Research: {{item}}"
    },
    {
      "id": "summarize",
      "type": "reduce",
      "worker_tags": ["writer"],
      "depends_on": ["research"],
      "prompt_template": "Summarize:\n{{steps.research.outputs}}"
    }
  ],
  "input": { "topics": ["AI safety", "Quantum computing"] }
}
```

**Step Types:**

| Type | Behavior |
|------|----------|
| `task` | One task → one worker. Basic primitive. |
| `fan_out` | Spawn N parallel steps (N known at define time). |
| `map` | Like fan_out but N determined at runtime from `items_from`. |
| `condition` | Evaluate `expression` over previous step output, choose branch. |
| `approval` | Pause run, wait for POST approve/reject. |
| `reduce` | Collect outputs from fan_out/map into one (fan-in). |

**Run** — concrete execution of a workflow:
- `id`, `status` (pending, running, paused, completed, failed, cancelled)
- `workflow_json` — frozen snapshot of the definition
- `input_json` — workflow input data
- Timestamps: created_at_ms, updated_at_ms, started_at_ms, ended_at_ms

**Step Instance** — concrete step within a Run:
- `id`, `run_id`, `def_step_id` (reference to step in workflow_json)
- `status` (pending, ready, running, completed, failed, skipped, waiting_approval)
- `worker_id`, `input_json`, `output_json`, `error_text`
- `attempt`, `max_attempts`, `timeout_ms`
- `parent_step_id` — for map/fan_out children
- `item_index` — index within map/fan_out

## API Design

### Runs

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/runs` | Create and start workflow |
| `GET` | `/runs` | List runs (filter: status, limit, offset) |
| `GET` | `/runs/{id}` | Run details + all steps |
| `POST` | `/runs/{id}/cancel` | Cancel run |
| `POST` | `/runs/{id}/retry` | Retry failed steps |

### Steps

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/runs/{id}/steps` | All steps with statuses |
| `GET` | `/runs/{id}/steps/{step_id}` | Single step details |
| `POST` | `/runs/{id}/steps/{step_id}/approve` | Approve approval step |
| `POST` | `/runs/{id}/steps/{step_id}/reject` | Reject approval step |

### Workers

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/workers` | List workers (static + registered) |
| `POST` | `/workers` | Register new worker |
| `DELETE` | `/workers/{id}` | Remove worker |
| `GET` | `/workers/{id}/health` | Health check |

### Events / Observability

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/runs/{id}/events` | Run audit log |
| `GET` | `/health` | NullBoiler health + stats |

### Callbacks

Part of run creation payload:
```json
{
  "callbacks": [
    {
      "url": "http://nulltracker:7700/runs/{run_id}/events",
      "events": ["step.completed", "step.failed", "run.completed", "run.failed"],
      "headers": {"Authorization": "Bearer ..."}
    }
  ]
}
```

Callback payload:
```json
{
  "event": "step.completed",
  "run_id": "run_abc",
  "step_id": "summarize",
  "timestamp_ms": 1709312400000,
  "data": { "output": "...", "duration_ms": 5200 }
}
```

## DAG Execution Engine

### Scheduler Loop

```
loop {
    1. Find all steps with status "ready"
       (all depends_on completed)

    2. For each ready step:
       a) map → expand items, create child steps as "ready"
       b) condition → evaluate expression, skip inactive branches
       c) approval → set "waiting_approval", fire callback
       d) task | fan_out → find worker by tags, POST /webhook, set "running"

    3. Check timeouts on running steps

    4. If all steps completed/skipped → run = completed
       If any step failed + no retries → run = failed

    5. Sleep(poll_interval) or wake on event
}
```

### Worker Dispatch

1. Filter workers by `step.worker_tags` (intersection with `worker.tags`)
2. Select least-loaded worker (`current_tasks < max_concurrent`)
3. POST to `worker.url/webhook`:
```json
{
  "message": "<rendered prompt_template>",
  "session_key": "run_{run_id}_step_{step_id}"
}
```
4. Parse response → save output → mark step completed/failed

### Data Flow Between Steps

Template syntax for referencing outputs:
- `{{steps.research.output}}` — single step output
- `{{steps.research.outputs}}` — array of outputs (map/fan_out)
- `{{input.topics}}` — workflow input data
- `{{item}}` — current item in map iteration

### Retry Policy

Per-step configuration:
```json
{
  "retry": { "max_attempts": 3, "backoff_ms": [1000, 5000, 15000] }
}
```

### Timeouts

```json
{ "timeout_ms": 300000 }
```

Worker non-response within timeout → step failed → retry if attempts remain.

## Database Schema

```sql
CREATE TABLE workers (
    id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    token TEXT NOT NULL,
    tags_json TEXT NOT NULL DEFAULT '[]',
    max_concurrent INTEGER NOT NULL DEFAULT 1,
    source TEXT NOT NULL DEFAULT 'config',
    status TEXT NOT NULL DEFAULT 'active',
    last_health_ms INTEGER,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE runs (
    id TEXT PRIMARY KEY,
    status TEXT NOT NULL DEFAULT 'pending',
    workflow_json TEXT NOT NULL,
    input_json TEXT NOT NULL DEFAULT '{}',
    callbacks_json TEXT NOT NULL DEFAULT '[]',
    error_text TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    started_at_ms INTEGER,
    ended_at_ms INTEGER
);
CREATE INDEX idx_runs_status ON runs(status);

CREATE TABLE steps (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    def_step_id TEXT NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    worker_id TEXT REFERENCES workers(id),
    input_json TEXT NOT NULL DEFAULT '{}',
    output_json TEXT,
    error_text TEXT,
    attempt INTEGER NOT NULL DEFAULT 1,
    max_attempts INTEGER NOT NULL DEFAULT 1,
    timeout_ms INTEGER,
    parent_step_id TEXT REFERENCES steps(id),
    item_index INTEGER,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    started_at_ms INTEGER,
    ended_at_ms INTEGER
);
CREATE INDEX idx_steps_run ON steps(run_id);
CREATE INDEX idx_steps_status ON steps(run_id, status);
CREATE INDEX idx_steps_parent ON steps(parent_step_id);

CREATE TABLE step_deps (
    step_id TEXT NOT NULL REFERENCES steps(id),
    depends_on TEXT NOT NULL REFERENCES steps(id),
    PRIMARY KEY (step_id, depends_on)
);
CREATE INDEX idx_step_deps_dep ON step_deps(depends_on);

CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT REFERENCES steps(id),
    kind TEXT NOT NULL,
    data_json TEXT NOT NULL DEFAULT '{}',
    ts_ms INTEGER NOT NULL
);
CREATE INDEX idx_events_run ON events(run_id, id);

CREATE TABLE artifacts (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT REFERENCES steps(id),
    kind TEXT NOT NULL,
    uri TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}',
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX idx_artifacts_run ON artifacts(run_id);
CREATE INDEX idx_artifacts_step ON artifacts(step_id);
```

## Module Structure

```
NullBoiler/
├── build.zig
├── src/
│   ├── main.zig              -- CLI, arg parsing, server startup
│   ├── server.zig            -- HTTP server, routing, JSON parsing
│   ├── api.zig               -- Request handlers
│   ├── store.zig             -- SQLite layer
│   ├── engine.zig            -- DAG scheduler loop
│   ├── dispatch.zig          -- Worker selection, HTTP calls
│   ├── templates.zig         -- Prompt template rendering
│   ├── callbacks.zig         -- Webhook firing
│   ├── types.zig             -- Shared types
│   ├── ids.zig               -- UUID v7 generation
│   └── migrations/
│       └── 001_init.sql
├── tests/
│   ├── test_engine.zig
│   ├── test_api.zig
│   ├── test_dispatch.zig
│   ├── test_templates.zig
│   └── test_e2e.sh
└── config.example.json
```

## Error Handling

1. **Step failure** → retry if attempts remain, else step = failed
2. **Worker unreachable** → mark worker `dead`, reassign step
3. **All workers dead** → step stays `ready`, scheduler waits
4. **Run failure** → critical step failed without retries → run = failed, fire callbacks
5. **NullBoiler crash** → on restart: resume runs with status `running` or `paused`

Callback failures: fire-and-forget with 3 retries, exponential backoff.

## Configuration

```json
{
  "port": 8080,
  "db": "nullboiler.db",
  "workers": [
    {
      "id": "claw-1",
      "url": "http://localhost:3001",
      "token": "bearer_xyz",
      "tags": ["coder", "researcher"],
      "max_concurrent": 3
    }
  ],
  "engine": {
    "poll_interval_ms": 500,
    "default_timeout_ms": 300000,
    "default_max_attempts": 1,
    "health_check_interval_ms": 30000
  },
  "callbacks": {
    "retry_attempts": 3,
    "retry_backoff_ms": [1000, 5000, 15000]
  }
}
```

## Demo Scenarios

### 1. Research Pipeline (map → reduce → task)
```bash
curl -X POST http://localhost:8080/runs -d '{
  "steps": [
    {"id": "research", "type": "map", "worker_tags": ["researcher"],
     "items_from": "$.topics",
     "prompt_template": "Research this topic thoroughly: {{item}}"},
    {"id": "summarize", "type": "reduce", "depends_on": ["research"],
     "worker_tags": ["writer"],
     "prompt_template": "Summarize these findings:\n{{steps.research.outputs}}"},
    {"id": "edit", "type": "task", "depends_on": ["summarize"],
     "worker_tags": ["editor"],
     "prompt_template": "Edit and polish:\n{{steps.summarize.output}}"}
  ],
  "input": {"topics": ["AI safety", "Quantum computing", "Biotech"]}
}'
```

### 2. Code Review Committee (fan_out → reduce)
```bash
curl -X POST http://localhost:8080/runs -d '{
  "steps": [
    {"id": "review", "type": "fan_out", "count": 3,
     "worker_tags": ["reviewer"],
     "prompt_template": "Review this code:\n{{input.code}}"},
    {"id": "judge", "type": "reduce", "depends_on": ["review"],
     "worker_tags": ["senior_reviewer"],
     "prompt_template": "Synthesize best feedback:\n{{steps.review.outputs}}"}
  ],
  "input": {"code": "fn main() { ... }"}
}'
```

### 3. Dev Workflow with Conditional (sequential + condition + approval)
```bash
curl -X POST http://localhost:8080/runs -d '{
  "steps": [
    {"id": "plan", "type": "task", "worker_tags": ["planner"],
     "prompt_template": "Create plan for: {{input.feature}}"},
    {"id": "code", "type": "task", "depends_on": ["plan"],
     "worker_tags": ["coder"],
     "prompt_template": "Implement:\n{{steps.plan.output}}",
     "retry": {"max_attempts": 3}},
    {"id": "test", "type": "task", "depends_on": ["code"],
     "worker_tags": ["tester"],
     "prompt_template": "Test:\n{{steps.code.output}}"},
    {"id": "check", "type": "condition", "depends_on": ["test"],
     "expression": "steps.test.output contains ALL TESTS PASSED",
     "branches": {"true": "approve", "false": "code"}},
    {"id": "approve", "type": "approval", "depends_on": ["check"]}
  ],
  "input": {"feature": "Add user authentication"}
}'
```

## Key Design Decisions

1. **API-first** — workflows defined in API requests, not config files
2. **Loose coupling with NullTracker** — callbacks, not direct integration
3. **Hybrid worker management** — static config + dynamic registration
4. **SQLite persistence** — crash recovery, consistent with ecosystem
5. **DAG engine** — proven pattern, all orchestration patterns map naturally
6. **Standalone capable** — works with or without NullTracker
