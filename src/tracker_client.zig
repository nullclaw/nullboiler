/// HTTP client for NullTickets API used by the pull-mode tracker runtime.
const std = @import("std");

pub const TransitionInfo = struct {
    trigger: []const u8 = "",
    to: []const u8 = "",
};

pub const TaskInfo = struct {
    id: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    stage: []const u8 = "",
    pipeline_id: []const u8 = "",
    priority: i64 = 0,
    metadata_json: []const u8 = "{}",
    task_json: []const u8 = "{}",
    task_version: i64 = 0,
    available_transitions: []const TransitionInfo = &.{},
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
    expires_at_ms: i64 = 0,
};

const HttpResult = struct {
    status_code: u16,
    body: []const u8,
};

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

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const root = parsed.value.object;
        const task_val = root.get("task") orelse return null;
        const run_val = root.get("run") orelse return null;
        if (task_val != .object or run_val != .object) return null;

        return ClaimResponse{
            .task = try parseTaskInfo(self.allocator, task_val),
            .run = .{
                .id = try dupeJsonString(self.allocator, run_val.object, "id"),
                .attempt = getJsonInt(run_val.object, "attempt") orelse 1,
            },
            .lease_id = try dupeJsonString(self.allocator, root, "lease_id"),
            .lease_token = try dupeJsonString(self.allocator, root, "lease_token"),
            .expires_at_ms = getJsonInt(root, "expires_at_ms") orelse 0,
        };
    }

    pub fn heartbeat(self: *TrackerClient, lease_id: []const u8, lease_token: []const u8) !?i64 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/leases/{s}/heartbeat", .{ self.base_url, lease_id });
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .POST, "{}", lease_token);
        defer self.allocator.free(result.body);

        if (result.status_code < 200 or result.status_code >= 300) return null;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        return getJsonInt(parsed.value.object, "expires_at_ms");
    }

    pub fn transition(
        self: *TrackerClient,
        run_id: []const u8,
        trigger: []const u8,
        lease_token: []const u8,
        usage_json: ?[]const u8,
        expected_stage: ?[]const u8,
        expected_task_version: ?i64,
    ) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/transition", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const trigger_json = try std.json.Stringify.valueAlloc(self.allocator, trigger, .{});
        defer self.allocator.free(trigger_json);
        const stage_field = if (expected_stage) |stage|
            try std.fmt.allocPrint(self.allocator, ",\"expected_stage\":{f}", .{std.json.fmt(stage, .{})})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(stage_field);
        const version_field = if (expected_task_version) |version|
            try std.fmt.allocPrint(self.allocator, ",\"expected_task_version\":{d}", .{version})
        else
            try self.allocator.dupe(u8, "");
        defer self.allocator.free(version_field);

        const body = if (usage_json) |usage|
            try std.fmt.allocPrint(self.allocator, "{{\"trigger\":{s}{s}{s},\"usage\":{s}}}", .{ trigger_json, stage_field, version_field, usage })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"trigger\":{s}{s}{s}}}", .{ trigger_json, stage_field, version_field });
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    pub fn failRun(self: *TrackerClient, run_id: []const u8, reason: []const u8, lease_token: []const u8, usage_json: ?[]const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/runs/{s}/fail", .{ self.base_url, run_id });
        defer self.allocator.free(url);

        const reason_json = try std.json.Stringify.valueAlloc(self.allocator, reason, .{});
        defer self.allocator.free(reason_json);
        const body = if (usage_json) |usage|
            try std.fmt.allocPrint(self.allocator, "{{\"error\":{s},\"usage\":{s}}}", .{ reason_json, usage })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"error\":{s}}}", .{reason_json});
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, lease_token);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

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

    pub fn postArtifact(self: *TrackerClient, task_id: []const u8, run_id: []const u8, kind: []const u8, uri: []const u8, meta_json: []const u8) !bool {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/artifacts", .{self.base_url});
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"task_id\":{f},\"run_id\":{f},\"kind\":{f},\"uri\":{f},\"meta\":{s}}}",
            .{
                std.json.fmt(task_id, .{}),
                std.json.fmt(run_id, .{}),
                std.json.fmt(kind, .{}),
                std.json.fmt(uri, .{}),
                meta_json,
            },
        );
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .POST, body, null);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

    pub fn getTask(self: *TrackerClient, task_id: []const u8) !?TaskInfo {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/tasks/{s}", .{ self.base_url, task_id });
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .GET, null, null);
        defer self.allocator.free(result.body);

        if (result.status_code < 200 or result.status_code >= 300) return null;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        return try parseTaskInfo(self.allocator, parsed.value);
    }

    pub fn getQueueStats(self: *TrackerClient) ![]const u8 {
        const url = try std.fmt.allocPrint(self.allocator, "{s}/ops/queue", .{self.base_url});
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .GET, null, null);
        return result.body;
    }

    pub fn storeGetValue(self: *TrackerClient, namespace: []const u8, key: []const u8) !?[]const u8 {
        const namespace_enc = try encodePathSegment(self.allocator, namespace);
        defer self.allocator.free(namespace_enc);
        const key_enc = try encodePathSegment(self.allocator, key);
        defer self.allocator.free(key_enc);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/store/{s}/{s}",
            .{ trimTrailingSlash(self.base_url), namespace_enc, key_enc },
        );
        defer self.allocator.free(url);

        const result = try self.httpRequest(url, .GET, null, null);
        defer self.allocator.free(result.body);

        if (result.status_code == 404) return null;
        if (result.status_code < 200 or result.status_code >= 300) return null;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, result.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;

        const value = parsed.value.object.get("value") orelse return null;
        const value_json = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        return value_json;
    }

    pub fn storePutValue(self: *TrackerClient, namespace: []const u8, key: []const u8, value_json: []const u8) !bool {
        const namespace_enc = try encodePathSegment(self.allocator, namespace);
        defer self.allocator.free(namespace_enc);
        const key_enc = try encodePathSegment(self.allocator, key);
        defer self.allocator.free(key_enc);

        const url = try std.fmt.allocPrint(
            self.allocator,
            "{s}/store/{s}/{s}",
            .{ trimTrailingSlash(self.base_url), namespace_enc, key_enc },
        );
        defer self.allocator.free(url);

        const body = try std.fmt.allocPrint(self.allocator, "{{\"value\":{s}}}", .{value_json});
        defer self.allocator.free(body);

        const result = try self.httpRequest(url, .PUT, body, null);
        defer self.allocator.free(result.body);

        return result.status_code >= 200 and result.status_code < 300;
    }

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

        return HttpResult{
            .status_code = @intCast(@intFromEnum(result.status)),
            .body = try self.allocator.dupe(u8, response_body.written()),
        };
    }
};

fn trimTrailingSlash(url: []const u8) []const u8 {
    if (url.len > 0 and url[url.len - 1] == '/') return url[0 .. url.len - 1];
    return url;
}

fn encodePathSegment(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (value) |ch| {
        if (isUnreserved(ch)) {
            try buf.append(allocator, ch);
            continue;
        }
        try buf.writer(allocator).print("%{X:0>2}", .{ch});
    }

    return try buf.toOwnedSlice(allocator);
}

fn isUnreserved(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or
        ch == '_' or
        ch == '.' or
        ch == '~';
}

fn parseTaskInfo(allocator: std.mem.Allocator, task_value: std.json.Value) !TaskInfo {
    if (task_value != .object) return error.InvalidTaskPayload;
    const obj = task_value.object;

    const metadata_json = if (obj.get("metadata")) |metadata|
        try std.json.Stringify.valueAlloc(allocator, metadata, .{})
    else
        try allocator.dupe(u8, "{}");

    const task_json = try std.json.Stringify.valueAlloc(allocator, task_value, .{});
    const transitions = try parseTransitions(allocator, obj.get("available_transitions"));

    return TaskInfo{
        .id = try dupeJsonString(allocator, obj, "id"),
        .title = try dupeJsonString(allocator, obj, "title"),
        .description = try dupeJsonString(allocator, obj, "description"),
        .stage = try dupeJsonString(allocator, obj, "stage"),
        .pipeline_id = try dupeJsonString(allocator, obj, "pipeline_id"),
        .priority = getJsonInt(obj, "priority") orelse 0,
        .metadata_json = metadata_json,
        .task_json = task_json,
        .task_version = getJsonInt(obj, "task_version") orelse 0,
        .available_transitions = transitions,
    };
}

fn parseTransitions(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const TransitionInfo {
    const transitions_val = value orelse return allocator.alloc(TransitionInfo, 0);
    if (transitions_val != .array) return allocator.alloc(TransitionInfo, 0);

    var list: std.ArrayListUnmanaged(TransitionInfo) = .empty;
    defer list.deinit(allocator);

    for (transitions_val.array.items) |item| {
        if (item != .object) continue;
        try list.append(allocator, .{
            .trigger = try dupeJsonString(allocator, item.object, "trigger"),
            .to = if (getJsonString(item.object, "to")) |value_str|
                try allocator.dupe(u8, value_str)
            else
                try allocator.dupe(u8, ""),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return allocator.dupe(u8, getJsonString(obj, key) orelse "");
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        else => null,
    };
}

test "TrackerClient init stores base_url and api_token" {
    const allocator = std.testing.allocator;
    var client = TrackerClient.init(allocator, "http://localhost:9000", "my-token");
    _ = &client;

    try std.testing.expectEqualStrings("http://localhost:9000", client.base_url);
    try std.testing.expect(client.api_token != null);
    try std.testing.expectEqualStrings("my-token", client.api_token.?);
}

test "TaskInfo defaults" {
    const info: TaskInfo = .{};
    try std.testing.expectEqualStrings("", info.id);
    try std.testing.expectEqualStrings("{}", info.metadata_json);
    try std.testing.expectEqualStrings("{}", info.task_json);
    try std.testing.expectEqual(@as(i64, 0), info.task_version);
    try std.testing.expectEqual(@as(usize, 0), info.available_transitions.len);
}

test "ClaimResponse defaults" {
    const resp: ClaimResponse = .{};
    try std.testing.expectEqualStrings("", resp.lease_id);
    try std.testing.expectEqual(@as(i64, 0), resp.expires_at_ms);
}

test "TrackerClient exposes optimistic transition support" {
    try std.testing.expect(@hasDecl(TrackerClient, "transition"));
    try std.testing.expect(@hasDecl(TrackerClient, "postArtifact"));
}

test "encodePathSegment percent-encodes reserved characters" {
    const allocator = std.testing.allocator;
    const encoded = try encodePathSegment(allocator, "team alpha/key");
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings("team%20alpha%2Fkey", encoded);
}
