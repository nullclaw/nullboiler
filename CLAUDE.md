# NullBoiler

DAG-based workflow orchestrator for NullClaw AI bot agents. Part of the Null ecosystem (NullTracker, NullClaw).

## Tech Stack

- **Language**: Zig 0.15.2
- **Database**: SQLite (vendored in `deps/sqlite/`), WAL mode
- **Protocol**: HTTP/1.1 REST API with JSON payloads
- **Dispatch**: HTTP (webhook/api_chat/openai_chat), MQTT, Redis Streams
- **Vendored C libs**: SQLite (`deps/sqlite/`), hiredis (`deps/hiredis/`), libmosquitto (`deps/mosquitto/`)

## Module Map

| File | Role |
|------|------|
| `main.zig` | CLI args (`--port`, `--db`, `--config`, `--version`), HTTP accept loop, engine thread, tracker thread |
| `api.zig` | REST API routing and 19 endpoint handlers (incl. signal, chat, tracker status) |
| `store.zig` | SQLite layer, 30+ CRUD methods, schema migrations |
| `engine.zig` | DAG scheduler: tick loop, 14 step type handlers, graph cycles, worker handoff |
| `dispatch.zig` | Worker selection (tags, capacity), protocol-aware dispatch (`webhook`, `api_chat`, `openai_chat`, `mqtt`, `redis_stream`) |
| `async_dispatch.zig` | Thread-safe response queue for async MQTT/Redis dispatch (keyed by correlation_id) |
| `redis_client.zig` | Hiredis wrapper: connect, XADD, listener thread for response streams |
| `mqtt_client.zig` | Libmosquitto wrapper: connect, publish, subscribe, listener thread for response topics |
| `templates.zig` | Prompt template rendering: `{{input.X}}`, `{{steps.ID.output}}`, `{{item}}`, `{{task.X}}`, `{{debate_responses}}`, `{{chat_history}}`, `{{role}}` |
| `callbacks.zig` | Fire-and-forget webhook callbacks on step/run events |
| `config.zig` | JSON config loader (`Config`, `WorkerConfig`, `EngineConfig`, `TrackerConfig`) |
| `types.zig` | `RunStatus`, `StepStatus`, `StepType` (14 types), `WorkerStatus`, `TrackerTaskState`, row types |
| `tracker.zig` | Pull-mode tracker thread: poll NullTickets, claim tasks, heartbeat leases, stall detection |
| `tracker_client.zig` | HTTP client for NullTickets API (claim, heartbeat, transition, fail, artifacts) |
| `workspace.zig` | Workspace lifecycle: create, hook execution, cleanup, path sanitization |
| `subprocess.zig` | NullClaw subprocess: spawn, health check, prompt sending, kill |
| `workflow_loader.zig` | Load JSON workflow definitions from `workflows/` directory |
| `ids.zig` | UUID v4 generation, `nowMs()` |
| `migrations/001_init.sql` | 6 tables: workers, runs, steps, step_deps, events, artifacts |
| `migrations/002_advanced_steps.sql` | 3 tables: cycle_state, chat_messages, saga_state + ALTER TABLE |

## Build / Test / Run

```sh
zig build              # build
zig build test         # unit tests
zig build && bash tests/test_e2e.sh   # e2e tests (requires Python 3 for mock workers)
./zig-out/bin/nullboiler --port 8080 --db nullboiler.db --config config.json
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| POST | `/workers` | Register worker |
| GET | `/workers` | List workers |
| DELETE | `/workers/{id}` | Remove worker |
| POST | `/runs` | Create workflow run |
| GET | `/runs` | List runs |
| GET | `/runs/{id}` | Get run details |
| POST | `/runs/{id}/cancel` | Cancel run |
| POST | `/runs/{id}/retry` | Retry failed run |
| GET | `/runs/{id}/steps` | List steps for run |
| GET | `/runs/{id}/steps/{step_id}` | Get step details |
| POST | `/runs/{id}/steps/{step_id}/approve` | Approve approval step |
| POST | `/runs/{id}/steps/{step_id}/reject` | Reject approval step |
| GET | `/runs/{id}/events` | List run events |
| POST | `/runs/{id}/steps/{step_id}/signal` | Signal a waiting step |
| GET | `/runs/{id}/steps/{step_id}/chat` | Get group_chat transcript |
| GET | `/tracker/status` | Pull-mode tracker status (running tasks, concurrency, counters) |
| GET | `/tracker/tasks` | List running pull-mode tasks |
| GET | `/tracker/tasks/{task_id}` | Get single pull-mode task details |

## Step Types

`task`, `fan_out`, `map`, `condition`, `approval`, `reduce`, `loop`, `sub_workflow`, `wait`, `router`, `transform`, `saga`, `debate`, `group_chat`

## Coding Conventions

- Follow NullTracker patterns (same author)
- Arena allocators per request/tick; free everything via arena deinit
- Error handling: return errors up, log with `std.log`
- Tests: use `:memory:` SQLite, `std.testing.allocator` for leak detection
- Naming: `snake_case` everywhere
- No external dependencies beyond vendored C libs (SQLite, hiredis, libmosquitto)

## Architecture

- Single-threaded HTTP accept loop on main thread
- Background engine thread polls DB for active runs (+ polls async response queue for MQTT/Redis steps)
- `std.atomic.Value(bool)` for coordinated shutdown
- Config workers seeded into DB on startup (source = "config")
- Schema in `migrations/001_init.sql` + `002_advanced_steps.sql`, applied on `Store.init`
- Graph cycles: condition/router can route back to completed steps, engine creates new step instances per iteration
- Worker handoff: dispatch result can include `handoff_to` for chained delegation (max 5)
- Async dispatch: MQTT/Redis workers use two-phase dispatch (publish → engine polls response queue)
- Background listener threads (MQTT/Redis) started conditionally when async workers are configured
- Pull-mode tracker thread (conditional): polls NullTickets for tasks, claims work, manages subprocess lifecycles

## Pull-Mode (NullTickets Integration)

Optional pull-mode where NullBoiler acts as an agent polling NullTickets for work. Activated by adding a `tracker` section to `config.json`.

### Configuration

```json
{
  "tracker": {
    "url": "http://localhost:8070",
    "api_token": "nt_secret_token",
    "poll_interval_ms": 10000,
    "agent_id": "boiler-01",
    "concurrency": {
      "max_concurrent_tasks": 10,
      "per_pipeline": { "code-review": 5 },
      "per_role": { "coder": 5 }
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

If `tracker` is absent or null, the tracker thread does not start and push-mode operates unchanged.

### Workflow Definitions

JSON files in `workflows/` directory. Two execution modes:
- `subprocess` — spawn NullClaw child process per task (isolated workspace)
- `dispatch` — use existing registered workers (no workspace)

Three-axis concurrency: global (`max_concurrent_tasks`) + per-pipeline + per-role limits.

### Thread Model

```
Main thread:       HTTP accept loop (push API — unchanged)
Engine thread:     DAG tick loop (unchanged)
Tracker thread:    Poll NullTickets → claim → workspace → subprocess/dispatch
MQTT listener:     (unchanged, conditional)
Redis listener:    (unchanged, conditional)
```

## Database

SQLite with WAL mode. Schema: 9 tables across 2 migrations.
- `001_init.sql`: workers, runs, steps, step_deps, events, artifacts
- `002_advanced_steps.sql`: cycle_state, chat_messages, saga_state + iteration_index/child_run_id columns on steps
