# NullBoiler

DAG-based workflow orchestrator for NullClaw AI bot agents. Part of the Null ecosystem (NullTracker, NullClaw).

## Tech Stack

- **Language**: Zig 0.15.2
- **Database**: SQLite (vendored in `deps/sqlite/`), WAL mode
- **Protocol**: HTTP/1.1 REST API with JSON payloads

## Module Map

| File | Role |
|------|------|
| `main.zig` | CLI args (`--port`, `--db`, `--config`, `--version`), HTTP accept loop, engine thread |
| `api.zig` | REST API routing and 16 endpoint handlers (incl. signal, chat) |
| `store.zig` | SQLite layer, 30+ CRUD methods, schema migrations |
| `engine.zig` | DAG scheduler: tick loop, 14 step type handlers, graph cycles, worker handoff |
| `dispatch.zig` | Worker selection (tags, capacity), protocol-aware HTTP dispatch (`webhook`, `api_chat`, `openai_chat`) |
| `templates.zig` | Prompt template rendering: `{{input.X}}`, `{{steps.ID.output}}`, `{{item}}`, `{{debate_responses}}`, `{{chat_history}}`, `{{role}}` |
| `callbacks.zig` | Fire-and-forget webhook callbacks on step/run events |
| `config.zig` | JSON config loader (`Config`, `WorkerConfig`, `EngineConfig`) |
| `types.zig` | `RunStatus`, `StepStatus`, `StepType` (14 types), `WorkerStatus`, row types |
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

## Step Types

`task`, `fan_out`, `map`, `condition`, `approval`, `reduce`, `loop`, `sub_workflow`, `wait`, `router`, `transform`, `saga`, `debate`, `group_chat`

## Coding Conventions

- Follow NullTracker patterns (same author)
- Arena allocators per request/tick; free everything via arena deinit
- Error handling: return errors up, log with `std.log`
- Tests: use `:memory:` SQLite, `std.testing.allocator` for leak detection
- Naming: `snake_case` everywhere
- No external dependencies beyond vendored SQLite

## Architecture

- Single-threaded HTTP accept loop on main thread
- Background engine thread polls DB for active runs
- `std.atomic.Value(bool)` for coordinated shutdown
- Config workers seeded into DB on startup (source = "config")
- Schema in `migrations/001_init.sql` + `002_advanced_steps.sql`, applied on `Store.init`
- Graph cycles: condition/router can route back to completed steps, engine creates new step instances per iteration
- Worker handoff: dispatch result can include `handoff_to` for chained delegation (max 5)

## Database

SQLite with WAL mode. Schema: 9 tables across 2 migrations.
- `001_init.sql`: workers, runs, steps, step_deps, events, artifacts
- `002_advanced_steps.sql`: cycle_state, chat_messages, saga_state + iteration_index/child_run_id columns on steps
