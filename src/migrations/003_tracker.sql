CREATE TABLE IF NOT EXISTS tracker_runs (
    task_id TEXT PRIMARY KEY,
    tracker_run_id TEXT NOT NULL,
    boiler_run_id TEXT NOT NULL UNIQUE REFERENCES runs(id),
    lease_id TEXT NOT NULL,
    lease_token TEXT NOT NULL,
    pipeline_id TEXT NOT NULL,
    agent_role TEXT NOT NULL,
    task_title TEXT NOT NULL,
    task_stage TEXT NOT NULL,
    task_version INTEGER NOT NULL DEFAULT 0,
    success_trigger TEXT,
    artifact_kind TEXT NOT NULL DEFAULT 'nullboiler_run',
    state TEXT NOT NULL DEFAULT 'running',
    claimed_at_ms INTEGER NOT NULL,
    last_heartbeat_ms INTEGER,
    lease_expires_at_ms INTEGER,
    completed_at_ms INTEGER,
    last_error_text TEXT
);

CREATE INDEX IF NOT EXISTS idx_tracker_runs_state ON tracker_runs(state, claimed_at_ms DESC);
CREATE INDEX IF NOT EXISTS idx_tracker_runs_boiler_run ON tracker_runs(boiler_run_id);
