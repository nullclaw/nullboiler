# AGENTS.md — NullBoiler Engineering Protocol

Default working protocol for coding agents in this repository. Scope: entire repository.
The module map and tech stack live in [CLAUDE.md](CLAUDE.md) and are kept authoritative there.

## 1) Project Snapshot

NullBoiler is the orchestration engine of the null stack: it decides what runs,
when, and on which worker. Zig 0.16.0, vendored SQLite (WAL), HTTP/1.1 JSON REST,
worker dispatch over webhook / api_chat / openai_chat / a2a (+ MQTT, Redis Streams).

Division of labor (do not blur these boundaries):

- `nulltickets` = durable task state (source of truth)
- `nullboiler` = orchestration policy (this repo)
- `nullclaw` (or compatible workers) = execution
- `nullwatch` = traces, evals, run intelligence
- `nullhub` = install, config, UI

## 2) Architecture Facts (why this protocol exists)

These are hard-won constraints — code changes must respect them:

- The engine rebuilds the run graph from the **stored** `workflow_json`. Anything
  strategy expansion derives (e.g. `depends_on` from `applyChain`) must be
  persisted, not just used transiently (#36).
- A2A dispatch appends `/a2a` to the configured worker URL: worker URLs are
  **base** URLs. `message/send` (A2A v0.3.0) is the wire format with `kind`
  discriminators and required `messageId` (#42, #48, #53).
- Prompt templates render **strictly**: unresolved references fail the node
  visibly. Never add silent-empty fallbacks (#40).
- `on_success.transition_to` / `on_failure.transition_to` are applied as the
  pipeline FSM **trigger** name — the trigger must exist on the task's stage (#53).
- `/tracker/*` endpoints serve a published snapshot; never serve state under the
  tick mutex (#41, #50).
- Known gaps — do not build on them: synchronous worker dispatch has no timeout
  (#43); no-worker dead-ends wait silently without fail-fast (#44); MQTT and
  Redis dispatch are stubs (#32).

## 3) Engineering Principles

- KISS / YAGNI / DRY (rule of three), fail fast with explicit errors.
- Determinism: tests must not depend on network, wall-clock ordering, or system state.
- Every code change ships with tests. `zig build test --summary all` must show
  0 failures and 0 leaks. Regression tests cite the issue they guard.
- Never weaken auth paths (worker tokens, API auth) or silently swallow dispatch
  errors — unnamed failures are orchestrator bugs in themselves (#53).

## 4) Validation

```bash
zig build test --summary all   # required before every commit
zig fmt --check src/           # required before every commit
zig build                      # dev build
```

## 5) Contribution flow

See [CONTRIBUTING.md](CONTRIBUTING.md).
