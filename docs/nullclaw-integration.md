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
      "url": "http://localhost:3000",
      "token": "nb_worker_token_1",
      "protocol": "webhook",
      "tags": ["coder"],
      "max_concurrent": 2
    }
  ]
}
```

## Supported worker responses

NullBoiler accepts:

1. Legacy shape: `{"output":"..."}`
2. NullClaw shape: `{"status":"ok","response":"...","thread_events":[...]}`
3. Plain text body (treated as output)
4. ZeroClaw `api_chat`: `{"reply":"...","model":"..."}`
5. OpenAI chat-completions: `{"choices":[{"message":{"content":"..."}}]}`

`{"status":"received"}` without `output/response` is treated as an error because no synchronous step result is available for DAG progression.
