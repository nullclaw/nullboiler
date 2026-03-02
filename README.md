# NullBoiler

NullBoiler is an orchestration engine for AI agents.

It is intentionally narrow: it decides what should run, when it should run, and which worker should execute it.  
It does not replace the task tracker and it does not replace the agent runtime.

You do not need all components together.  
Choose only the pieces required for your workflow.

## Design Principle

`tracker = source of truth`  
`orchestrator = policy engine`  
`agent = executor`

### 1) Tracker: [nulltickets](https://github.com/nullclaw/nulltickets)

Use nulltickets as the authoritative task system for AI agents:

- Stores tasks, states, priorities, and ownership.
- Preserves durable history of task lifecycle.
- Acts as the canonical queue/source of truth for pending work.

### 2) Orchestrator: [nullboiler](https://github.com/nullclaw/nullboiler)

Use nullboiler to apply orchestration policy:

- Pulls/selects work from tracker or another source.
- Applies scheduling and routing strategies.
- Enforces concurrency limits, retries, and backoff policies.
- Dispatches work to one or many agents/workers.

NullBoiler should not become a task tracker or artifact database.

### 3) Agent Runtime: [nullclaw](https://github.com/nullclaw/nullclaw) or another compatible worker

Use an agent runtime as the execution engine:

- Receives a concrete task/job to run.
- Executes tools, code, and model interactions.
- Returns execution outputs/events back to the orchestrator/tracker flow.

`nullclaw` is the reference runtime, but `nullboiler` can also orchestrate other compatible workers
(for example OpenClaw/OpenAI-compatible, ZeroClaw, or PicoClaw via bridge).

Agents should execute work, not own global orchestration policy.

## Why This Separation Exists

Teams often try to move tracker and artifact responsibilities into the orchestrator.  
This project keeps boundaries strict on purpose:

- Tracker owns durable truth.
- Orchestrator owns coordination policy.
- Agent owns execution.

This keeps the architecture modular, simpler to reason about, and easier to evolve.

## Supported Compositions

- `nullclaw` only: single-agent direct execution.
- `nullboiler + nullclaw`: orchestrated execution without dedicated tracker.
- `nullboiler + other compatible agents`: orchestrated execution without `nullclaw` dependency.
- `nulltickets + nullclaw`: tracker-driven execution loop.
- `nulltickets + nullboiler + nullclaw`: full multi-agent orchestration with durable task source.

See additional integration docs in [`docs/`](./docs).
