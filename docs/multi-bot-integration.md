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

## nullTracker bridge

For `nullTracker + nullBoiler + nullClaw` end-to-end flow, run:

```bash
python3 tools/nulltracker_nullboiler_executor.py --agent-id dev-1 --agent-role llm-dev
```

Full guide: `docs/nulltracker-nullboiler-nullclaw.md`.
