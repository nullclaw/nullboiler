const std = @import("std");
const config_mod = @import("config.zig");

pub const ClientError = error{
    MissingTrackerUrl,
    RequestFailed,
    UnexpectedStatus,
    InvalidJson,
    OutOfMemory,
};

pub const ClaimResponse = struct {
    task: TaskSummary,
    run: TrackerRunSummary,
    lease_id: []const u8,
    lease_token: []const u8,
    expires_at_ms: i64,
};

pub const TaskSummary = struct {
    id: []const u8,
    pipeline_id: []const u8,
    stage: []const u8,
    title: []const u8,
    description: []const u8,
    priority: i64,
    metadata: std.json.Value,
    task_version: i64,
};

pub const TrackerRunSummary = struct {
    id: []const u8,
    task_id: []const u8,
    attempt: i64,
    status: []const u8,
    agent_id: ?[]const u8 = null,
    agent_role: ?[]const u8 = null,
};

pub const HeartbeatResponse = struct {
    expires_at_ms: i64,
};

pub const TaskDetailsResponse = struct {
    id: []const u8,
    pipeline_id: []const u8,
    stage: []const u8,
    title: []const u8,
    description: []const u8,
    priority: i64,
    metadata: std.json.Value,
    task_version: i64,
    available_transitions: []const TransitionSummary = &.{},
};

pub const TransitionSummary = struct {
    trigger: []const u8,
    to: []const u8,
};

pub const QueueStatsResponse = struct {
    roles: []const struct {
        role: []const u8,
        claimable_count: i64,
        oldest_claimable_age_ms: ?i64 = null,
        failed_count: i64,
        stuck_count: i64,
        near_expiry_leases: i64,
    } = &.{},
    generated_at_ms: i64 = 0,
};

pub fn hasClaimableWork(allocator: std.mem.Allocator, cfg: config_mod.TrackerConfig) !bool {
    const stats = try getQueueStats(allocator, cfg);
    for (stats.roles) |role| {
        if (std.mem.eql(u8, role.role, cfg.agent_role) and role.claimable_count > 0) {
            return true;
        }
    }
    return false;
}

pub fn getQueueStats(allocator: std.mem.Allocator, cfg: config_mod.TrackerConfig) !QueueStatsResponse {
    const response = try sendRequest(allocator, cfg, .GET, "/ops/queue", null, cfg.api_token);
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.UnexpectedStatus;
    const parsed = std.json.parseFromSlice(QueueStatsResponse, allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    return parsed.value;
}

pub fn claim(allocator: std.mem.Allocator, cfg: config_mod.TrackerConfig) !?ClaimResponse {
    const payload = std.json.Stringify.valueAlloc(allocator, .{
        .agent_id = cfg.agent_id,
        .agent_role = cfg.agent_role,
        .lease_ttl_ms = cfg.lease_ttl_ms,
    }, .{}) catch return error.OutOfMemory;
    defer allocator.free(payload);

    const response = try sendRequest(allocator, cfg, .POST, "/leases/claim", payload, cfg.api_token);
    defer allocator.free(response.body);

    return switch (response.status_code) {
        200 => blk: {
            const parsed = std.json.parseFromSlice(ClaimResponse, allocator, response.body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return error.InvalidJson;
            break :blk parsed.value;
        },
        204 => null,
        else => error.UnexpectedStatus,
    };
}

pub fn heartbeat(allocator: std.mem.Allocator, cfg: config_mod.TrackerConfig, lease_id: []const u8, lease_token: []const u8) !HeartbeatResponse {
    const path = try std.fmt.allocPrint(allocator, "/leases/{s}/heartbeat", .{lease_id});
    defer allocator.free(path);

    const response = try sendRequest(allocator, cfg, .POST, path, "{}", lease_token);
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.UnexpectedStatus;

    const parsed = std.json.parseFromSlice(HeartbeatResponse, allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    return parsed.value;
}

pub fn getTask(allocator: std.mem.Allocator, cfg: config_mod.TrackerConfig, task_id: []const u8) !TaskDetailsResponse {
    const path = try std.fmt.allocPrint(allocator, "/tasks/{s}", .{task_id});
    defer allocator.free(path);

    const response = try sendRequest(allocator, cfg, .GET, path, null, cfg.api_token);
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.UnexpectedStatus;

    const parsed = std.json.parseFromSlice(TaskDetailsResponse, allocator, response.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    return parsed.value;
}

pub fn addEvent(
    allocator: std.mem.Allocator,
    cfg: config_mod.TrackerConfig,
    run_id: []const u8,
    lease_token: []const u8,
    kind: []const u8,
    data_json: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "/runs/{s}/events", .{run_id});
    defer allocator.free(path);
    const payload = try std.fmt.allocPrint(allocator, "{{\"kind\":{f},\"data\":{s}}}", .{
        std.json.fmt(kind, .{}),
        data_json,
    });
    defer allocator.free(payload);

    const response = try sendRequest(allocator, cfg, .POST, path, payload, lease_token);
    defer allocator.free(response.body);
    if (response.status_code != 201) return error.UnexpectedStatus;
}

pub fn transitionRun(
    allocator: std.mem.Allocator,
    cfg: config_mod.TrackerConfig,
    run_id: []const u8,
    lease_token: []const u8,
    trigger: []const u8,
    expected_stage: ?[]const u8,
    expected_task_version: ?i64,
) !void {
    const path = try std.fmt.allocPrint(allocator, "/runs/{s}/transition", .{run_id});
    defer allocator.free(path);

    const expected_stage_field = if (expected_stage) |stage|
        try std.fmt.allocPrint(allocator, ",\"expected_stage\":{f}", .{std.json.fmt(stage, .{})})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(expected_stage_field);

    const expected_version_field = if (expected_task_version) |version|
        try std.fmt.allocPrint(allocator, ",\"expected_task_version\":{d}", .{version})
    else
        try allocator.dupe(u8, "");
    defer allocator.free(expected_version_field);

    const payload = try std.fmt.allocPrint(allocator, "{{\"trigger\":{f}{s}{s}}}", .{
        std.json.fmt(trigger, .{}),
        expected_stage_field,
        expected_version_field,
    });
    defer allocator.free(payload);

    const response = try sendRequest(allocator, cfg, .POST, path, payload, lease_token);
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.UnexpectedStatus;
}

pub fn failRun(
    allocator: std.mem.Allocator,
    cfg: config_mod.TrackerConfig,
    run_id: []const u8,
    lease_token: []const u8,
    error_text: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "/runs/{s}/fail", .{run_id});
    defer allocator.free(path);
    const payload = try std.fmt.allocPrint(allocator, "{{\"error\":{f}}}", .{
        std.json.fmt(error_text, .{}),
    });
    defer allocator.free(payload);

    const response = try sendRequest(allocator, cfg, .POST, path, payload, lease_token);
    defer allocator.free(response.body);
    if (response.status_code != 200) return error.UnexpectedStatus;
}

pub fn addArtifact(
    allocator: std.mem.Allocator,
    cfg: config_mod.TrackerConfig,
    task_id: []const u8,
    run_id: []const u8,
    kind: []const u8,
    uri: []const u8,
    meta_json: []const u8,
) !void {
    const payload = try std.fmt.allocPrint(allocator,
        "{{\"task_id\":{f},\"run_id\":{f},\"kind\":{f},\"uri\":{f},\"meta\":{s}}}",
        .{
            std.json.fmt(task_id, .{}),
            std.json.fmt(run_id, .{}),
            std.json.fmt(kind, .{}),
            std.json.fmt(uri, .{}),
            meta_json,
        },
    );
    defer allocator.free(payload);

    const response = try sendRequest(allocator, cfg, .POST, "/artifacts", payload, cfg.api_token);
    defer allocator.free(response.body);
    if (response.status_code != 201) return error.UnexpectedStatus;
}

const HttpResponse = struct {
    status_code: u16,
    body: []u8,
};

fn sendRequest(
    allocator: std.mem.Allocator,
    cfg: config_mod.TrackerConfig,
    method: std.http.Method,
    path: []const u8,
    payload: ?[]const u8,
    bearer_token: ?[]const u8,
) !HttpResponse {
    const base_url = cfg.url orelse return error.MissingTrackerUrl;
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path });
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (bearer_token) |token| blk: {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch return error.RequestFailed;

    return .{
        .status_code = @intCast(@intFromEnum(result.status)),
        .body = response_body.toOwnedSlice() catch return error.OutOfMemory,
    };
}
