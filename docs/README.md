# NullBoiler Documentation

This directory contains integration guides for different deployment modes.

## Choose by scenario

1. Single orchestrator with NullClaw workers:
   `nullboiler + nullclaw`
   See: `single-nullclaw-integration.md`
2. Multi-agent/multi-provider orchestration:
   `nullboiler + (nullclaw | zeroclaw | openclaw | picoclaw bridge)`
   See: `multi-bot-integration.md`
3. Full async loop with durable task queue:
   `nulltickets + nullboiler + nullclaw`
   See: `nulltickets-nullboiler-nullclaw.md`
4. Containerized local stack with profiles:
   `docker compose + nullboiler + nullclaw + nulltickets`
   See: `docker-compose-nulltickets-nullclaw.md`

## Document map

- `single-nullclaw-integration.md`
  Required gateway pairing/token setup and supported response payloads.
- `multi-bot-integration.md`
  Worker protocol matrix, config examples, PicoClaw bridge, and tracker bridge entrypoint.
- `nulltickets-nullboiler-nullclaw.md`
  End-to-end native pull-mode flow, prerequisites, workflow layout, and environment variables.
- `docker-compose-nulltickets-nullclaw.md`
  Compose profiles, required config alignment, and full-stack smoke test.

## Design principle

NullBoiler stays orchestration-focused. Execution logic belongs to workers (for example NullClaw), and durable queue/state logic belongs to NullTickets. You can run each component independently or combine them per workload requirements.
