# External Requirements for End-to-End Flow

This file lists what **must exist** in external projects (`nullclaw`, `nulltracker`) for the current NullBoiler flow to work.

## 1) nullclaw must-have contract (for NullBoiler worker dispatch)

1. Expose an HTTP webhook endpoint with an explicit path, normally `/webhook`.
2. Accept `POST` requests with `Content-Type: application/json`.
3. Accept Bearer auth when worker `token` is configured in NullBoiler (`Authorization: Bearer <token>`).
4. Accept request body fields produced by NullBoiler webhook protocol:
   - `message` (string)
   - `text` (string)
   - `session_key` (string)
   - `session_id` (string)
5. Return HTTP `2xx` for successful execution.
6. Return a JSON object with a synchronous result in `response` (string).
   - Canonical working shape: `{"status":"ok","response":"..."}`
7. Do not return async-only ack without output for sync orchestration.
   - `{"status":"received"}` without `response` is treated by NullBoiler as an error.

## 2) nulltracker must-have contract (for tracker -> boiler executor)

The bridge script (`tools/nulltracker_nullboiler_executor.py`) depends on these APIs and semantics.

1. `POST /leases/claim`
   - Request JSON: `{"agent_id":"...","agent_role":"...","lease_ttl_ms":<int>}`
   - Responses:
     - `204` when no task is available.
     - `200` with JSON containing: `task`, `run`, `lease_id`, `lease_token`.
2. `POST /leases/{lease_id}/heartbeat`
   - Must accept header `Authorization: Bearer <lease_token>`.
   - Must return `200` while lease is valid.
3. `POST /runs/{run_id}/events`
   - Must accept header `Authorization: Bearer <lease_token>`.
   - Request JSON: `{"kind":"...","data":{...}}`
   - Expected status: `200` or `201`.
4. `POST /runs/{run_id}/transition`
   - Must accept header `Authorization: Bearer <lease_token>`.
   - Request JSON: `{"trigger":"...","usage":{...}}`
   - Expected status: `200`.
5. `POST /runs/{run_id}/fail`
   - Must accept header `Authorization: Bearer <lease_token>`.
   - Request JSON: `{"error":"...","usage":{...}}` (`usage` optional)
   - Expected status: `200`.
6. `GET /tasks/{task_id}`
   - Must return `200` with `available_transitions` list.
   - Each transition object must contain string `trigger`.
   - If this is missing, you must set bridge `SUCCESS_TRIGGER`; otherwise completed boiler runs will still end as failed tracker runs.
7. Pipeline/task role alignment must exist:
   - task current stage must be claimable by the bridge `agent_role`.
   - otherwise `POST /leases/claim` will never provide relevant work.

## 3) Optional but required for full observability

1. `POST /artifacts` in nulltracker for attaching execution reports.
   - The bridge uses payload: `task_id`, `run_id`, `kind`, `uri`, `meta`.
   - If unsupported, orchestration still works, but report artifact persistence is lost.

## 4) Compose profile requirements (if using this repo's docker-compose)

1. nullclaw must provide `GET /health` (used by compose healthcheck).
2. nulltracker must provide `GET /health` (used by compose healthcheck).
3. nullclaw pairing token must match NullBoiler worker token.
4. NullBoiler worker URL for nullclaw must include explicit path, e.g. `http://nullclaw:3000/webhook`.
