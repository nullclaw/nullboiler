# Docker Compose: nullBoiler + nullClaw + nullTracker

This guide describes how to run `nullboiler`, `nullclaw`, and `nulltracker` together with the root `docker-compose.yml`.

## 1. Prerequisites

1. Clone dependencies into `reference/`:

```bash
git clone https://github.com/nullclaw/nullclaw reference/nullclaw
git clone https://github.com/nullclaw/nulltracker reference/nulltracker
```

2. Verify token alignment between:

- `docker/nullclaw.config.json` -> `gateway.paired_tokens[0]`
- `docker/nullboiler.config.json` -> `workers[0].token`

3. Set a valid provider key in `docker/nullclaw.config.json` (`api_key` field).
4. Optional hardening: set `api_token` in `docker/nullboiler.config.json` and export the same token as `NULLBOILER_TOKEN` before `docker compose up`.

## 2. Compose profiles

The repository uses one compose file with profile-based stacks.

1. `nullboiler` only:

```bash
docker compose up -d nullboiler
```

2. `nullboiler + nullclaw`:

```bash
docker compose --profile nullclaw up -d
```

3. Full async stack (`nullboiler + nullclaw + nulltracker + executor`):

```bash
docker compose --profile nulltracker up -d
```

## 3. Service roles in full stack

1. `nullboiler` listens on `:8080` and orchestrates workflows.
2. `nullclaw` listens on `:3000` and executes worker calls from `nullboiler`.
3. `nulltracker` listens on `:7700` and stores tasks/runs/leases.
4. `nulltracker-executor` claims tasks from `nulltracker`, creates runs in `nullboiler`, and writes status/events back.

## 4. Health checks

```bash
curl -fsS http://127.0.0.1:8080/health
curl -fsS http://127.0.0.1:3000/health
curl -fsS http://127.0.0.1:7700/health
docker compose logs -f nulltracker-executor
```

## 5. Minimal task flow test (full stack)

1. Create a pipeline:

```bash
curl -sS -X POST http://127.0.0.1:7700/pipelines \
  -H 'content-type: application/json' \
  -d '{
    "name":"llm-dev-pipeline",
    "definition":{
      "initial":"todo",
      "states":{
        "todo":{"agent_role":"llm-dev"},
        "done":{"terminal":true}
      },
      "transitions":[
        {"from":"todo","to":"done","trigger":"complete"}
      ]
    }
  }'
```

2. Create a task for the same role:

```bash
curl -sS -X POST http://127.0.0.1:7700/tasks \
  -H 'content-type: application/json' \
  -d '{
    "pipeline_id":"<pipeline_id>",
    "title":"Compose integration check",
    "description":"Run through nullboiler and complete this task.",
    "priority":0,
    "metadata":{"source":"compose-smoke-test"}
  }'
```

3. Watch execution:

```bash
docker compose logs -f nulltracker-executor
```

## 6. Stop stack

```bash
docker compose down
```

To remove persisted databases/volumes:

```bash
docker compose down -v
```
