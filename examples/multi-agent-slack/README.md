# Multi-Agent Slack Orchestration via NullBoiler

Orchestrate multiple NullClaw agents (planner + builder) through NullBoiler's DAG engine, with Slack as a notification channel.

## Architecture

```
                    NullBoiler (orchestrator)
                   /          |           \
            dispatch      dispatch      callbacks
               |              |             |
       [planner agent]  [builder agent]  [Slack webhook]
       nullclaw :3001   nullclaw :3002   #project-updates
```

**How it works:**

1. Two NullClaw instances run as NullBoiler workers — each with its own system prompt, model, and gateway port
2. You create a workflow run via NullBoiler's API, using a strategy (sequential, parallel, or custom DAG)
3. NullBoiler dispatches tasks to the right worker based on `worker_tags`
4. Each NullClaw agent processes the task and returns results via HTTP
5. NullBoiler chains outputs between steps — the builder gets the planner's output as context
6. Optional Slack webhook fires on step/run completion for visibility

**Why this is better than agents talking through Slack messages:**

- NullBoiler manages ordering, retries, timeouts, and failure handling
- Clean separation: orchestration (NullBoiler) vs execution (NullClaw) vs notification (Slack)
- Full observability via NullBoiler's events API
- Easy to add more agents, change strategies, or add approval gates
- No Slack rate-limit issues from message-based orchestration

## Prerequisites

- NullBoiler binary (see root README for build instructions)
- Two NullClaw instances (or one with two configs)
- Optional: Slack incoming webhook for notifications

## Quick Start

```sh
# 1. Start NullBoiler with the example config
../../zig-out/bin/nullboiler --config config.json --port 8080

# 2. Start planner agent (separate terminal)
nullclaw gateway --port 3001 --config planner-config.json

# 3. Start builder agent (separate terminal)
nullclaw gateway --port 3002 --config builder-config.json

# 4. Submit a workflow
./run-workflow.sh "Build a REST API for a todo app in Go"
```

## Files

| File | Purpose |
|------|---------|
| `config.json` | NullBoiler config — registers both agents as workers |
| `planner-config.json` | NullClaw config for the planner agent |
| `builder-config.json` | NullClaw config for the builder agent |
| `workflows/plan-then-build.json` | Sequential: planner -> builder |
| `workflows/parallel-research.json` | Parallel: both agents research, then reduce |
| `workflows/plan-build-review.json` | DAG: planner -> builder -> planner (review) |
| `run-workflow.sh` | Helper script to submit a workflow with a goal |

## Workflow Examples

### Sequential: Plan then Build

The planner breaks down the goal into steps, then the builder executes them.

```sh
curl -X POST http://localhost:8080/runs \
  -H "Content-Type: application/json" \
  -d @- <<'EOF'
{
  "strategy": "sequential",
  "steps": [
    {
      "id": "plan",
      "type": "task",
      "worker_tags": ["planner"],
      "prompt_template": "Break down this goal into concrete implementation steps:\n\n{{input.goal}}"
    },
    {
      "id": "build",
      "type": "task",
      "worker_tags": ["builder"],
      "prompt_template": "Execute this implementation plan:\n\n{{steps.plan.output}}"
    }
  ],
  "input": {"goal": "Build a REST API for a todo app in Go"}
}
EOF
```

### Parallel Research with Reduce

Both agents research independently, then results are combined.

```sh
curl -X POST http://localhost:8080/runs \
  -H "Content-Type: application/json" \
  -d @- <<'EOF'
{
  "strategy": "parallel",
  "steps": [
    {
      "id": "arch_research",
      "type": "task",
      "worker_tags": ["planner"],
      "prompt_template": "Research architecture patterns for: {{input.goal}}"
    },
    {
      "id": "impl_research",
      "type": "task",
      "worker_tags": ["builder"],
      "prompt_template": "Research implementation approaches and libraries for: {{input.goal}}"
    }
  ],
  "reduce": {
    "id": "synthesize",
    "worker_tags": ["planner"],
    "prompt_template": "Synthesize these research findings into a unified plan:\n\nArchitecture: {{steps.arch_research.output}}\n\nImplementation: {{steps.impl_research.output}}"
  },
  "input": {"goal": "Real-time collaborative editor"}
}
EOF
```

### Custom DAG: Plan -> Build -> Review

Manual `depends_on` for a three-step workflow where the planner reviews the builder's work.

```sh
curl -X POST http://localhost:8080/runs \
  -H "Content-Type: application/json" \
  -d @- <<'EOF'
{
  "steps": [
    {
      "id": "plan",
      "type": "task",
      "worker_tags": ["planner"],
      "prompt_template": "Create a detailed plan for: {{input.goal}}"
    },
    {
      "id": "build",
      "type": "task",
      "worker_tags": ["builder"],
      "depends_on": ["plan"],
      "prompt_template": "Implement this plan:\n\n{{steps.plan.output}}"
    },
    {
      "id": "review",
      "type": "task",
      "worker_tags": ["planner"],
      "depends_on": ["build"],
      "prompt_template": "Review this implementation against the original plan.\n\nPlan: {{steps.plan.output}}\n\nImplementation: {{steps.build.output}}\n\nList issues found or confirm it meets requirements."
    }
  ],
  "input": {"goal": "Build a CLI tool for managing Docker containers"},
  "callbacks": [
    {
      "url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
      "events": ["run.completed", "run.failed"]
    }
  ]
}
EOF
```

## Monitoring

```sh
# Check run status
curl http://localhost:8080/runs/{run_id}

# Watch step progress
curl http://localhost:8080/runs/{run_id}/steps

# Stream events
curl http://localhost:8080/runs/{run_id}/events
```

## Slack Notifications

Add a `callbacks` field to your workflow to get Slack notifications:

```json
{
  "callbacks": [
    {
      "url": "https://hooks.slack.com/services/T.../B.../xxx",
      "events": ["step.completed", "step.failed", "run.completed", "run.failed"]
    }
  ]
}
```

NullBoiler fires webhooks on step/run events. Format matches Slack incoming webhook expectations.
