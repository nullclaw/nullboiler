# MQTT & Redis Stream Dispatch Protocols

## Summary

Add MQTT and Redis Stream as dispatch protocols for NullBoiler workers, alongside existing HTTP-based protocols (webhook, api_chat, openai_chat). Uses vendored C libraries (libmosquitto, hiredis) and async two-phase dispatch with engine polling.

## Wire Format

### Request (NullBoiler → worker topic/stream)

```json
{
  "correlation_id": "run_<id>_step_<id>",
  "reply_to": "nullclaw/planner/requests/responses",
  "timestamp_ms": 1709578800000,
  "token": "worker-secret",
  "message": "rendered prompt text",
  "session_key": "run_<id>_step_<id>"
}
```

### Response (worker → response topic/stream)

```json
{
  "correlation_id": "run_<id>_step_<id>",
  "timestamp_ms": 1709578805000,
  "response": "agent output text"
}
```

Error response:
```json
{
  "correlation_id": "run_<id>_step_<id>",
  "error": "something went wrong"
}
```

`correlation_id` keys request↔response matching. `reply_to` tells the worker where to send the response.

## Config

```json
{
  "id": "planner",
  "url": "mqtt://broker:1883/nullclaw/planner/requests",
  "token": "planner-secret",
  "protocol": "mqtt",
  "tags": ["planner"],
  "max_concurrent": 1
}
```

```json
{
  "id": "builder",
  "url": "redis://redis:6379/nullclaw:builder:requests",
  "token": "builder-secret",
  "protocol": "redis_stream",
  "tags": ["builder"],
  "max_concurrent": 1
}
```

URL scheme encodes host:port and topic/stream key:
- `mqtt://host:port/topic/path` — broker + request topic. Response topic = `<request_topic>/responses`
- `redis://host:port/stream:key` — Redis + request stream. Response stream = `<stream:key>:responses`

## Async Dispatch Flow

### Phase 1: Publish (in `dispatchStep`)

For `mqtt`/`redis_stream` protocols, `dispatchStep` publishes the message and returns an async ack:

```
DispatchResult{
    .output = "",
    .success = true,
    .error_text = null,
    .async_pending = true,
    .correlation_id = "run_xxx_step_yyy",
}
```

For HTTP protocols — unchanged, `async_pending = false`.

### Phase 2: Poll (in engine tick loop)

Engine already polls running steps each tick. For steps with `async_pending` stored in `input_json`:
- Calls `pollAsyncResponse(allocator, worker_protocol, worker_url, correlation_id)`
- If response found → complete/fail step
- If not found → continue waiting (timeout via `timeout_ms`)

## Background Listeners

One background thread per protocol type (not per worker):

- **MQTT listener thread**: connects to broker, subscribes to `+/responses` wildcard, puts incoming messages into thread-safe queue (keyed by correlation_id)
- **Redis listener thread**: XREADGROUP loop on all response streams, same queue pattern

`pollAsyncResponse` checks the queue — O(1) lookup by correlation_id.

Lifecycle:
- Start in `main.zig` alongside engine thread (only if mqtt/redis_stream workers exist in config)
- Stop via `shutdown_requested` atomic (same pattern as engine)

## Vendored Libraries

- `deps/mosquitto/` — libmosquitto client (publish, subscribe, connect). Pure C, POSIX sockets only.
- `deps/hiredis/` — hiredis core (XADD, XREADGROUP, connect). Pure C.

Both linked as static C libraries via `build.zig` (same pattern as `deps/sqlite/`).

## New Files

- `src/mqtt_client.zig` — libmosquitto wrapper (publish, subscribe, connect, listener thread)
- `src/redis_client.zig` — hiredis wrapper (XADD, XREADGROUP, connect, listener thread)
- `src/async_dispatch.zig` — response queue, pollAsyncResponse, correlation logic
- `deps/mosquitto/` — vendored libmosquitto
- `deps/hiredis/` — vendored hiredis

## Modified Files

- `src/worker_protocol.zig` — add `.mqtt`, `.redis_stream` to Protocol enum, URL parsing
- `src/worker_response.zig` — unchanged (response format is the same JSON)
- `src/dispatch.zig` — two-phase dispatch for async protocols, `async_pending` field on DispatchResult
- `src/engine.zig` — poll async responses for running steps
- `src/main.zig` — start/stop listener threads
- `src/config.zig` — unchanged (workers already support arbitrary protocol strings)
- `build.zig` — add mosquitto and hiredis static lib targets

## What Does NOT Change

- `store.zig` — untouched
- `strategy.zig` — untouched
- `api.zig` — untouched (except Context already passes what's needed)
- Worker selection logic — untouched
- Existing HTTP protocols — untouched

## Error Handling

- Broker/Redis unreachable on publish → `DispatchResult.success = false`, step retries via engine
- Broker/Redis disconnect on listener → reconnect with backoff (1s, 2s, 4s, max 30s), log warning
- Response timeout → step failed, engine retry if attempts remain
- Invalid JSON in response → ignored, timeout kicks in
- Unknown correlation_id in response → ignored (stale message)

## Testing

- Unit tests: buildRequestBody for mqtt/redis_stream, URL parsing
- Unit tests: response queue put/get, correlation matching
- Unit tests: worker_protocol parse mqtt/redis_stream
- E2e: requires mock MQTT broker / Redis — manual testing initially

---

# Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add MQTT and Redis Stream as async dispatch protocols for NullBoiler workers.

**Architecture:** Vendored C libs (libmosquitto, hiredis) linked as static libraries. Two-phase async dispatch: publish returns immediately, background listener threads collect responses into a shared queue, engine polls the queue each tick.

**Tech Stack:** Zig 0.15.2, C interop via `@cImport`, libmosquitto 2.x, hiredis 1.x

---

## Phase 1: Foundation (async_dispatch + protocol enum + URL parsing)

No C deps yet — just the Zig infrastructure that everything else builds on.

---

### Task 1: Add `async_dispatch.zig` — thread-safe response queue

**Files:**
- Create: `src/async_dispatch.zig`
- Modify: `src/main.zig` (comptime import)

**Step 1: Write failing tests**

```zig
const std = @import("std");

pub const AsyncResponse = struct {
    correlation_id: []const u8,
    output: []const u8,
    success: bool,
    error_text: ?[]const u8,
    timestamp_ms: i64,
};

pub const ResponseQueue = struct {
    // Thread-safe queue keyed by correlation_id
    // ...
};

test "ResponseQueue: put and get by correlation_id" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    queue.put("corr-1", .{
        .correlation_id = "corr-1",
        .output = "hello",
        .success = true,
        .error_text = null,
        .timestamp_ms = 1000,
    });

    const resp = queue.take("corr-1");
    try std.testing.expect(resp != null);
    try std.testing.expectEqualStrings("hello", resp.?.output);

    // Second take returns null (consumed)
    try std.testing.expect(queue.take("corr-1") == null);
}

test "ResponseQueue: take returns null for unknown id" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();
    try std.testing.expect(queue.take("nonexistent") == null);
}

test "ResponseQueue: multiple correlation ids" {
    var queue = ResponseQueue.init(std.testing.allocator);
    defer queue.deinit();

    queue.put("a", .{ .correlation_id = "a", .output = "alpha", .success = true, .error_text = null, .timestamp_ms = 1 });
    queue.put("b", .{ .correlation_id = "b", .output = "beta", .success = true, .error_text = null, .timestamp_ms = 2 });

    const b = queue.take("b");
    try std.testing.expect(b != null);
    try std.testing.expectEqualStrings("beta", b.?.output);

    const a = queue.take("a");
    try std.testing.expect(a != null);
    try std.testing.expectEqualStrings("alpha", a.?.output);
}
```

**Step 2: Implement ResponseQueue**

Thread-safe via `std.Thread.Mutex`. Internal storage: `std.StringHashMap(AsyncResponse)`.

- `init(allocator)` — create empty queue
- `deinit()` — free storage
- `put(correlation_id, response)` — lock, put, unlock
- `take(correlation_id) -> ?AsyncResponse` — lock, remove and return if exists, unlock

**Step 3: Add comptime import in `main.zig`**

**Step 4: Run tests, commit**

```bash
git add src/async_dispatch.zig src/main.zig
git commit -m "feat: add thread-safe response queue for async dispatch"
```

---

### Task 2: Extend Protocol enum and URL parsing

**Files:**
- Modify: `src/worker_protocol.zig`

**Step 1: Write failing tests**

```zig
test "parse supports mqtt and redis_stream" {
    try std.testing.expectEqual(Protocol.mqtt, parse("mqtt").?);
    try std.testing.expectEqual(Protocol.redis_stream, parse("redis_stream").?);
}

test "parseMqttUrl extracts host, port, topic" {
    const result = parseMqttUrl("mqtt://broker.local:1883/nullclaw/planner/requests");
    try std.testing.expectEqualStrings("broker.local", result.host);
    try std.testing.expectEqual(@as(u16, 1883), result.port);
    try std.testing.expectEqualStrings("nullclaw/planner/requests", result.topic);
    try std.testing.expectEqualStrings("nullclaw/planner/requests/responses", result.response_topic);
}

test "parseRedisUrl extracts host, port, stream key" {
    const result = parseRedisUrl("redis://redis.local:6379/nullclaw:builder:requests");
    try std.testing.expectEqualStrings("redis.local", result.host);
    try std.testing.expectEqual(@as(u16, 6379), result.port);
    try std.testing.expectEqualStrings("nullclaw:builder:requests", result.stream_key);
    try std.testing.expectEqualStrings("nullclaw:builder:requests:responses", result.response_stream);
}
```

**Step 2: Add to Protocol enum**

```zig
pub const Protocol = enum {
    webhook,
    api_chat,
    openai_chat,
    mqtt,
    redis_stream,
};
```

Update `parse()`, `requiresModel()`, `requiresExplicitPath()`.

**Step 3: Add URL parsers**

```zig
pub const MqttUrlParts = struct {
    host: []const u8,
    port: u16,
    topic: []const u8,
    response_topic: []const u8, // allocator-owned: topic ++ "/responses"
};

pub fn parseMqttUrl(allocator: std.mem.Allocator, url: []const u8) !MqttUrlParts { ... }

pub const RedisUrlParts = struct {
    host: []const u8,
    port: u16,
    stream_key: []const u8,
    response_stream: []const u8, // allocator-owned: key ++ ":responses"
};

pub fn parseRedisUrl(allocator: std.mem.Allocator, url: []const u8) !RedisUrlParts { ... }
```

Parse `mqtt://host:port/topic/path` and `redis://host:port/stream:key`.

**Step 4: Update validateUrlForProtocol and buildRequestUrl**

mqtt/redis_stream don't need explicit path validation — they use their own URL parsers.

**Step 5: Run tests, commit**

```bash
git add src/worker_protocol.zig
git commit -m "feat: add mqtt and redis_stream protocol parsing"
```

---

### Task 3: Extend DispatchResult with async fields

**Files:**
- Modify: `src/worker_response.zig`
- Modify: `src/dispatch.zig`

**Step 1: Add fields to ParseResult**

```zig
pub const ParseResult = struct {
    output: []const u8,
    success: bool,
    error_text: ?[]const u8,
    async_pending: bool = false,
    correlation_id: ?[]const u8 = null,
};
```

Default values ensure all existing code works unchanged.

**Step 2: Add buildAsyncRequestBody to dispatch.zig**

```zig
fn buildAsyncRequestBody(
    allocator: std.mem.Allocator,
    worker_token: []const u8,
    correlation_id: []const u8,
    reply_to: []const u8,
    rendered_prompt: []const u8,
) ![]const u8 { ... }
```

Produces the wire format JSON with correlation_id, reply_to, timestamp_ms, token, message, session_key.

**Step 3: Write test for buildAsyncRequestBody**

Verify it produces valid JSON with all required fields.

**Step 4: Run tests, commit**

```bash
git add src/worker_response.zig src/dispatch.zig
git commit -m "feat: add async_pending fields and async request body builder"
```

---

### Task 4: Add async polling to engine tick loop

**Files:**
- Modify: `src/engine.zig`

**Step 1: Add async step polling**

In the running-steps poll section (around line 267), add a check for `task` type steps that have `async_pending` in their `input_json`:

```zig
} else if (std.mem.eql(u8, step.type, "task")) {
    self.pollAsyncTaskStep(alloc, run_row, step) catch |err| {
        log.err("error polling async task step {s}: {}", .{ step.id, err });
    };
}
```

**Step 2: Implement pollAsyncTaskStep**

- Parse step.input_json for `"async_pending": true` and `"correlation_id"`
- If not async → skip (normal HTTP step, already completed synchronously)
- Call `self.response_queue.take(correlation_id)`
- If response found → complete/fail step using existing patterns
- If not found → check timeout, fail if exceeded

**Step 3: Wire response_queue into Engine**

Engine gets a new field: `response_queue: *async_dispatch.ResponseQueue`
Passed from main.zig at init.

**Step 4: Update dispatchStep for async protocols**

In the dispatch flow (engine.zig ~376), after `dispatchStep` returns:
- If `final_result.async_pending` → save correlation_id to step input_json, leave step as `running`, return (don't complete/fail)
- Engine will pick it up on next tick via pollAsyncTaskStep

**Step 5: Run tests, commit**

```bash
git add src/engine.zig
git commit -m "feat: add async task step polling in engine tick loop"
```

---

## Phase 2: Vendored C Libraries + Client Wrappers

### Task 5: Vendor hiredis

**Files:**
- Create: `deps/hiredis/` (build.zig, build.zig.zon, C sources)
- Modify: `build.zig.zon` (add hiredis dependency)
- Modify: `build.zig` (link hiredis)

Download hiredis 1.x source (hiredis.c, hiredis.h, sds.c, sds.h, alloc.c, alloc.h, read.c, read.h, net.c, net.h) into `deps/hiredis/`.

Create `deps/hiredis/build.zig` following the SQLite pattern:
- `addLibrary` with `link_libc = true`
- Add all `.c` files
- Install headers

Wire into root `build.zig.zon` and `build.zig`.

**Verify: `zig build` compiles cleanly.**

```bash
git add deps/hiredis/ build.zig build.zig.zon
git commit -m "feat: vendor hiredis 1.x as static C library"
```

---

### Task 6: Vendor libmosquitto

**Files:**
- Create: `deps/mosquitto/` (build.zig, build.zig.zon, C sources)
- Modify: `build.zig.zon` (add mosquitto dependency)
- Modify: `build.zig` (link mosquitto)

Download mosquitto client library source (mosquitto.c, mosquitto.h, client-related .c files) into `deps/mosquitto/`.

Same pattern as hiredis/sqlite.

**Verify: `zig build` compiles cleanly.**

```bash
git add deps/mosquitto/ build.zig build.zig.zon
git commit -m "feat: vendor libmosquitto client as static C library"
```

---

### Task 7: Implement `redis_client.zig`

**Files:**
- Create: `src/redis_client.zig`

Zig wrapper around hiredis via `@cImport(@cInclude("hiredis.h"))`:

- `connect(host, port) -> RedisConn`
- `xadd(conn, stream_key, fields) -> void` — publish message
- `xreadgroup(conn, group, consumer, stream, count) -> []Message` — read from consumer group
- `xgroupCreate(conn, stream, group) -> void` — ensure group exists
- `disconnect(conn) -> void`

Plus a listener thread function:
- `runListener(response_queue, shutdown, configs) -> void`
- Connects to Redis, creates consumer groups, polls in a loop
- Parses response JSON, extracts correlation_id, puts into response_queue
- Reconnects with backoff on errors

Unit tests: parse URL, build XADD args (no live Redis needed).

```bash
git add src/redis_client.zig
git commit -m "feat: implement Redis Stream client wrapper"
```

---

### Task 8: Implement `mqtt_client.zig`

**Files:**
- Create: `src/mqtt_client.zig`

Zig wrapper around libmosquitto via `@cImport(@cInclude("mosquitto.h"))`:

- `connect(host, port) -> MqttConn`
- `publish(conn, topic, payload) -> void`
- `subscribe(conn, topic) -> void`
- `disconnect(conn) -> void`

Plus a listener thread function:
- `runListener(response_queue, shutdown, configs) -> void`
- Connects to broker, subscribes to response topics
- On message callback: parse JSON, extract correlation_id, put into response_queue
- Reconnects with backoff on errors

Unit tests: parse URL, build publish payload (no live broker needed).

```bash
git add src/mqtt_client.zig
git commit -m "feat: implement MQTT client wrapper"
```

---

## Phase 3: Integration + Wiring

### Task 9: Wire dispatch for MQTT/Redis protocols

**Files:**
- Modify: `src/dispatch.zig`

In `dispatchStep`, add cases for `.mqtt` and `.redis_stream`:

- Parse URL with `worker_protocol.parseMqttUrl` / `parseRedisUrl`
- Build async request body with `buildAsyncRequestBody`
- Publish via `mqtt_client.publish` / `redis_client.xadd`
- Return `DispatchResult{ .async_pending = true, .correlation_id = ... }`

Update `probeWorker` to handle mqtt/redis_stream (try connect + disconnect).

```bash
git add src/dispatch.zig
git commit -m "feat: wire MQTT and Redis Stream dispatch in dispatchStep"
```

---

### Task 10: Start/stop listener threads in main.zig

**Files:**
- Modify: `src/main.zig`

After config loading and before server start:

1. Create `ResponseQueue`
2. Scan config workers for mqtt/redis_stream protocols
3. If any mqtt workers → spawn MQTT listener thread
4. If any redis_stream workers → spawn Redis listener thread
5. Pass response_queue pointer to Engine
6. On shutdown → signal listener threads, join

```bash
git add src/main.zig
git commit -m "feat: start/stop MQTT and Redis listener threads at startup"
```

---

### Task 11: Update worker validation in main.zig

**Files:**
- Modify: `src/main.zig`

In the worker seeding loop (~line 136), update protocol validation to accept `mqtt` and `redis_stream`. URL validation uses the new parsers.

```bash
git add src/main.zig
git commit -m "feat: validate mqtt and redis_stream worker URLs at startup"
```

---

### Task 12: Update example and documentation

**Files:**
- Modify: `examples/multi-agent-slack/README.md` — add MQTT/Redis examples
- Create: `examples/multi-agent-mqtt/` — minimal MQTT example config + workflow
- Modify: `CLAUDE.md` — add mqtt/redis_stream to protocol list

```bash
git add examples/ CLAUDE.md
git commit -m "docs: add MQTT and Redis Stream dispatch examples"
```
