-- nullboiler schema v1

CREATE TABLE IF NOT EXISTS workers (
    id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    token TEXT NOT NULL,
    protocol TEXT NOT NULL DEFAULT 'webhook',
    model TEXT,
    tags_json TEXT NOT NULL DEFAULT '[]',
    max_concurrent INTEGER NOT NULL DEFAULT 1,
    source TEXT NOT NULL DEFAULT 'config',
    status TEXT NOT NULL DEFAULT 'active',
    consecutive_failures INTEGER NOT NULL DEFAULT 0,
    circuit_open_until_ms INTEGER,
    last_error_text TEXT,
    last_health_ms INTEGER,
    created_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS runs (
    id TEXT PRIMARY KEY,
    idempotency_key TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    workflow_json TEXT NOT NULL,
    input_json TEXT NOT NULL DEFAULT '{}',
    callbacks_json TEXT NOT NULL DEFAULT '[]',
    error_text TEXT,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    started_at_ms INTEGER,
    ended_at_ms INTEGER
);
CREATE INDEX IF NOT EXISTS idx_runs_status ON runs(status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_runs_idempotency_key ON runs(idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE IF NOT EXISTS steps (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    def_step_id TEXT NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    worker_id TEXT REFERENCES workers(id),
    input_json TEXT NOT NULL DEFAULT '{}',
    output_json TEXT,
    error_text TEXT,
    attempt INTEGER NOT NULL DEFAULT 1,
    max_attempts INTEGER NOT NULL DEFAULT 1,
    timeout_ms INTEGER,
    next_attempt_at_ms INTEGER,
    parent_step_id TEXT REFERENCES steps(id),
    item_index INTEGER,
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    started_at_ms INTEGER,
    ended_at_ms INTEGER,
    child_run_id TEXT REFERENCES runs(id),
    iteration_index INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_steps_run ON steps(run_id);
CREATE INDEX IF NOT EXISTS idx_steps_status ON steps(run_id, status);
CREATE INDEX IF NOT EXISTS idx_steps_parent ON steps(parent_step_id);

CREATE TABLE IF NOT EXISTS step_deps (
    step_id TEXT NOT NULL REFERENCES steps(id),
    depends_on TEXT NOT NULL REFERENCES steps(id),
    PRIMARY KEY (step_id, depends_on)
);
CREATE INDEX IF NOT EXISTS idx_step_deps_dep ON step_deps(depends_on);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT REFERENCES steps(id),
    kind TEXT NOT NULL,
    data_json TEXT NOT NULL DEFAULT '{}',
    ts_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_events_run ON events(run_id, id);

CREATE TABLE IF NOT EXISTS artifacts (
    id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(id),
    step_id TEXT REFERENCES steps(id),
    kind TEXT NOT NULL,
    uri TEXT NOT NULL,
    meta_json TEXT NOT NULL DEFAULT '{}',
    created_at_ms INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_artifacts_run ON artifacts(run_id);
CREATE INDEX IF NOT EXISTS idx_artifacts_step ON artifacts(step_id);
