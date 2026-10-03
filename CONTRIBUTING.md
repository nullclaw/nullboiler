# Contributing to NullBoiler

1. **Read [AGENTS.md](AGENTS.md)** first — it defines the engineering protocol,
   architecture facts, and conventions for this repository.
2. One concern per PR. No drive-by refactors.
3. Before every commit:
   - `zig build test --summary all` — 0 failures, 0 leaks
   - `zig fmt --check src/`
4. Every PR runs the 4-target CI matrix (linux-x86_64, linux-aarch64,
   macos-aarch64, windows-x86_64). Keep it green.
5. Bug fixes must include a regression test that reproduces the original
   failure and cites the issue number.
6. API surface changes must update the OpenAPI export and the docs in
   `docs/` (including `docs/multi-bot-integration.md` for worker protocol
   changes).
