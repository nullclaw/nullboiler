# NullBoiler Multi-Bot Integration

NullBoiler supports multiple worker protocols per worker:

- `webhook` — `POST` JSON `{message,text,session_key,session_id}`
- `api_chat` — `POST` JSON `{message,session_id}`
- `openai_chat` — `POST` OpenAI-compatible `/chat/completions` payload

## Bot Compatibility Matrix

| Bot | Recommended protocol | URL example | Notes |
| --- | --- | --- | --- |
| NullClaw | `webhook` | `http://127.0.0.1:3000/webhook` | `response` field supported |
| ZeroClaw | `api_chat` or `webhook` | `http://127.0.0.1:42617/api/chat` | `reply` and `response` supported |
| OpenClaw / OpenAI-compatible gateways | `openai_chat` | `http://127.0.0.1:42617/v1/chat/completions` | `model` is required in worker config |
| PicoClaw | `webhook` via bridge | `http://127.0.0.1:18795/webhook` | PicoClaw gateway is WS-first (`/pico/ws`), use bridge below for sync orchestration |

## Worker config examples

```json
{
  "workers": [
    {
      "id": "nullclaw-1",
      "url": "http://127.0.0.1:3000/webhook",
      "token": "token-1",
      "protocol": "webhook",
      "tags": ["coder"],
      "max_concurrent": 2
    },
    {
      "id": "zeroclaw-1",
      "url": "http://127.0.0.1:42617/api/chat",
      "token": "token-2",
      "protocol": "api_chat",
      "tags": ["reviewer"],
      "max_concurrent": 1
    },
    {
      "id": "openclaw-1",
      "url": "http://127.0.0.1:42617/v1/chat/completions",
      "token": "token-3",
      "protocol": "openai_chat",
      "model": "anthropic/claude-sonnet-4-6",
      "tags": ["writer"],
      "max_concurrent": 1
    }
  ]
}
```

## PicoClaw bridge

Use `tools/picoclaw_webhook_bridge.py` to expose a synchronous `/webhook` endpoint backed by:

```bash
picoclaw agent --message "<prompt>" --session "<session_key>"
```

Bridge response is strict webhook-compatible JSON:

```json
{"status":"ok","response":"..."}
```

Then register that bridge endpoint in NullBoiler with protocol `webhook`.

Native pull-mode with `NullTickets` is documented in `docs/nulltickets-nullboiler-nullclaw.md`.

## A2A worker conventions

When a workflow uses `execution: "dispatch"` with `dispatch.protocol = "a2a"`:

- **Worker URL is the base URL.** The dispatcher appends `/a2a` to the configured
  worker URL itself. Configure `http://host:3000`, not `http://host:3000/a2a` —
  the latter produces `POST /a2a/a2a` and fails with `HTTP 404`.
- The dispatcher sends A2A v0.3.0 JSON-RPC (`message/send`, `kind` discriminators,
  `messageId`), requires the worker to accept it at `POST {base}/a2a`, and parses
  the reply from the result's `parts[].text` (falling back to the legacy
  `artifacts[].parts[].text` shape).

## Workflow transition conventions

`on_success.transition_to` and `on_failure.transition_to` are applied as the
pipeline FSM **trigger** name. Define the pipeline transition's `trigger` to
match the value used in the workflow (naming the trigger after its target state,
e.g. `trigger: "done"` for `to: "done"`, is the simplest convention). A trigger
name that does not exist on the task's current stage is rejected by the tracker
and the task re-enters its retry cycle.
