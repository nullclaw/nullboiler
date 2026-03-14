# NullBoiler

Graph-based workflow orchestrator with unified state model for NullClaw AI bot agents. Part of the Null ecosystem (NullTracker, NullClaw).

## Tech Stack

- **Language**: Zig 0.15.2
- **Database**: SQLite (vendored in `deps/sqlite/`), WAL mode
- **Protocol**: HTTP/1.1 REST API with JSON payloads
- **Dispatch**: HTTP (webhook/api_chat/openai_chat/a2a), MQTT, Redis Streams
- **Vendored C libs**: SQLite (`deps/sqlite/`), hiredis (`deps/hiredis/`), libmosquitto (`deps/mosquitto/`)

## Module Map

| File | Role |
|------|------|
| `main.zig` | CLI args (`--port`, `--db`, `--config`, `--version`, `--export-manifest`, `--from-json`), HTTP accept loop, engine thread, tracker thread |
| `api.zig` | REST API routing and 30+ endpoint handlers (runs, workers, workflows, checkpoints, state, SSE stream, tracker) |
| `store.zig` | SQLite layer, CRUD methods for all tables, schema migrations (4 migration files) |
| `engine.zig` | Graph-based state scheduler: tick loop, 7 node type handlers, checkpoints, reducers, goto, breakpoints, deferred nodes, reconciliation |
| `state.zig` | Unified state model: 7 reducer types (last_value, append, merge, add, min, max, add_messages), overwrite bypass, ephemeral keys, state path resolution |
| `sse.zig` | Server-Sent Events hub: per-run event queues, 5 stream modes (values, updates, tasks, debug, custom) |
| `dispatch.zig` | Worker selection (tags, capacity, A2A preference), protocol-aware dispatch |
| `async_dispatch.zig` | Thread-safe response queue for async MQTT/Redis dispatch (keyed by correlation_id) |
| `redis_client.zig` | Hiredis wrapper: connect, XADD, listener thread for response streams |
| `mqtt_client.zig` | Libmosquitto wrapper: connect, publish, subscribe, listener thread for response topics |
| `templates.zig` | Prompt template rendering: state-based `{{state.X}}`, legacy `{{input.X}}`, `{{item}}`, `{{task.X}}`, `{{attempt}}`, conditional blocks |
| `callbacks.zig` | Fire-and-forget webhook callbacks on step/run events |
| `config.zig` | JSON config loader (`Config`, `WorkerConfig`, `EngineConfig`, `TrackerConfig`) |
| `types.zig` | `RunStatus`, `StepStatus`, `StepType` (7 types), `WorkerStatus`, `ReducerType`, row types |
| `tracker.zig` | Pull-mode tracker thread: poll NullTickets, claim tasks, heartbeat leases, stall detection |
| `tracker_client.zig` | HTTP client for NullTickets API (claim, heartbeat, transition, fail, artifacts) |
| `workspace.zig` | Workspace lifecycle: create, hook execution, cleanup, path sanitization |
| `subprocess.zig` | NullClaw subprocess: spawn, health check, prompt sending, kill |
| `workflow_loader.zig` | Load JSON workflow definitions from `workflows/` directory, hot-reload watcher |
| `workflow_validation.zig` | Graph-based workflow validation: reachability, cycles, state key refs, route/send targets |
| `ids.zig` | UUID v4 generation, `nowMs()` |
| `metrics.zig` | Prometheus-style metrics counters |
| `strategy.zig` | Pluggable strategy map for workflow execution |
| `worker_protocol.zig` | Protocol-specific request body builders |
| `worker_response.zig` | Protocol-specific response parsers |
| `export_manifest.zig` | Export tool manifest for CLI integration |
| `from_json.zig` | Import workflow from JSON CLI command |

## Build / Test / Run

```sh
zig build              # build
zig build test         # unit tests (324 tests)
zig build && bash tests/test_e2e.sh   # e2e tests (requires Python 3 for mock workers)
./zig-out/bin/nullboiler --port 8080 --db nullboiler.db --config config.json
```

## Step Types (7)

`task`, `route`, `interrupt`, `agent`, `send`, `transform`, `subgraph`

## Reducers (7)

`last_value`, `append`, `merge`, `add`, `min`, `max`, `add_messages`

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/metrics` | Prometheus metrics |
| POST | `/workers` | Register worker |
| GET | `/workers` | List workers |
| DELETE | `/workers/{id}` | Remove worker |
| POST | `/runs` | Create workflow run (legacy step-array or graph format) |
| GET | `/runs` | List runs (supports ?status= filter) |
| GET | `/runs/{id}` | Get run details |
| POST | `/runs/{id}/cancel` | Cancel run |
| POST | `/runs/{id}/retry` | Retry failed run |
| POST | `/runs/{id}/resume` | Resume interrupted run (with optional state updates) |
| POST | `/runs/{id}/state` | Inject state into running run (pending injection) |
| POST | `/runs/{id}/replay` | Replay run from a checkpoint |
| POST | `/runs/fork` | Fork run from a checkpoint into a new run |
| GET | `/runs/{id}/steps` | List steps for run |
| GET | `/runs/{id}/steps/{step_id}` | Get step details |
| GET | `/runs/{id}/events` | List run events |
| GET | `/runs/{id}/checkpoints` | List checkpoints for run |
| GET | `/runs/{id}/checkpoints/{cpId}` | Get checkpoint details |
| GET | `/runs/{id}/stream` | SSE stream (supports ?mode=values\|updates\|tasks\|debug) |
| POST | `/workflows` | Create workflow definition |
| GET | `/workflows` | List workflow definitions |
| GET | `/workflows/{id}` | Get workflow definition |
| PUT | `/workflows/{id}` | Update workflow definition |
| DELETE | `/workflows/{id}` | Delete workflow definition |
| POST | `/workflows/{id}/validate` | Validate workflow definition |
| GET | `/workflows/{id}/mermaid` | Export workflow as Mermaid diagram |
| POST | `/workflows/{id}/run` | Start a run from a stored workflow |
| GET | `/rate-limits` | Get current rate limit info per worker |
| POST | `/admin/drain` | Enable drain mode |
| GET | `/tracker/status` | Pull-mode tracker status |
| GET | `/tracker/tasks` | List running pull-mode tasks |
| GET | `/tracker/tasks/{task_id}` | Get single pull-mode task details |
| GET | `/tracker/stats` | Tracker statistics |
| POST | `/tracker/refresh` | Force tracker poll |
| POST | `/internal/agent-events/{run_id}/{step_id}` | Agent event callback (from NullClaw) |

## Coding Conventions

- Follow NullTracker patterns (same author)
- Arena allocators per request/tick; free everything via arena deinit
- Error handling: return errors up, log with `std.log`
- Tests: use `:memory:` SQLite, `std.testing.allocator` for leak detection
- Naming: `snake_case` everywhere
- No external dependencies beyond vendored C libs (SQLite, hiredis, libmosquitto)

## Architecture

- **Unified state model**: Every node reads from state, returns partial updates, engine applies reducers
- **Graph-based execution**: Workflow = `{nodes: {}, edges: [], schema: {}}` with `__start__` and `__end__` synthetic nodes
- **Checkpoints**: State snapshot after every node, enabling fork/replay/resume
- **Conditional edges**: Route nodes produce values, edges like `["router:yes", "next"]` are taken when route result matches
- **Deferred nodes**: Nodes with `"defer": true` execute right before `__end__`
- **Command primitive**: Workers can return `{"goto": "node_name"}` to override normal graph traversal
- **Breakpoints**: `interrupt_before` / `interrupt_after` arrays pause execution
- **Subgraph**: Inline child workflow execution with input/output mapping (max recursion depth 10)
- **Multi-turn agents**: Agent nodes can loop with `continuation_prompt` up to `max_turns`
- **Configurable runs**: Per-run config stored as `state.__config`
- **Node-level cache**: FNV hash of (node_name, rendered_prompt) with configurable TTL
- **Token accounting**: Cumulative input/output token tracking per step and per run
- **Workflow hot-reload**: `WorkflowWatcher` polls `workflows/` directory for JSON changes, upserts into DB
- **Reconciliation**: Check NullTickets task status between steps, cancel if task is terminal

### Thread Model

```
Main thread:       HTTP accept loop (push API)
Engine thread:     Graph tick loop (state-based scheduler)
Tracker thread:    Poll NullTickets -> claim -> workspace -> subprocess/dispatch
MQTT listener:     (conditional, for async MQTT workers)
Redis listener:    (conditional, for async Redis workers)
```

### SSE Streaming

5 modes for real-time consumption via `GET /runs/{id}/stream?mode=X`:
- `values` -- full state after each step
- `updates` -- node name + partial state updates
- `tasks` -- task start/finish with metadata
- `debug` -- everything with step number + timestamp
- `custom` -- user-defined events from worker output (`ui_messages`, `stream_messages`)

## Database

SQLite with WAL mode. Schema across 4 migrations:
- `001_init.sql`: workers, runs, steps, step_deps, events, artifacts
- `002_advanced_steps.sql`: cycle_state, chat_messages, saga_state (legacy, unused by current engine)
- `003_tracker.sql`: tracker_runs
- `004_orchestration.sql`: workflows, checkpoints, agent_events, pending_state_injections, node_cache, pending_writes + ALTER TABLE extensions for state_json, config_json, parent_run_id, token accounting

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
