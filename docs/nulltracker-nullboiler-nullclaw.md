# nullTracker + nullBoiler + nullClaw

This setup gives you:

1. `nullTracker` as durable queue/state machine (`claim`, `lease`, `transition`).
2. `nullBoiler` as workflow orchestrator.
3. `nullClaw` as execution workers behind `nullBoiler`.

## How it works

1. Bridge executor claims a task from `nullTracker` by `agent_role`.
2. Bridge creates a `nullBoiler` run with one `task` step.
3. `nullBoiler` dispatches to `nullClaw` workers by `worker_tags`.
4. Bridge polls run status and writes events/artifact back to `nullTracker`.
5. On success bridge calls `POST /runs/{id}/transition`, otherwise `POST /runs/{id}/fail`.

## Prerequisites

Start services:

```bash
# nulltracker
zig-out/bin/nulltracker --port 7700 --db nulltracker.db

# nullboiler
zig-out/bin/nullboiler --port 8080 --db nullboiler.db --config config.json

# nullclaw gateway(s)
nullclaw gateway --port 3000
```

## Docker Compose quick start

For the containerized stack, use root compose profiles:

```bash
# nullboiler + nullclaw + nulltracker + bridge executor
docker compose --profile nulltracker up -d
```

Detailed compose guide:
`docs/docker-compose-nulltracker-nullclaw.md`.

Configure `nullBoiler` workers to point at `nullClaw`:

```json
{
  "workers": [
    {
      "id": "nullclaw-dev-1",
      "url": "http://127.0.0.1:3000/webhook",
      "token": "same_as_nullclaw_gateway_paired_token",
      "protocol": "webhook",
      "tags": ["llm-dev"],
      "max_concurrent": 2
    }
  ]
}
```

Important:

1. `nullTracker` task `agent_role` must match bridge `--agent-role`.
2. Bridge `--worker-tags` must match `nullBoiler` worker tags.

## Run bridge executor

```bash
python3 tools/nulltracker_nullboiler_executor.py \
  --tracker-base http://127.0.0.1:7700 \
  --boiler-base http://127.0.0.1:8080 \
  --agent-id dev-1 \
  --agent-role llm-dev \
  --worker-tags llm-dev
```

## Environment variables

Supported equivalents:

1. `TRACKER_BASE`
2. `NULLBOILER_BASE`
3. `NULLBOILER_TOKEN` (optional bearer token for protected nullBoiler API)
4. `AGENT_ID`
5. `AGENT_ROLE`
6. `NULLBOILER_WORKER_TAGS` (comma-separated)
7. `SUCCESS_TRIGGER` (optional fixed transition trigger)
8. `LEASE_TTL_MS`
9. `HEARTBEAT_INTERVAL_SEC`
10. `POLL_INTERVAL_SEC`
11. `CLAIM_SLEEP_SEC`
12. `HTTP_TIMEOUT_SEC`
13. `WORK_DIR`
14. `MAX_TASKS` (0 means infinite loop)

## Notes

1. Bridge writes markdown reports to `WORK_DIR` and attaches them as `nullboiler_report` artifacts in `nullTracker`.
2. If no transition is available after successful execution, bridge marks tracker run as failed to avoid stuck `running` runs.
3. This bridge is intentionally simple: one tracker claim maps to one `nullBoiler` run with one `task` step.
