# NullBoiler Advanced Step Types — Design

## Overview

Extend NullBoiler's step type system from 6 to 14 types, plus 2 engine features, to achieve full orchestration parity with top vendors (AG2, CrewAI, LangGraph, OpenAI Agents SDK, AWS Step Functions, Temporal, Google ADK).

**Goal:** Cover every major orchestration pattern so NullBoiler can handle any workflow that competing orchestrators can.

**Existing step types (MVP):** `task`, `fan_out`, `map`, `condition`, `approval`, `reduce`

## New Step Types

### 1. `loop` — Iterative Repetition

Wraps a sequence of child steps and repeats until a condition is met or max_iterations reached. Inspired by Google ADK LoopAgent and LangGraph cycles.

```json
{
  "id": "code_fix_loop",
  "type": "loop",
  "max_iterations": 10,
  "exit_condition": "steps.test.output contains ALL TESTS PASSED",
  "body": ["code", "test"],
  "depends_on": ["plan"]
}
```

**Behavior:**
- Creates child step instances for each body step on every iteration
- After each iteration, evaluates `exit_condition` against the last body step's output
- If condition met or `max_iterations` reached → loop step marks completed
- Child steps get `iteration_index` field for tracking
- Output: last iteration's final step output

**Error handling:**
- `max_iterations` required — engine enforces hard stop
- Body step failure → loop immediately fails
- Empty body → validation error at run creation

---

### 2. `sub_workflow` — Workflow Composition

Invokes another workflow definition as a nested step. Inspired by AWS Step Functions and Temporal child workflows.

```json
{
  "id": "run_review",
  "type": "sub_workflow",
  "workflow": {
    "steps": [
      {"id": "lint", "type": "task", "worker_tags": ["linter"], "prompt_template": "Lint: {{input.code}}"},
      {"id": "review", "type": "task", "depends_on": ["lint"], "worker_tags": ["reviewer"], "prompt_template": "Review: {{steps.lint.output}}"}
    ]
  },
  "input_mapping": {"code": "{{steps.code.output}}"},
  "depends_on": ["code"]
}
```

**Behavior:**
- Creates a child Run in the DB with the nested workflow definition
- Maps parent step outputs into child run input via `input_mapping`
- Parent step stays "running" until child run completes
- On child completion: parent step output = child run's final step output
- On child failure: parent step fails

**Error handling:**
- Circular nesting: depth limit of 5
- Parent run cancellation → child runs cascade-cancel

---

### 3. `wait` — Timer / Signal Pause

Pauses execution for a duration, until a timestamp, or until an external signal. Inspired by AWS Wait and Temporal timers+signals.

```json
{"id": "cooldown", "type": "wait", "duration_ms": 60000}
```
```json
{"id": "scheduled", "type": "wait", "until_ms": 1709400000000}
```
```json
{"id": "wait_for_deploy", "type": "wait", "signal": "deploy_complete"}
```

**Behavior:**
- `duration_ms` — pause for N milliseconds from when step becomes ready
- `until_ms` — pause until absolute timestamp
- `signal` — pause until `POST /runs/{id}/steps/{step_id}/signal` called
- Output: `{"waited_ms": N}` or `{"signal": "deploy_complete", "data": {...}}`

**Error handling:**
- Signal timeout: optional `timeout_ms` — if signal doesn't arrive, step fails
- Server restart: wait state persists in DB, resumes on restart

---

### 4. `router` — Dynamic N-way Routing

Evaluates an expression and routes to one of N target steps. Extends `condition` from binary to N-ary. Inspired by OpenAI Swarm handoff and CrewAI @router.

```json
{
  "id": "route",
  "type": "router",
  "depends_on": ["classify"],
  "expression": "steps.classify.output",
  "routes": {
    "bug": "fix_bug",
    "feature": "implement_feature",
    "refactor": "refactor_code"
  },
  "default": "fix_bug"
}
```

**Behavior:**
- Extracts value from expression (step output)
- Matches against route keys (exact match or contains)
- Activates matched target step, skips all others
- Falls back to `default` if no match
- Output: `{"routed_to": "fix_bug"}`

**Error handling:**
- No match + no default → step fails with "no matching route"
- Multiple matches → first match wins

---

### 5. `transform` — Pure Data Transformation

Reshapes data without dispatching to any worker. Like AWS Pass state.

```json
{
  "id": "prepare_input",
  "type": "transform",
  "output_template": "{\"combined\": \"{{steps.a.output}} + {{steps.b.output}}\", \"count\": {{input.n}}}"
}
```

**Behavior:**
- Renders `output_template` using the same template context as task steps
- No worker dispatch — runs entirely in the engine
- Instant completion
- Useful for data reshaping between steps

---

### 6. `saga` — Compensation Wrapper

Wraps a sequence of steps with ordered rollback on failure. Inspired by Temporal's saga pattern.

```json
{
  "id": "deploy_saga",
  "type": "saga",
  "body": ["provision", "deploy", "verify"],
  "compensations": {
    "provision": "deprovision",
    "deploy": "rollback_deploy"
  }
}
```

**Behavior:**
- Executes body steps sequentially
- If any body step fails (after retries): stops forward execution
- Runs compensation steps in reverse order for all *completed* body steps
- Saga step itself marks failed after compensation completes
- Output: `{"failed_at": "verify", "compensated": ["deploy", "provision"]}`

**Error handling:**
- Compensation step failure → saga marks "compensation_failed", run fails with both errors
- Partial compensation → failed compensations reported in output
- Nested saga → supported, compensations run innermost first

---

### 7. `debate` — Single-Round Committee

Sends same prompt to N workers, then a judge worker picks the best response. Inspired by AG2 group chat (single-round variant).

```json
{
  "id": "code_review",
  "type": "debate",
  "worker_tags": ["reviewer"],
  "judge_tags": ["senior_reviewer"],
  "count": 3,
  "prompt_template": "Review: {{steps.code.output}}",
  "judge_template": "Pick best review:\n{{debate_responses}}"
}
```

**Behavior:**
- Dispatches `prompt_template` to `count` workers matching `worker_tags`
- Collects all responses
- Renders `judge_template` with `{{debate_responses}}` containing all responses
- Dispatches judge prompt to a worker matching `judge_tags`
- Output: judge's response

**Error handling:**
- Worker unavailable → skip that participant, note in output
- All workers unavailable → step fails

---

### 8. `group_chat` — Multi-Turn Deliberation

Multiple workers exchange messages in rounds until consensus or max_rounds. Inspired by AG2 group chat and CrewAI hierarchical process.

```json
{
  "id": "design_discussion",
  "type": "group_chat",
  "participants": [
    {"tags": ["architect"], "role": "Architect"},
    {"tags": ["security"], "role": "Security Lead"},
    {"tags": ["frontend"], "role": "Frontend Dev"}
  ],
  "max_rounds": 5,
  "exit_condition": "CONSENSUS REACHED",
  "prompt_template": "Discuss: {{input.topic}}",
  "round_template": "Previous discussion:\n{{chat_history}}\n\nYour role: {{role}}. Continue the discussion."
}
```

**Behavior:**
- Round 1: send `prompt_template` to all participants
- Round 2+: send `round_template` with `{{chat_history}}` of all prior messages
- After each round: check if any response contains `exit_condition`
- Stop on condition match or `max_rounds`
- Output: full chat transcript + final round responses

**Error handling:**
- Worker unavailable → skip for that round
- All workers unavailable → step fails
- Max rounds without consensus → completes with `"consensus": false`

---

## Engine Features

### 9. Graph Cycles — Backward Edges

Allow `depends_on` to reference steps that appear later in the workflow, enabling feedback loops (like LangGraph).

```json
{
  "steps": [
    {"id": "code", "type": "task", "depends_on": ["plan"], ...},
    {"id": "test", "type": "task", "depends_on": ["code"], ...},
    {"id": "check", "type": "condition", "depends_on": ["test"],
     "expression": "ALL TESTS PASSED", "true_target": "done", "false_target": "code"},
    {"id": "done", "type": "task", "depends_on": ["check"], ...}
  ]
}
```

**Safety mechanisms:**
- `max_cycle_iterations` per-run (default 10): hard limit on cycle repeats
- Cycle detection at run creation: engine identifies cycles, marks them, tracks count
- Per-step iteration counter: each step instance tracks its iteration
- New step instances per iteration: old ones preserved for audit trail

**How it works:**
1. Condition/router routes to already-completed step → cycle detected
2. Check `max_cycle_iterations` — if exceeded, run fails
3. Create new step instances for cycle body with incremented `iteration_index`
4. New instances reference previous iteration's outputs

**Error handling:**
- Cycle within a cycle → each tracked independently
- Cycle limit exceeded → run fails with "cycle limit exceeded"
- Cycle + saga → compensation triggered normally

---

### 10. Worker Handoff

Worker response can include `handoff_to` to redirect step to a different worker. Inspired by OpenAI Swarm.

**Extended worker response:**
```json
{
  "output": "I can't handle this, need a specialist",
  "handoff_to": {"tags": ["security_expert"], "message": "This needs security review: ..."}
}
```

**Behavior:**
- Engine checks response for `handoff_to` field
- If present: re-dispatches to worker matching new tags with handoff message
- Original worker's output stored as intermediate (audit)
- Max handoff chain: 5
- Final worker's output becomes the step output

**Error handling:**
- Handoff to unavailable worker → step fails (retry if attempts remain)
- Chain exceeded (>5) → step fails with "handoff chain limit exceeded"
- Handoff counter resets on retry

---

## New API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/runs/{id}/steps/{step_id}/signal` | Send signal to a `wait` step |
| `GET` | `/runs/{id}/steps/{step_id}/chat` | Get group_chat transcript |

**Signal payload:**
```json
{"signal": "deploy_complete", "data": {"version": "1.2.3"}}
```

---

## Database Schema Changes

```sql
-- New table for cycle tracking
CREATE TABLE cycle_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    cycle_key TEXT NOT NULL,
    iteration_count INTEGER NOT NULL DEFAULT 0,
    max_iterations INTEGER NOT NULL DEFAULT 10,
    PRIMARY KEY (run_id, cycle_key)
);

-- New table for group_chat messages
CREATE TABLE chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL REFERENCES steps(id),
    round INTEGER NOT NULL,
    role TEXT NOT NULL,
    worker_id TEXT,
    message TEXT NOT NULL,
    ts_ms INTEGER NOT NULL
);
CREATE INDEX idx_chat_messages_step ON chat_messages(step_id, round);

-- New table for saga compensation tracking
CREATE TABLE saga_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    saga_step_id TEXT NOT NULL REFERENCES steps(id),
    body_step_id TEXT NOT NULL,
    compensation_step_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    PRIMARY KEY (run_id, saga_step_id, body_step_id)
);
```

**StepType enum additions:** `loop`, `sub_workflow`, `wait`, `router`, `transform`, `saga`, `debate`, `group_chat`

---

## Complete Step Type Coverage

| Pattern | NullBoiler Step | Vendor Reference |
|---------|----------------|-----------------|
| Sequential pipeline | `task` + `depends_on` | All vendors |
| Static parallelism | `fan_out` | AWS Parallel, Google Parallel |
| Dynamic parallelism | `map` | AWS Map, Google ADK |
| Fan-in / aggregation | `reduce` | All vendors |
| Conditional branching | `condition` | AWS Choice |
| Human approval | `approval` | LangGraph HITL |
| **Iterative loop** | **`loop`** | Google ADK LoopAgent |
| **Workflow composition** | **`sub_workflow`** | AWS Step Functions, Temporal |
| **Timer / signal pause** | **`wait`** | AWS Wait, Temporal timers |
| **N-way routing** | **`router`** | OpenAI Swarm, CrewAI @router |
| **Data transformation** | **`transform`** | AWS Pass state |
| **Ordered rollback** | **`saga`** | Temporal saga pattern |
| **Committee voting** | **`debate`** | AG2 group chat |
| **Multi-turn deliberation** | **`group_chat`** | AG2 group chat, CrewAI hierarchical |
| **Feedback loops** | **Graph cycles** | LangGraph cycles |
| **Agent transfer** | **Worker handoff** | OpenAI Swarm handoff |

**Total: 14 step types + 2 engine features = full orchestration coverage.**
