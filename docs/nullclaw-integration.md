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

## Example: single NullClaw bot for a real coding task

This is a pure `nullboiler + nullclaw` flow (no `nulltracker`, no bridge).

### 1) Start services

```bash
# nullclaw gateway
nullclaw gateway --port 3000

# nullboiler
zig-out/bin/nullboiler --config config.json --port 8080 --db nullboiler.db
```

### 2) Submit run: "rewrite openclaw tests from TypeScript to Go"

```bash
curl -sS -X POST http://127.0.0.1:8080/runs \
  -H 'Content-Type: application/json' \
  -d '{
    "input": {
      "repo": "openclaw",
      "goal": "rewrite tests from TypeScript to Go"
    },
    "steps": [
      {
        "id": "rewrite-tests",
        "type": "task",
        "worker_tags": ["coder"],
        "prompt_template": "Repository: {{input.repo}}\nGoal: {{input.goal}}\n\nTask:\n1) Find the TypeScript test suite.\n2) Rewrite tests to idiomatic Go tests.\n3) Keep behavior equivalent.\n4) Update test command/docs if needed.\n5) Return a concise summary of changed files and migration notes."
      }
    ]
  }'
```

Response returns run id:

```json
{"id":"<run_id>","status":"running"}
```

### 3) Poll run status

```bash
curl -sS http://127.0.0.1:8080/runs/<run_id>
```

When completed, step output is in `steps[].output_json.output`.

### 4) Run continuously all night with one bot

If you have a list of tasks, submit runs in a loop from shell (single worker still executes by capacity limits):

```bash
while IFS= read -r task; do
  curl -sS -X POST http://127.0.0.1:8080/runs \
    -H 'Content-Type: application/json' \
    -d "{\"steps\":[{\"id\":\"night-task\",\"type\":\"task\",\"worker_tags\":[\"coder\"],\"prompt_template\":\"$task\"}]}"
done < night_tasks.txt
```

## Required worker response shape

For NullClaw integration, return synchronous JSON response:

```json
{"status":"ok","response":"...","thread_events":[...]}
```

`{"status":"received"}` without `response` is treated as an error because no synchronous step result is available for DAG progression.
