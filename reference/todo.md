# NullBoiler Production Gaps vs OpenClaw-Ready Orchestrators

This backlog tracks the main gaps that prevent `nullboiler` from matching production-ready orchestrators commonly used with OpenClaw-compatible ecosystems.

## P0 (Critical)

- [x] `P0-01` API authentication and authorization boundary (token-based access for non-health endpoints).
- [x] `P0-02` Atomic run creation with DB transaction (no partial run/step persistence on failure).
- [ ] `P0-03` Worker health checks + quarantine/circuit-breaker states (dead/draining lifecycle automation).
- [ ] `P0-04` Idempotent run submission (idempotency key to prevent duplicate workflow launches).

## P1 (High)

- [ ] `P1-01` Retry policy upgrades: exponential backoff + jitter + max elapsed time.
- [ ] `P1-02` Dead-letter handling for terminally failed runs/steps.
- [ ] `P1-03` Structured observability: request IDs, metrics endpoint, OTEL spans.
- [ ] `P1-04` API pagination/filtering for runs, steps, events, workers.
- [ ] `P1-05` Admission control and rate limiting (per IP/token and global caps).
- [ ] `P1-06` Graceful shutdown and drain mode for in-flight steps.

## P2 (Medium)

- [ ] `P2-01` Signed callbacks/webhooks (HMAC) and replay protection.
- [ ] `P2-02` Multi-tenant namespace boundaries (projects/tenants/quotas).
- [ ] `P2-03` Workflow versioning and deterministic replay diagnostics.
- [ ] `P2-04` OpenAPI spec + generated client SDK for automation integrations.

## Current Execution

- [x] `P0-01` completed: bearer auth implemented in API path, config/CLI wiring added, and nulltracker bridge updated with optional token propagation.
- [x] `P0-02` completed: `POST /runs` now wrapped in DB transaction with rollback on any failure.
- [ ] Next: `P0-03` worker health checks + circuit-breaker states.
