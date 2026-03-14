-- Note: step_deps, cycle_state, saga_state kept for backward compatibility
-- until engine.zig is rewritten (Task 8). They will be removed then.

-- Saved workflow definitions
CREATE TABLE IF NOT EXISTS workflows (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    definition_json TEXT NOT NULL,
    version INTEGER DEFAULT 1,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL
);

-- State checkpoints (snapshots after each step)
CREATE TABLE IF NOT EXISTS checkpoints (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL,
    parent_id TEXT REFERENCES checkpoints(id),
    state_json TEXT NOT NULL,
    completed_nodes_json TEXT NOT NULL,
    version INTEGER NOT NULL,
    metadata_json TEXT,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_checkpoints_run ON checkpoints(run_id, version);
CREATE INDEX IF NOT EXISTS idx_checkpoints_parent ON checkpoints(parent_id);

-- Agent intermediate events (from nullclaw callback)
CREATE TABLE IF NOT EXISTS agent_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT NOT NULL,
    iteration INTEGER NOT NULL,
    tool TEXT,
    args_json TEXT,
    result_text TEXT,
    status TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_agent_events_run_step ON agent_events(run_id, step_id);

-- Pending state injections (thread-safe queue for POST /runs/{id}/state)
CREATE TABLE IF NOT EXISTS pending_state_injections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    updates_json TEXT NOT NULL,
    apply_after_step TEXT,
    created_at_ms INTEGER NOT NULL
);

-- Extend runs table
ALTER TABLE runs ADD COLUMN state_json TEXT;
ALTER TABLE runs ADD COLUMN workflow_id TEXT REFERENCES workflows(id);
ALTER TABLE runs ADD COLUMN forked_from_run_id TEXT REFERENCES runs(id);
ALTER TABLE runs ADD COLUMN forked_from_checkpoint_id TEXT REFERENCES checkpoints(id);
ALTER TABLE runs ADD COLUMN checkpoint_count INTEGER DEFAULT 0;

-- Extend steps table
ALTER TABLE steps ADD COLUMN state_before_json TEXT;
ALTER TABLE steps ADD COLUMN state_after_json TEXT;
ALTER TABLE steps ADD COLUMN state_updates_json TEXT;
-- NOTE: parent_step_id already exists from 001_init.sql — do NOT add it again

-- Subgraph support: parent run linkage and per-run config
ALTER TABLE runs ADD COLUMN parent_run_id TEXT REFERENCES runs(id);
ALTER TABLE runs ADD COLUMN config_json TEXT;

-- Node-level cache (Gap 3)
CREATE TABLE IF NOT EXISTS node_cache (
    cache_key TEXT PRIMARY KEY,
    node_name TEXT NOT NULL,
    result_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL,
    ttl_ms INTEGER
);

-- Pending writes from parallel node execution (Gap 4)
CREATE TABLE IF NOT EXISTS pending_writes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL,
    step_id TEXT NOT NULL,
    channel TEXT NOT NULL,
    value_json TEXT NOT NULL,
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pending_writes_run ON pending_writes(run_id);

-- Token accounting columns on runs
ALTER TABLE runs ADD COLUMN total_input_tokens INTEGER DEFAULT 0;
ALTER TABLE runs ADD COLUMN total_output_tokens INTEGER DEFAULT 0;
ALTER TABLE runs ADD COLUMN total_tokens INTEGER DEFAULT 0;

-- Token accounting columns on steps
ALTER TABLE steps ADD COLUMN input_tokens INTEGER DEFAULT 0;
ALTER TABLE steps ADD COLUMN output_tokens INTEGER DEFAULT 0;
ALTER TABLE steps ADD COLUMN total_tokens INTEGER DEFAULT 0;
