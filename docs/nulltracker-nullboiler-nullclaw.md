# NullTickets + NullBoiler + NullClaw

This guide keeps its historical filename, but the tracker is now `NullTickets`.

This setup gives you:

1. `NullTickets` as durable queue/state machine (`claim`, `lease`, `transition`).
2. `nullBoiler` as workflow orchestrator.
3. `nullClaw` as execution workers behind `nullBoiler`.

## How it works

1. `nullBoiler` polls `NullTickets` directly by `agent_role`.
2. `nullBoiler` claims a task lease and materializes a run from `tracker-workflow.json`.
3. `nullBoiler` dispatches to `nullClaw` workers by `worker_tags`.
4. `nullBoiler` heartbeats the lease, records artifacts, and transitions/fails the tracker run natively.

Legacy note:

1. `tools/nulltracker_nullboiler_executor.py` still exists as a bridge for older stacks.
2. New installations should prefer native `tracker` config in `nullboiler`.

## Prerequisites

Start services:

```bash
# nulltickets
zig-out/bin/nulltickets --port 7700 --db nulltickets.db

# nullboiler
zig-out/bin/nullboiler --port 8080 --db nullboiler.db --config config.json

# nullclaw gateway(s)
nullclaw gateway --port 3000
```

## Docker Compose quick start

For the containerized stack, use root compose profiles:

```bash
# nullboiler + nullclaw + nulltickets
docker compose --profile nulltickets up -d
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

1. `NullTickets` task `agent_role` must match `nullboiler.tracker.agent_role`.
2. `nullBoiler` worker tags must match the workers able to execute the claimed role.
3. `tracker.workflow_path` should point at a workflow template available from the `nullboiler` process.

## Environment variables

Recommended native equivalents via `config.json`:

1. `tracker.url`
2. `tracker.api_token`
3. `tracker.agent_id`
4. `tracker.agent_role`
5. `tracker.workflow_path`
6. `tracker.success_trigger`
7. `tracker.max_concurrent_tasks`
8. `tracker.lease_ttl_ms`
9. `tracker.heartbeat_interval_ms`
10. `tracker.poll_interval_ms`

## Notes

1. Native tracker mode exposes status in `GET /tracker/status`, `GET /tracker/tasks`, and `GET /tracker/stats`.
2. `nullhub` can auto-link a local `nulltickets` instance to `nullboiler` and write `tracker-workflow.json` for you.
3. The legacy bridge is still available for compatibility, but it is no longer the recommended path.
