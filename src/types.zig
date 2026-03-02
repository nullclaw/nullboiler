/// Domain types for NullBoiler orchestrator.
/// Enums, DB row types, and API response types.
const std = @import("std");

// ── Enums ──────────────────────────────────────────────────────────────

pub const RunStatus = enum {
    pending,
    running,
    paused,
    completed,
    failed,
    cancelled,

    pub fn toString(self: RunStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?RunStatus {
        inline for (@typeInfo(RunStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const StepStatus = enum {
    pending,
    ready,
    running,
    completed,
    failed,
    skipped,
    waiting_approval,

    pub fn toString(self: StepStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StepStatus {
        inline for (@typeInfo(StepStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const StepType = enum {
    task,
    fan_out,
    map,
    condition,
    approval,
    reduce,
    loop,
    sub_workflow,
    wait,
    router,
    transform,
    saga,
    debate,
    group_chat,

    pub fn toString(self: StepType) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?StepType {
        inline for (@typeInfo(StepType).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const WorkerStatus = enum {
    active,
    draining,
    dead,

    pub fn toString(self: WorkerStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?WorkerStatus {
        inline for (@typeInfo(WorkerStatus).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const WorkerSource = enum {
    config,
    registered,

    pub fn toString(self: WorkerSource) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(s: []const u8) ?WorkerSource {
        inline for (@typeInfo(WorkerSource).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

// ── DB Row Types ───────────────────────────────────────────────────────

pub const WorkerRow = struct {
    id: []const u8,
    url: []const u8,
    token: []const u8,
    protocol: []const u8,
    model: ?[]const u8,
    tags_json: []const u8,
    max_concurrent: i64,
    source: []const u8,
    status: []const u8,
    consecutive_failures: i64,
    circuit_open_until_ms: ?i64,
    last_error_text: ?[]const u8,
    last_health_ms: ?i64,
    created_at_ms: i64,
};

pub const RunRow = struct {
    id: []const u8,
    idempotency_key: ?[]const u8,
    status: []const u8,
    workflow_json: []const u8,
    input_json: []const u8,
    callbacks_json: []const u8,
    error_text: ?[]const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    started_at_ms: ?i64,
    ended_at_ms: ?i64,
};

pub const StepRow = struct {
    id: []const u8,
    run_id: []const u8,
    def_step_id: []const u8,
    type: []const u8,
    status: []const u8,
    worker_id: ?[]const u8,
    input_json: []const u8,
    output_json: ?[]const u8,
    error_text: ?[]const u8,
    attempt: i64,
    max_attempts: i64,
    timeout_ms: ?i64,
    next_attempt_at_ms: ?i64,
    parent_step_id: ?[]const u8,
    item_index: ?i64,
    created_at_ms: i64,
    updated_at_ms: i64,
    started_at_ms: ?i64,
    ended_at_ms: ?i64,
    child_run_id: ?[]const u8,
    iteration_index: i64,
};

pub const EventRow = struct {
    id: i64,
    run_id: []const u8,
    step_id: ?[]const u8,
    kind: []const u8,
    data_json: []const u8,
    ts_ms: i64,
};

pub const ArtifactRow = struct {
    id: []const u8,
    run_id: []const u8,
    step_id: ?[]const u8,
    kind: []const u8,
    uri: []const u8,
    meta_json: []const u8,
    created_at_ms: i64,
};

pub const ChatMessageRow = struct {
    id: i64,
    run_id: []const u8,
    step_id: []const u8,
    round: i64,
    role: []const u8,
    worker_id: ?[]const u8,
    message: []const u8,
    ts_ms: i64,
};

pub const SagaStateRow = struct {
    run_id: []const u8,
    saga_step_id: []const u8,
    body_step_id: []const u8,
    compensation_step_id: ?[]const u8,
    status: []const u8,
};

// ── API Response Types ─────────────────────────────────────────────────

pub const HealthResponse = struct {
    status: []const u8,
    version: []const u8,
    active_runs: i64,
    total_workers: i64,
};

pub const ErrorResponse = struct {
    @"error": ErrorDetail,
};

pub const ErrorDetail = struct {
    code: []const u8,
    message: []const u8,
};

// ── Tests ──────────────────────────────────────────────────────────────

test "RunStatus round-trip" {
    const s = RunStatus.pending;
    const name = s.toString();
    try std.testing.expectEqualStrings("pending", name);
    const parsed = RunStatus.fromString(name);
    try std.testing.expectEqual(RunStatus.pending, parsed.?);
}

test "StepStatus round-trip" {
    const s = StepStatus.waiting_approval;
    const name = s.toString();
    try std.testing.expectEqualStrings("waiting_approval", name);
    const parsed = StepStatus.fromString(name);
    try std.testing.expectEqual(StepStatus.waiting_approval, parsed.?);
}

test "StepType round-trip" {
    const s = StepType.fan_out;
    try std.testing.expectEqualStrings("fan_out", s.toString());
    try std.testing.expectEqual(StepType.fan_out, StepType.fromString("fan_out").?);
}

test "WorkerStatus round-trip" {
    try std.testing.expectEqual(WorkerStatus.draining, WorkerStatus.fromString("draining").?);
}

test "WorkerSource round-trip" {
    try std.testing.expectEqual(WorkerSource.registered, WorkerSource.fromString("registered").?);
}

test "fromString returns null for unknown" {
    try std.testing.expectEqual(@as(?RunStatus, null), RunStatus.fromString("bogus"));
    try std.testing.expectEqual(@as(?StepStatus, null), StepStatus.fromString("nope"));
}
