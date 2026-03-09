# NullTickets + NullBoiler + NullClaw

This setup gives you:

1. `NullTickets` as durable queue/state machine (`claim`, `lease`, `transition`).
2. `nullBoiler` as native pull-mode orchestrator.
3. `nullClaw` as subprocess executor behind `nullBoiler`.

## How it works

1. `nullBoiler` polls `NullTickets` directly by workflow `claim_roles`.
2. `nullBoiler` claims a task lease and resolves a pipeline workflow from `tracker.workflows_dir`.
3. `nullBoiler` creates a per-task workspace and runs `nullClaw` as a subprocess.
4. `nullBoiler` heartbeats the lease, posts events/artifacts, and transitions or fails the tracker run natively.

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
`docs/docker-compose-nulltickets-nullclaw.md`.

Configure `nullBoiler` tracker mode to spawn `nullClaw` directly:

```json
{
  "tracker": {
    "url": "http://127.0.0.1:7700",
    "agent_id": "boiler-dev",
    "workflows_dir": "workflows",
    "workspace": {
      "root": "workspaces"
    },
    "subprocess": {
      "command": "nullclaw"
    }
  }
}
```

Important:

1. `NullTickets` stage `agent_role` must be listed in the matching workflow file `claim_roles`.
2. `tracker.workflows_dir` must contain exactly the workflow files `nullboiler` should claim.
3. `tracker.workspace.root` should point at a writable workspace root for task checkouts/runs.

## Environment variables

Recommended native equivalents via `config.json`:

1. `tracker.url`
2. `tracker.api_token`
3. `tracker.agent_id`
4. `tracker.concurrency.max_concurrent_tasks`
5. `tracker.workflows_dir`
6. `tracker.workspace.root`
7. `tracker.subprocess.command`
8. `tracker.lease_ttl_ms`
9. `tracker.heartbeat_interval_ms`
10. `tracker.poll_interval_ms`

## Notes

1. Native tracker mode exposes status in `GET /tracker/status`, `GET /tracker/tasks`, and `GET /tracker/stats`.
2. `nullhub` can auto-link a local `nulltickets` instance to `nullboiler` and write the workflow file under `workflows/`.
3. `nullboiler` no longer supports bridge-style tracker config. Use the native `tracker` section only.
