-- Migration 002: Advanced step types support

-- Cycle tracking for graph loops
CREATE TABLE IF NOT EXISTS cycle_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    cycle_key TEXT NOT NULL,
    iteration_count INTEGER NOT NULL DEFAULT 0,
    max_iterations INTEGER NOT NULL DEFAULT 10,
    PRIMARY KEY (run_id, cycle_key)
);

-- Group chat message history
CREATE TABLE IF NOT EXISTS chat_messages (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL REFERENCES steps(id),
    round INTEGER NOT NULL,
    role TEXT NOT NULL,
    worker_id TEXT,
    message TEXT NOT NULL,
    ts_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_step ON chat_messages(step_id, round);

-- Saga compensation state
CREATE TABLE IF NOT EXISTS saga_state (
    run_id TEXT NOT NULL REFERENCES runs(id),
    saga_step_id TEXT NOT NULL REFERENCES steps(id),
    body_step_id TEXT NOT NULL,
    compensation_step_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    PRIMARY KEY (run_id, saga_step_id, body_step_id)
);

-- NOTE: steps.child_run_id and steps.iteration_index are defined in
-- migrations/001_init.sql as part of the canonical schema.
