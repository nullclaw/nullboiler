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
