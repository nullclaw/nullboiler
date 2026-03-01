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
| `api.zig` | REST API routing and 14 endpoint handlers |
| `store.zig` | SQLite layer, 22+ CRUD methods, schema migration |
| `engine.zig` | DAG scheduler: tick loop, 6 step type handlers |
| `dispatch.zig` | Worker selection (tags, capacity), HTTP POST to `/webhook` |
| `templates.zig` | Prompt template rendering: `{{input.X}}`, `{{steps.ID.output}}`, `{{item}}` |
| `callbacks.zig` | Fire-and-forget webhook callbacks on step/run events |
| `config.zig` | JSON config loader (`Config`, `WorkerConfig`, `EngineConfig`) |
| `types.zig` | `RunStatus`, `StepStatus`, `StepType`, `WorkerStatus`, row types |
| `ids.zig` | UUID v4 generation, `nowMs()` |
| `migrations/001_init.sql` | 6 tables: workers, runs, steps, step_deps, events, artifacts |

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

## Step Types

`task`, `fan_out`, `map`, `condition`, `approval`, `reduce`

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
- Schema in `migrations/001_init.sql`, applied on `Store.init`

## Database

SQLite with WAL mode. Schema: 6 tables (workers, runs, steps, step_deps, events, artifacts).
See `src/migrations/001_init.sql` for full schema.
