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

### 4) Run all night with orchestration strategy (no shell loop)

Use one run with a `loop` step that keeps executing a task step until the bot reports completion token.

```bash
curl -sS -X POST http://127.0.0.1:8080/runs \
  -H 'Content-Type: application/json' \
  -d '{
    "input": {
      "repo": "openclaw",
      "task_file": "night_tasks.md"
    },
    "steps": [
      {
        "id": "night-loop",
        "type": "loop",
        "max_iterations": 1000,
        "exit_condition": "BACKLOG_DONE",
        "body": ["execute-next-task"]
      },
      {
        "id": "execute-next-task",
        "type": "task",
        "worker_tags": ["coder"],
        "prompt_template": "Repository: {{input.repo}}\nTask source file: {{input.task_file}}\n\nDo exactly one next unchecked task from the file.\nApply code changes and tests.\nMark the task as done in the same file.\nIf no unchecked tasks remain, return exactly: BACKLOG_DONE.\nOtherwise return a short summary prefixed with: CONTINUE."
      }
    ]
  }'
```

How it works:

1. `loop` creates a child `execute-next-task` step.
2. After each iteration, NullBoiler checks child output for `BACKLOG_DONE`.
3. If found, run completes; otherwise next iteration starts automatically.

## Required worker response shape

For NullClaw integration, return synchronous JSON response:

```json
{"status":"ok","response":"...","thread_events":[...]}
```

`{"status":"received"}` without `response` is treated as an error because no synchronous step result is available for DAG progression.
