# NullBoiler + NullClaw Integration

This project dispatches workflow `task`/`reduce`/chat steps to NullClaw gateway workers.

## Required NullClaw setup

Configure each NullClaw gateway with a static paired token:

```json
{
  "gateway": {
    "host": "127.0.0.1",
    "port": 3000,
    "require_pairing": true,
    "paired_tokens": ["nb_worker_token_1"]
  }
}
```

Start gateway:

```bash
nullclaw gateway --port 3000
```

## Required NullBoiler setup

Point worker `url` to NullClaw gateway and use the same token from `gateway.paired_tokens`:

```json
{
  "workers": [
    {
      "id": "nullclaw-1",
      "url": "http://localhost:3000/webhook",
      "token": "nb_worker_token_1",
      "protocol": "webhook",
      "tags": ["coder"],
      "max_concurrent": 2
    }
  ]
}
```

## Example: one bot works all night

If you want one agent to keep taking tasks overnight, use:

1. `nullclaw` as worker runtime
2. `nullboiler` as orchestrator
3. `nulltracker` as task queue
4. `tools/nulltracker_nullboiler_executor.py` as the bridge loop

### 1) Start services

```bash
# 1) nullclaw gateway
nullclaw gateway --port 3000

# 2) nullboiler
zig-out/bin/nullboiler --config config.json --port 8080 --db nullboiler.db

# 3) nulltracker
zig-out/bin/nulltracker --port 7700 --db nulltracker.db
```

If `nullboiler` uses API token auth, export it before starting bridge:

```bash
export NULLBOILER_TOKEN="your_nullboiler_api_token"
```

### 2) Run a single long-running bridge worker

Use one agent identity and one role. The role should match your tracker stage role.

```bash
python3 tools/nulltracker_nullboiler_executor.py \
  --tracker-base http://127.0.0.1:7700 \
  --boiler-base http://127.0.0.1:8080 \
  --agent-id night-bot-1 \
  --agent-role llm-dev \
  --worker-tags coder \
  --max-tasks 0
```

`--max-tasks 0` means infinite loop (keep processing tasks all night).

### 3) Create tracker pipeline and tasks

Create a pipeline where the initial stage is owned by the same role (`llm-dev`):

```bash
curl -sS -X POST http://127.0.0.1:7700/pipelines \
  -H 'content-type: application/json' \
  -d '{
    "name":"night-bot",
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

Create tasks in that pipeline (repeat as needed):

```bash
curl -sS -X POST http://127.0.0.1:7700/tasks \
  -H 'content-type: application/json' \
  -d '{
    "pipeline_id":"<pipeline_id>",
    "title":"Night task 1",
    "description":"Implement and test feature X.",
    "priority":0
  }'
```

### 4) Observe execution

1. Bridge logs: task claim, run status changes, transition/fail results.
2. `GET http://127.0.0.1:8080/runs` to inspect nullboiler runs.
3. `GET http://127.0.0.1:7700/tasks/<task_id>` to inspect tracker state.

## Supported worker responses

NullBoiler accepts:

1. NullClaw shape: `{"status":"ok","response":"...","thread_events":[...]}`
2. ZeroClaw `api_chat`: `{"reply":"...","model":"..."}`
3. OpenAI chat-completions: `{"choices":[{"message":{"content":"..."}}]}`

`{"status":"received"}` without `response` is treated as an error because no synchronous step result is available for DAG progression.
