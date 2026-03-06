/// HTTP client for NullTickets API — used by pull-mode agents to claim tasks,
/// heartbeat leases, transition runs, report failures, and fetch task info.
const std = @import("std");

// ── Response Types ───────────────────────────────────────────────────

pub const TaskInfo = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    stage: []const u8 = "",
    pipeline_id: []const u8 = "",
    priority: i64 = 0,
    metadata_json: []const u8 = "{}",
};

pub const RunInfo = struct {
    id: []const u8 = "",
    attempt: i64 = 1,
};

pub const ClaimResponse = struct {
    task: TaskInfo = .{},
    run: RunInfo = .{},
    lease_id: []const u8 = "",
    lease_token: []const u8 = "",
};

// ── HTTP Result ──────────────────────────────────────────────────────

const HttpResult = struct {
    status_code: u16,
    body: []const u8,
};

// ── TrackerClient ────────────────────────────────────────────────────

pub const TrackerClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_token: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_token: ?[]const u8) TrackerClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .api_token = api_token,
        };
    }

    /// POST /leases/claim — attempt to claim a task from the queue.
    /// Returns null on 204 (no work available) or on HTTP error.
    pub fn claim(self: *TrackerClient, agent_id: []const u8, agent_role: []const u8, lease_ttl_ms: i64) !?ClaimResponse {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/leases/claim", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .agent_id = agent_id,
            .agent_role = agent_role,
            .lease_ttl_ms = lease_ttl_ms,
        }, .{});
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, null);
        defer self.allocator.free(result.body);

        if (result.status_code == 204) return null;
        if (result.status_code < 200 or result.status_code >= 300) return null;

        const parsed = std.json.parseFromSlice(ClaimResponse, self.allocator, result.body, .{ .ignore_unknown_fields = true }) catch {
            return null;
        };
        defer parsed.deinit();

        // Copy all fields so they outlive the parsed JSON arena
        return ClaimResponse{
            .task = .{
                .id = try self.allocator.dupe(u8, parsed.value.task.id),
                .title = try self.allocator.dupe(u8, parsed.value.task.title),
                .description = try self.allocator.dupe(u8, parsed.value.task.description),
                .stage = try self.allocator.dupe(u8, parsed.value.task.stage),
                .pipeline_id = try self.allocator.dupe(u8, parsed.value.task.pipeline_id),
                .priority = parsed.value.task.priority,
                .metadata_json = try self.allocator.dupe(u8, parsed.value.task.metadata_json),
            },
            .run = .{
                .id = try self.allocator.dupe(u8, parsed.value.run.id),
                .attempt = parsed.value.run.attempt,
            },
            .lease_id = try self.allocator.dupe(u8, parsed.value.lease_id),
            .lease_token = try self.allocator.dupe(u8, parsed.value.lease_token),
        };
    }

    /// POST /leases/{id}/heartbeat — extend the lease TTL.
    /// Uses lease_token as Bearer override. Returns true on 2xx.
    pub fn heartbeat(self: *TrackerClient, lease_id: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/leases/{s}/heartbeat", .{ self.base_url, lease_id });
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .POST, "{}", lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    /// POST /runs/{id}/transition — move a run to the next stage.
    /// Uses lease_token as Bearer override. Returns true on 2xx.
    pub fn transition(self: *TrackerClient, run_id: []const u8, trigger: []const u8, lease_token: []const u8, usage_json: ?[]const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/transition", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const body = if (usage_json) |usage| blk: {
            const trigger_json = try std.json.Stringify.valueAlloc(self.allocator, trigger, .{});
            defer self.allocator.free(trigger_json);
            break :blk try std.fmt.allocPrint(self.allocator, "{{\"trigger\":{s},\"usage\":{s}}}", .{ trigger_json, usage });
        } else blk: {
            break :blk try std.json.Stringify.valueAlloc(self.allocator, .{ .trigger = trigger }, .{});
        };
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    /// POST /runs/{id}/fail — report a run failure with reason.
    /// Uses lease_token as Bearer override. Returns true on 2xx.
    pub fn failRun(self: *TrackerClient, run_id: []const u8, reason: []const u8, lease_token: []const u8, usage_json: ?[]const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/fail", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const body = if (usage_json) |usage| blk: {
            const reason_json = try std.json.Stringify.valueAlloc(self.allocator, reason, .{});
            defer self.allocator.free(reason_json);
            break :blk try std.fmt.allocPrint(self.allocator, "{{\"reason\":{s},\"usage\":{s}}}", .{ reason_json, usage });
        } else blk: {
            break :blk try std.json.Stringify.valueAlloc(self.allocator, .{ .reason = reason }, .{});
        };
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    /// POST /runs/{id}/events — post a progress event.
    /// Returns true on 2xx.
    pub fn postEvent(self: *TrackerClient, run_id: []const u8, kind: []const u8, data_json: []const u8, lease_token: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/events", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const kind_json = try std.json.Stringify.valueAlloc(self.allocator, kind, .{});
        defer self.allocator.free(kind_json);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"kind\":{s},\"data\":{s}}}", .{ kind_json, data_json });
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    /// POST /artifacts — upload an artifact for a task.
    /// Uses self.api_token for auth. Returns true on 2xx.
    pub fn postArtifact(self: *TrackerClient, task_id: []const u8, name: []const u8, content: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/artifacts", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .task_id = task_id,
            .name = name,
            .content = content,
        }, .{});
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, null);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    /// GET /tasks/{id} — fetch task details.
    /// Returns null on non-2xx.
    pub fn getTask(self: *TrackerClient, task_id: []const u8) !?TaskInfo {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tasks/{s}", .{ self.base_url, task_id });
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .GET, null, null);
        defer self.allocator.free(result.body);

        if (result.status_code < 200 or result.status_code >= 300) return null;

        const parsed = std.json.parseFromSlice(TaskInfo, self.allocator, result.body, .{ .ignore_unknown_fields = true }) catch {
            return null;
        };
        defer parsed.deinit();

        return TaskInfo{
            .id = try self.allocator.dupe(u8, parsed.value.id),
            .title = try self.allocator.dupe(u8, parsed.value.title),
            .description = try self.allocator.dupe(u8, parsed.value.description),
            .stage = try self.allocator.dupe(u8, parsed.value.stage),
            .pipeline_id = try self.allocator.dupe(u8, parsed.value.pipeline_id),
            .priority = parsed.value.priority,
            .metadata_json = try self.allocator.dupe(u8, parsed.value.metadata_json),
        };
    }

    /// GET /ops/queue — return raw queue stats JSON.
    pub fn getQueueStats(self: *TrackerClient) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/ops/queue", .{self.base_url});
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .GET, null, null);
        // Caller owns the body
        return result.body;
    }

    // ── Internal HTTP helper ─────────────────────────────────────────

    fn httpRequest(
        self: *TrackerClient,
        url: []const u8,
        method: std.http.Method,
        body: ?[]const u8,
        bearer_override: ?[]const u8,
    ) !HttpResult {
        var client: std.http.Client = .{ .allocator = self.allocator };
        defer client.deinit();

        var response_body: std.io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();

        // Determine the auth token: bearer_override takes priority over self.api_token
        const token = bearer_override orelse self.api_token;
        var auth_header: ?[]const u8 = null;
        if (token) |t| {
            auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{t});
        }
        defer if (auth_header) |ah| self.allocator.free(ah);

        var headers_buf: [1]std.http.Header = undefined;
        const extra_headers: []const std.http.Header = if (auth_header) |ah| blk: {
            headers_buf[0] = .{ .name = "Authorization", .value = ah };
            break :blk headers_buf[0..1];
        } else &.{};

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = body,
            .response_writer = &response_body.writer,
            .extra_headers = extra_headers,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
        }) catch {
            return error.HttpRequestFailed;
        };

        const status_code = @intFromEnum(result.status);
        const resp_data = try self.allocator.dupe(u8, response_body.written());

        return HttpResult{
            .status_code = @intCast(status_code),
            .body = resp_data,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────

test "TrackerClient init stores base_url and api_token" {
    const allocator = std.testing.allocator;
    var client = TrackerClient.init(allocator, "http://localhost:9000", "my-token");
    _ = &client;

    try std.testing.expectEqualStrings("http://localhost:9000", client.base_url);
    try std.testing.expect(client.api_token != null);
    try std.testing.expectEqualStrings("my-token", client.api_token.?);
}

test "TrackerClient init with null api_token" {
    const allocator = std.testing.allocator;
    var client = TrackerClient.init(allocator, "http://tracker.local", null);
    _ = &client;

    try std.testing.expectEqualStrings("http://tracker.local", client.base_url);
    try std.testing.expect(client.api_token == null);
}

test "TaskInfo defaults" {
    const info: TaskInfo = .{};
    try std.testing.expectEqualStrings("", info.id);
    try std.testing.expectEqualStrings("", info.title);
    try std.testing.expectEqualStrings("", info.description);
    try std.testing.expectEqualStrings("", info.stage);
    try std.testing.expectEqualStrings("", info.pipeline_id);
    try std.testing.expectEqual(@as(i64, 0), info.priority);
    try std.testing.expectEqualStrings("{}", info.metadata_json);
}

test "RunInfo defaults" {
    const info: RunInfo = .{};
    try std.testing.expectEqualStrings("", info.id);
    try std.testing.expectEqual(@as(i64, 1), info.attempt);
}

test "ClaimResponse defaults" {
    const resp: ClaimResponse = .{};
    try std.testing.expectEqualStrings("", resp.lease_id);
    try std.testing.expectEqualStrings("", resp.lease_token);
    try std.testing.expectEqualStrings("", resp.task.id);
    try std.testing.expectEqualStrings("{}", resp.task.metadata_json);
    try std.testing.expectEqual(@as(i64, 0), resp.task.priority);
    try std.testing.expectEqualStrings("", resp.run.id);
    try std.testing.expectEqual(@as(i64, 1), resp.run.attempt);
}

test "TrackerClient has postEvent method" {
    const has_method = @hasDecl(TrackerClient, "postEvent");
    try std.testing.expect(has_method);
}
