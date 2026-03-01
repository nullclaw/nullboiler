# Single NullClaw Integration

Use this mode when you want `nullboiler` to orchestrate tasks through one `nullclaw` worker setup (without `nulltracker`).

## 1) Configure NullClaw gateway

Set a static paired token in NullClaw config:

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

## 2) Configure NullBoiler worker

Use the same token and an explicit webhook path:

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

Start NullBoiler:

```bash
zig-out/bin/nullboiler --config config.json --port 8080 --db nullboiler.db
```

## 3) Example task run

Example request for: "rewrite openclaw tests from TypeScript to Go".

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
        "prompt_template": "Repository: {{input.repo}}\\nGoal: {{input.goal}}\\n\\nTask:\\n1) Find the TypeScript test suite.\\n2) Rewrite tests to idiomatic Go tests.\\n3) Keep behavior equivalent.\\n4) Update test command/docs if needed.\\n5) Return a concise summary of changed files and migration notes."
      }
    ]
  }'
```

Expected create-run response:

```json
{"id":"<run_id>","status":"running"}
```

Track progress:

```bash
curl -sS http://127.0.0.1:8080/runs/<run_id>
```

Final task output is in `steps[].output_json.output`.

## 4) Overnight mode with built-in orchestration strategy

Use one run with `loop` strategy. Each iteration executes one task unit and stops only when worker returns `BACKLOG_DONE`.

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
        "prompt_template": "Repository: {{input.repo}}\\nTask source file: {{input.task_file}}\\n\\nDo exactly one next unchecked task from the file.\\nApply code changes and tests.\\nMark the task as done in the same file.\\nIf no unchecked tasks remain, return exactly: BACKLOG_DONE.\\nOtherwise return a short summary prefixed with: CONTINUE."
      }
    ]
  }'
```

## 5) Required NullClaw response contract

NullBoiler expects synchronous JSON response from webhook workers:

```json
{"status":"ok","response":"...","thread_events":[...]}
```

`{"status":"received"}` without `response` is treated as an error because there is no synchronous output for DAG progression.
