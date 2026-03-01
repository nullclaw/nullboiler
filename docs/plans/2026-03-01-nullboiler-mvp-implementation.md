# NullBoiler MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a DAG-based workflow orchestrator that dispatches steps to NullClaw workers via HTTP, with SQLite persistence and crash recovery.

**Architecture:** Step-based DAG engine. Workflows submitted via REST API as JSON. Engine polls for ready steps, dispatches to NullClaw workers via POST /webhook, collects results, fires callback webhooks. SQLite stores all state for crash recovery.

**Tech Stack:** Zig 0.15.2, SQLite 3.51.2 (vendored, same as NullTracker), HTTP/1.1 stdlib server

**Reference:** Design doc at `docs/plans/2026-03-01-nullboiler-mvp-design.md`

**Convention source:** Follow NullTracker patterns at `~/Code/NullTracker/src/` — same build.zig structure, same Store pattern, same API routing style, same ids.zig.

---

## Task 1: Project Scaffold + Build System

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `deps/sqlite/` (copy from NullTracker)
- Create: `src/main.zig`
- Create: `.gitignore`

**Step 1: Copy SQLite dependency**

Copy `~/Code/NullTracker/deps` directory into NullBoiler root. It contains `deps/sqlite/` with `build.zig`, `build.zig.zon`, `sqlite3.c`, `sqlite3.h`, `sqlite3ext.h` — vendored SQLite 3.51.2.

**Step 2: Create build.zig.zon**

```zig
.{
    .name = .nullboiler,
    .version = "0.1.0",
    .minimum_zig_version = "0.15.2",
    .dependencies = .{
        .sqlite3 = .{
            .path = "deps/sqlite",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
        "deps",
    },
}
```

**Step 3: Create build.zig**

Follow NullTracker pattern exactly:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite3_dep.artifact("sqlite3");

    const exe = b.addExecutable(.{
        .name = "nullboiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(sqlite3_lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run nullboiler");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.linkLibrary(sqlite3_lib);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
```

**Step 4: Create minimal src/main.zig**

```zig
const std = @import("std");

const version = "0.1.0";

pub fn main() !void {
    std.debug.print("nullboiler v{s}\n", .{version});
}
```

**Step 5: Create .gitignore**

```
zig-out/
zig-cache/
.zig-cache/
nullboiler.db
*.db-journal
*.db-wal
*.db-shm
```

**Step 6: Build and verify**

Run: `zig build && zig build run`
Expected: prints `nullboiler v0.1.0`

**Step 7: Run tests**

Run: `zig build test`
Expected: PASS (no tests yet, but build succeeds)

**Step 8: Commit**

```
git add build.zig build.zig.zon src/main.zig deps/ .gitignore
git commit -m "feat: project scaffold with Zig build system and SQLite dep"
```

---

## Task 2: ids.zig + types.zig — Foundation Types

**Files:**
- Create: `src/ids.zig`
- Create: `src/types.zig`

**Step 1: Create src/ids.zig**

Same as NullTracker — UUID v4 generation + timestamp helper:

```zig
const std = @import("std");

pub fn generateId() [36]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var out: usize = 0;
    for (bytes, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[out] = '-';
            out += 1;
        }
        buf[out] = hex[b >> 4];
        buf[out + 1] = hex[b & 0x0f];
        out += 2;
    }
    return buf;
}

pub fn nowMs() i64 {
    return std.time.milliTimestamp();
}
```

**Step 2: Create src/types.zig**

All domain types: enums for RunStatus, StepStatus, StepType, WorkerStatus, WorkerSource. Row types for DB reads (WorkerRow, RunRow, StepRow, EventRow, ArtifactRow). API response types (HealthResponse, ErrorResponse, ErrorDetail).

Every enum gets `toString()` and `fromString()` methods. Row types use `[]const u8` for strings and `?` for nullable fields, matching NullTracker conventions.

**Step 3: Wire into main.zig for test discovery**

Add at bottom of main.zig:
```zig
comptime {
    _ = @import("ids.zig");
    _ = @import("types.zig");
}
```

**Step 4: Build and test**

Run: `zig build test`
Expected: PASS

**Step 5: Commit**

```
git add src/ids.zig src/types.zig src/main.zig
git commit -m "feat: add ids and types modules"
```

---

## Task 3: Database Schema + Store Init

**Files:**
- Create: `src/migrations/001_init.sql`
- Create: `src/store.zig`
- Modify: `src/main.zig`

**Step 1: Create src/migrations/001_init.sql**

Full schema from design doc: workers, runs, steps, step_deps, events, artifacts tables with all indexes. Use `CREATE TABLE IF NOT EXISTS` and `CREATE INDEX IF NOT EXISTS` for idempotency.

**Step 2: Create src/store.zig**

Follow NullTracker Store pattern:
- `@cImport` sqlite3.h
- `@embedFile` migration SQL
- `Store.init()`: open DB, set pragmas (WAL, NORMAL sync, foreign_keys ON, busy_timeout 5000, temp_store MEMORY, cache_size -2000), run migration
- `Store.deinit()`: close DB
- `execSimple()` helper for raw SQL execution

**Step 3: Update main.zig**

Add arg parsing (--port, --db, --version), open Store, print status. Add `comptime` import for store.zig.

**Step 4: Build and run**

Run: `zig build run`
Expected: prints version, opens DB, prints "database ready"

Run: `sqlite3 nullboiler.db ".tables"`
Expected: `artifacts  events  runs  step_deps  steps  workers`

**Step 5: Commit**

```
git add src/migrations/ src/store.zig src/main.zig
git commit -m "feat: SQLite store with schema migration"
```

---

## Task 4: Store CRUD Methods

**Files:**
- Modify: `src/store.zig`

Add all database query methods. Each method: prepare statement, bind params, step through results, collect into arena-allocated structs.

**Step 1: Worker CRUD**

- `insertWorker(id, url, token, tags_json, max_concurrent, source) !void`
- `listWorkers(allocator) ![]types.WorkerRow`
- `getWorker(allocator, id) !?types.WorkerRow`
- `deleteWorker(id) !void`
- `updateWorkerStatus(id, status, last_health_ms) !void`
- `deleteWorkersBySource(source) !void` — for config reload on startup

**Step 2: Run CRUD**

- `insertRun(id, workflow_json, input_json, callbacks_json) !void`
- `getRun(allocator, id) !?types.RunRow`
- `listRuns(allocator, status_filter, limit) ![]types.RunRow`
- `updateRunStatus(id, status, error_text) !void`
- `getActiveRuns(allocator) ![]types.RunRow` — `WHERE status IN ('running','paused')`

**Step 3: Step CRUD**

- `insertStep(...)` with all fields
- `insertStepDep(step_id, depends_on) !void`
- `getStepsByRun(allocator, run_id) ![]types.StepRow`
- `getStep(allocator, id) !?types.StepRow`
- `updateStepStatus(id, status, worker_id, output_json, error_text, attempt) !void`
- `getReadySteps(allocator, run_id) ![]types.StepRow` — core DAG query:

```sql
SELECT s.* FROM steps s
WHERE s.run_id = ? AND s.status = 'ready'
AND NOT EXISTS (
    SELECT 1 FROM step_deps d
    JOIN steps dep ON dep.id = d.depends_on
    WHERE d.step_id = s.id
    AND dep.status NOT IN ('completed', 'skipped')
)
```

- `countStepsByStatus(run_id, status) !i64`
- `getChildSteps(allocator, parent_step_id) ![]types.StepRow`

**Step 4: Event + Artifact CRUD**

- `insertEvent(run_id, step_id, kind, data_json) !void`
- `getEventsByRun(allocator, run_id) ![]types.EventRow`
- `insertArtifact(id, run_id, step_id, kind, uri, meta_json) !void`
- `getArtifactsByRun(allocator, run_id) ![]types.ArtifactRow`

**Step 5: Write unit tests**

Test with `:memory:` SQLite database:
- Init and deinit
- Insert and get run
- Insert and list workers
- Insert step with deps, verify getReadySteps
- Insert event, verify getEventsByRun

**Step 6: Run tests**

Run: `zig build test`
Expected: all PASS

**Step 7: Commit**

```
git add src/store.zig
git commit -m "feat: Store CRUD methods for all entities"
```

---

## Task 5: HTTP Server + Routing

**Files:**
- Create: `src/api.zig`
- Modify: `src/main.zig`

**Step 1: Create src/api.zig**

Follow NullTracker routing pattern:
- `Context` struct with store + allocator
- `HttpResponse` struct with status string + body + status_code
- `handleRequest(ctx, method, target, body) HttpResponse` — central router
- Path segment parsing: `parsePath()`, `getPathSegment()`, `eql()` helpers
- Route matching by method + segments for all endpoints from design doc
- Stub handlers returning 501 for unimplemented routes
- Implement `handleHealth()` returning `{"status":"ok","version":"0.1.0"}`

Full route table:
- `GET /health`
- `POST /runs`, `GET /runs`, `GET /runs/{id}`
- `POST /runs/{id}/cancel`, `POST /runs/{id}/retry`
- `GET /runs/{id}/steps`, `GET /runs/{id}/steps/{step_id}`
- `POST /runs/{id}/steps/{step_id}/approve`, `POST /runs/{id}/steps/{step_id}/reject`
- `GET /runs/{id}/events`
- `GET /workers`, `POST /workers`, `DELETE /workers/{id}`

**Step 2: Add HTTP server loop to main.zig**

Follow NullTracker main.zig:
- Listen on 127.0.0.1:port
- Accept loop with per-request arena allocator
- Read up to 1MB request
- Parse first line for method + target
- Extract body after `\r\n\r\n`
- Call `api.handleRequest()`
- Write HTTP/1.1 response with Content-Type: application/json

**Step 3: Build and test**

Run: `zig build run`
In another terminal: `curl http://localhost:8080/health`
Expected: `{"status":"ok","version":"0.1.0"}`

`curl http://localhost:8080/nonexistent`
Expected: `{"error":{"code":"not_found","message":"endpoint not found"}}`

**Step 4: Commit**

```
git add src/api.zig src/main.zig
git commit -m "feat: HTTP server with routing and handler stubs"
```

---

## Task 6: Config Loading + Worker Management API

**Files:**
- Create: `src/config.zig`
- Modify: `src/api.zig`
- Modify: `src/main.zig`

**Step 1: Create src/config.zig**

Structs: WorkerConfig, EngineConfig, Config. `loadFromFile(allocator, path)` reads JSON config file, returns parsed Config. If file doesn't exist, return defaults.

**Step 2: Load config workers on startup**

In main.zig after store init:
- Load config from `config.json` (or --config arg)
- Delete existing `source='config'` workers
- Insert each config worker into DB

**Step 3: Implement worker API handlers in api.zig**

- `handleListWorkers`: query store, serialize as JSON array, return 200
- `handleRegisterWorker`: parse body JSON, insert with source="registered", return 201
- `handleDeleteWorker`: delete by id, return 200

**Step 4: Test with curl**

```
curl http://localhost:8080/workers
curl -X POST http://localhost:8080/workers -d '{"id":"claw-3","url":"http://localhost:3003","token":"tok","tags":["tester"],"max_concurrent":2}'
curl -X DELETE http://localhost:8080/workers/claw-3
```

**Step 5: Commit**

```
git add src/config.zig src/api.zig src/main.zig
git commit -m "feat: worker management API with config loading"
```

---

## Task 7: Run Creation API (POST /runs)

**Files:**
- Modify: `src/api.zig`

The core endpoint. Parses workflow JSON, validates DAG, creates Run + Steps + deps in one transaction.

**Step 1: Define workflow parsing types**

In api.zig: `StepDef`, `RetryConfig`, `CallbackConfig`, `CreateRunRequest` structs matching the JSON format from the design doc.

**Step 2: Implement handleCreateRun**

1. Parse body as `CreateRunRequest`
2. Validate: check step types are valid, all `depends_on` reference existing step ids
3. Generate run_id (UUID v4)
4. Store frozen `workflow_json` = original body
5. INSERT run
6. For each StepDef: generate step_id, INSERT step with appropriate fields
7. For each depends_on: INSERT into step_deps
8. Mark steps with no dependencies as `ready`
9. Set run status to `running`
10. Return 201 with `{"id": run_id, "status": "running"}`

**Step 3: Implement handleGetRun**

Return run object + embedded steps array.

**Step 4: Implement handleListRuns**

Return array of runs. Support `?status=running` query parameter filter.

**Step 5: Test**

```
curl -X POST http://localhost:8080/runs -d '{
  "steps": [
    {"id": "s1", "type": "task", "worker_tags": ["coder"], "prompt_template": "Hello"},
    {"id": "s2", "type": "task", "worker_tags": ["coder"], "depends_on": ["s1"], "prompt_template": "World"}
  ],
  "input": {}
}'
```

Verify: s1 status = "ready", s2 status = "pending".

**Step 6: Commit**

```
git add src/api.zig
git commit -m "feat: POST /runs creates workflow with steps and deps"
```

---

## Task 8: Template Engine

**Files:**
- Create: `src/templates.zig`

Renders `{{...}}` expressions in prompt templates.

**Step 1: Write tests first**

```zig
test "render literal text unchanged" {
    // "Hello world" → "Hello world"
}

test "render input variable" {
    // "Hello {{input.name}}" with input={"name":"World"} → "Hello World"
}

test "render step output" {
    // "Result: {{steps.s1.output}}" → "Result: <s1 output>"
}

test "render step outputs array" {
    // "All: {{steps.s1.outputs}}" → "All: [\"r1\",\"r2\"]"
}

test "render item in map context" {
    // "Research: {{item}}" with item="AI" → "Research: AI"
}
```

**Step 2: Implement render()**

Context struct holds:
- `input`: `std.json.Value` (parsed run input)
- `step_outputs`: map of step_id to single output string
- `step_outputs_array`: map of step_id to array of output strings
- `item`: optional string for map iterations

Scan template for `{{...}}`, parse dot-path, resolve against context:
- `input.X` → look up key X in input JSON
- `steps.ID.output` → single output
- `steps.ID.outputs` → JSON-serialized array
- `item` → current map item

**Step 3: Run tests**

Run: `zig build test`
Expected: all template tests PASS

**Step 4: Commit**

```
git add src/templates.zig
git commit -m "feat: template engine for prompt rendering"
```

---

## Task 9: Worker Dispatch (HTTP Client)

**Files:**
- Create: `src/dispatch.zig`

Sends rendered prompts to NullClaw workers.

**Step 1: Implement selectWorker()**

Takes: list of workers, required tags, set of currently busy worker IDs.
Returns: best available worker or null.
Logic: filter active workers, check tag intersection, exclude overloaded, pick first match.

**Step 2: Implement dispatchStep()**

Uses `std.http.Client` to POST to `{worker.url}/webhook`:
- Headers: `Authorization: Bearer {worker.token}`, `Content-Type: application/json`
- Body: `{"message": rendered_prompt, "session_key": "run_{run_id}_step_{step_id}"}`
- Parse response JSON for `output` field
- Return `DispatchResult{output, status, error_text}`

**Step 3: Write tests for selectWorker**

Test tag matching, capacity filtering, dead worker exclusion.

**Step 4: Commit**

```
git add src/dispatch.zig
git commit -m "feat: worker dispatch module"
```

---

## Task 10: DAG Engine — Scheduler Loop

**Files:**
- Create: `src/engine.zig`
- Modify: `src/main.zig`

The heart of NullBoiler.

**Step 1: Engine struct**

Fields: store, allocator, poll_interval_ns, running (atomic bool).
Methods: init(), stop(), run() (main loop).

**Step 2: Implement tick() — single iteration**

Get active runs, process each.

**Step 3: Implement processRun()**

For each run:
1. Get all steps
2. Promote pending steps to ready (if all deps completed/skipped)
3. Process ready steps by type
4. Check run completion

**Step 4: Implement step type handlers**

- `executeTaskStep()`: render template, select worker, dispatch, save result
- `executeFanOutStep()`: create N child steps from `count`, mark as ready
- `executeMapStep()`: resolve `items_from` against run input, create child steps per item
- `executeReduceStep()`: collect child outputs, render template, dispatch to worker
- `executeConditionStep()`: evaluate expression, mark winning branch ready, skip others
- `executeApprovalStep()`: set status to waiting_approval

**Step 5: Implement checkRunCompletion()**

If all steps completed/skipped → run completed.
If any failed with no retries and all others done → run failed.

**Step 6: Start engine thread in main.zig**

Spawn engine.run() on a separate thread before the HTTP accept loop. On shutdown, call engine.stop() and join thread.

**Step 7: Commit**

```
git add src/engine.zig src/main.zig
git commit -m "feat: DAG engine scheduler with all step types"
```

---

## Task 11: Callbacks Module

**Files:**
- Create: `src/callbacks.zig`
- Modify: `src/engine.zig`

**Step 1: Implement fireCallbacks()**

Parse callbacks_json, for each matching callback (event kind matches filter), POST payload to URL with configured headers. Fire-and-forget: log errors but don't block.

**Step 2: Integrate into engine**

Call fireCallbacks after: step completed, step failed, run completed, run failed.

**Step 3: Commit**

```
git add src/callbacks.zig src/engine.zig
git commit -m "feat: webhook callback notifications"
```

---

## Task 12: Implement Remaining API Handlers

**Files:**
- Modify: `src/api.zig`

**Step 1: handleCancelRun**

Set run status to "cancelled", mark pending/ready steps as "skipped".

**Step 2: handleRetryRun**

Find failed steps, reset to "ready", increment attempt, set run back to "running".

**Step 3: handleListSteps, handleGetStep**

Query store, return JSON.

**Step 4: handleApproveStep**

Verify step is in "waiting_approval", change to "completed".

**Step 5: handleRejectStep**

Change waiting_approval step to "failed".

**Step 6: handleListEvents**

Query events by run_id, return JSON array.

**Step 7: handleHealth with real stats**

Query active run count, total worker count from store.

**Step 8: Commit**

```
git add src/api.zig
git commit -m "feat: implement all API handlers"
```

---

## Task 13: End-to-End Test Script

**Files:**
- Create: `tests/test_e2e.sh`

Shell script that:
1. Starts NullBoiler with temp DB on random port
2. Tests GET /health
3. Tests worker registration
4. Tests run creation and GET
5. Tests listing endpoints
6. Cleans up on exit

Run: `zig build && bash tests/test_e2e.sh`
Expected: ALL TESTS PASSED

**Commit:**
```
git add tests/test_e2e.sh
git commit -m "test: end-to-end integration tests"
```

---

## Task 14: Full Demo with Mock Workers

**Files:**
- Create: `tests/mock_worker.py`
- Modify: `tests/test_e2e.sh`

**Step 1: Create mock NullClaw worker**

Simple Python HTTP server that accepts POST /webhook and returns `{"output": "Mock response to: <first 50 chars of message>"}`.

**Step 2: Add workflow tests**

Start mock workers on different ports, register them, submit research pipeline workflow, poll until completion, verify status.

**Step 3: Run**

Run: `zig build && bash tests/test_e2e.sh`
Expected: RESEARCH PIPELINE: PASSED

**Step 4: Commit**

```
git add tests/mock_worker.py tests/test_e2e.sh
git commit -m "test: full workflow demo with mock workers"
```

---

## Task 15: Config Example + Project Guide

**Files:**
- Create: `config.example.json`
- Create: `CLAUDE.md`

**Step 1: config.example.json**

Full example with workers, engine settings, comments as field names.

**Step 2: CLAUDE.md**

Project guide: tech stack, module map, build/test/run commands, coding conventions (follow NullTracker patterns).

**Step 3: Commit**

```
git add config.example.json CLAUDE.md
git commit -m "docs: config example and CLAUDE.md project guide"
```

---

## Dependency Graph

```
Task 1 (scaffold)
  +-- Task 2 (ids + types)
       +-- Task 3 (schema + store init)
            +-- Task 4 (store CRUD)
                 |-- Task 5 (HTTP server + routing)
                 |    |-- Task 6 (worker API)
                 |    |-- Task 7 (run creation API)
                 |    +-- Task 12 (remaining handlers)
                 |-- Task 8 (template engine)
                 |-- Task 9 (worker dispatch)
                 +-- Task 10 (DAG engine) <-- depends on 4, 8, 9
                      +-- Task 11 (callbacks)
                           +-- Task 12 (remaining handlers)
                                +-- Task 13 (e2e tests)
                                     +-- Task 14 (full demo)
                                          +-- Task 15 (config + docs)
```

## Critical Path

1 -> 2 -> 3 -> 4 -> 8 -> 9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 15

Tasks 5, 6, 7 can proceed in parallel with 8, 9 once Task 4 is done.
