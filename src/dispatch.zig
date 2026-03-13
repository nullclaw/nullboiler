/// Worker dispatch module — protocol-aware HTTP dispatch for external bot workers.
/// Provides worker selection (filtering by status, capacity, and tags) and
/// request/response adapters for webhook/api_chat/openai_chat protocols.
const std = @import("std");
const ids = @import("ids.zig");
const worker_protocol = @import("worker_protocol.zig");
const worker_response = @import("worker_response.zig");
const redis_client = @import("redis_client.zig");
const mqtt_client = @import("mqtt_client.zig");

// ── Types ─────────────────────────────────────────────────────────────

pub const WorkerInfo = struct {
    id: []const u8,
    url: []const u8,
    token: []const u8,
    protocol: []const u8 = "webhook", // "webhook", "api_chat", "openai_chat"
    model: ?[]const u8 = null,
    tags_json: []const u8, // JSON array like ["coder","researcher"]
    max_concurrent: i64,
    status: []const u8, // "active", "draining", "dead"
    current_tasks: i64, // how many tasks currently assigned
};

pub const DispatchResult = worker_response.ParseResult;

// ── Worker Selection ──────────────────────────────────────────────────

/// Select the best available worker that matches all criteria:
///   1. status == "active"
///   2. current_tasks < max_concurrent
///   3. at least one tag in worker.tags_json intersects required_tags
///
/// Among eligible workers, returns the least-loaded one (lowest current_tasks).
/// Returns null if no worker is available.
pub fn selectWorker(
    allocator: std.mem.Allocator,
    workers: []const WorkerInfo,
    required_tags: []const []const u8,
) !?WorkerInfo {
    var best: ?WorkerInfo = null;
    var best_load: i64 = std.math.maxInt(i64);

    for (workers) |worker| {
        // 1. Must be active
        if (!std.mem.eql(u8, worker.status, "active")) continue;

        // 2. Must have capacity
        if (worker.current_tasks >= worker.max_concurrent) continue;

        // 3. Must have at least one matching tag
        if (!try workerMatchesTags(allocator, worker.tags_json, required_tags)) continue;

        // Pick the least-loaded worker
        if (worker.current_tasks < best_load) {
            best = worker;
            best_load = worker.current_tasks;
        }
    }

    return best;
}

/// Parse worker tags_json and check if any tag intersects with required_tags.
fn workerMatchesTags(
    allocator: std.mem.Allocator,
    tags_json: []const u8,
    required_tags: []const []const u8,
) !bool {
    if (required_tags.len == 0) return true;

    const parsed = std.json.parseFromSlice([]const []const u8, allocator, tags_json, .{}) catch {
        return false;
    };
    defer parsed.deinit();

    for (parsed.value) |worker_tag| {
        for (required_tags) |required_tag| {
            if (std.mem.eql(u8, worker_tag, required_tag)) {
                return true;
            }
        }
    }
    return false;
}

// ── Agent Step Options ────────────────────────────────────────────────

/// Extra fields included in the webhook body when step type is "agent".
pub const AgentOpts = struct {
    /// "autonomous" or "managed"
    mode: ?[]const u8 = null,
    /// Full callback URL for agent events; if null, omitted from body.
    /// Typically constructed as: self_url + "/internal/agent-events/{run_id}/{step_id}"
    callback_url: ?[]const u8 = null,
    /// Maximum agent iterations; if null, omitted from body.
    max_iterations: ?i64 = null,
    /// JSON array of tool names, e.g. "[\"search\",\"code\"]"; if null, omitted from body.
    tools_json: ?[]const u8 = null,
    /// Current state JSON to pass to the agent; if null, omitted from body.
    state_json: ?[]const u8 = null,
};

// ── HTTP Dispatch ─────────────────────────────────────────────────────

pub fn dispatchStep(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_token: []const u8,
    worker_protocol_raw: []const u8,
    worker_model: ?[]const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
) !DispatchResult {
    return dispatchStepWithOpts(allocator, worker_url, worker_token, worker_protocol_raw, worker_model, run_id, step_id, rendered_prompt, null);
}

/// Like dispatchStep but also accepts optional agent-specific fields.
/// When agent_opts is non-null and the protocol is webhook, the additional
/// fields (mode, callback_url, max_iterations, tools, state) are merged
/// into the request body.
pub fn dispatchStepWithOpts(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_token: []const u8,
    worker_protocol_raw: []const u8,
    worker_model: ?[]const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
    agent_opts: ?AgentOpts,
) !DispatchResult {
    const protocol = worker_protocol.parse(worker_protocol_raw) orelse {
        const err_msg = try std.fmt.allocPrint(allocator, "unsupported worker protocol: {s}", .{worker_protocol_raw});
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = err_msg,
        };
    };

    if (protocol == .mqtt) {
        return dispatchMqtt(allocator, worker_url, worker_token, run_id, step_id, rendered_prompt);
    }
    if (protocol == .redis_stream) {
        return dispatchRedis(allocator, worker_url, worker_token, run_id, step_id, rendered_prompt);
    }

    const url = worker_protocol.buildRequestUrl(allocator, worker_url, protocol) catch |err| switch (err) {
        error.WebhookUrlPathRequired => {
            return DispatchResult{
                .output = "",
                .success = false,
                .error_text = "webhook worker url must include explicit path (for example /webhook)",
            };
        },
        else => return err,
    };
    defer allocator.free(url);

    const body = buildRequestBody(
        allocator,
        protocol,
        worker_model,
        run_id,
        step_id,
        rendered_prompt,
        agent_opts,
    ) catch |err| switch (err) {
        error.MissingWorkerModel => {
            return DispatchResult{
                .output = "",
                .success = false,
                .error_text = "worker protocol openai_chat requires worker.model",
            };
        },
        else => {
            return DispatchResult{
                .output = "",
                .success = false,
                .error_text = "failed to build request body",
            };
        },
    };
    defer allocator.free(body);

    var auth_header: ?[]const u8 = null;
    if (worker_token.len > 0) {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{worker_token});
    }
    defer if (auth_header) |ah| allocator.free(ah);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var headers_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (auth_header) |ah| blk: {
        headers_buf[0] = .{ .name = "Authorization", .value = ah };
        break :blk headers_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch {
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "HTTP request failed",
        };
    };

    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        const err_msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{status_code});
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = err_msg,
        };
    }

    const response_data = response_body.written();
    return try worker_response.parse(allocator, response_data);
}

pub fn probeWorker(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_protocol_raw: []const u8,
) bool {
    const protocol = worker_protocol.parse(worker_protocol_raw) orelse return false;

    // Async protocols (mqtt/redis_stream) can't be probed via HTTP
    if (protocol == .mqtt or protocol == .redis_stream) return true;

    const url = worker_protocol.buildRequestUrl(allocator, worker_url, protocol) catch return false;
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch return false;

    const status_code = @intFromEnum(result.status);
    return status_code < 500;
}

fn buildRequestBody(
    allocator: std.mem.Allocator,
    protocol: worker_protocol.Protocol,
    worker_model: ?[]const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
    agent_opts: ?AgentOpts,
) ![]const u8 {
    const session_key = try std.fmt.allocPrint(allocator, "run_{s}_step_{s}", .{ run_id, step_id });
    defer allocator.free(session_key);

    switch (protocol) {
        .webhook => {
            // For agent steps with opts, build an extended body that includes
            // agent-specific fields alongside the standard webhook fields.
            if (agent_opts) |opts| {
                return buildWebhookAgentBody(allocator, session_key, rendered_prompt, opts);
            }
            return std.json.Stringify.valueAlloc(allocator, .{
                .message = rendered_prompt,
                .text = rendered_prompt,
                .session_key = session_key,
                .session_id = session_key,
            }, .{});
        },
        .api_chat => {
            return std.json.Stringify.valueAlloc(allocator, .{
                .message = rendered_prompt,
                .session_id = session_key,
            }, .{});
        },
        .openai_chat => {
            const model = worker_model orelse return error.MissingWorkerModel;
            const messages = [_]struct {
                role: []const u8,
                content: []const u8,
            }{
                .{ .role = "user", .content = rendered_prompt },
            };
            return std.json.Stringify.valueAlloc(allocator, .{
                .model = model,
                .stream = false,
                .messages = messages[0..],
            }, .{});
        },
        .mqtt, .redis_stream => {
            // MQTT and Redis Stream use async dispatch; body built by their respective clients
            return std.json.Stringify.valueAlloc(allocator, .{
                .message = rendered_prompt,
                .session_id = session_key,
            }, .{});
        },
    }
}

/// Build the webhook JSON body for an agent step, merging standard fields with
/// agent-specific optional fields (mode, callback_url, max_iterations, tools, state).
/// Only non-null fields from agent_opts are included in the output.
fn buildWebhookAgentBody(
    allocator: std.mem.Allocator,
    session_key: []const u8,
    rendered_prompt: []const u8,
    opts: AgentOpts,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Standard webhook fields
    try buf.appendSlice(allocator, "{\"message\":");
    try appendJsonString(&buf, allocator, rendered_prompt);
    try buf.appendSlice(allocator, ",\"text\":");
    try appendJsonString(&buf, allocator, rendered_prompt);
    try buf.appendSlice(allocator, ",\"session_key\":");
    try appendJsonString(&buf, allocator, session_key);
    try buf.appendSlice(allocator, ",\"session_id\":");
    try appendJsonString(&buf, allocator, session_key);

    // Optional agent fields
    if (opts.mode) |mode| {
        try buf.appendSlice(allocator, ",\"mode\":");
        try appendJsonString(&buf, allocator, mode);
    }
    if (opts.callback_url) |cb_url| {
        try buf.appendSlice(allocator, ",\"callback_url\":");
        try appendJsonString(&buf, allocator, cb_url);
    }
    if (opts.max_iterations) |max_iter| {
        const field = try std.fmt.allocPrint(allocator, ",\"max_iterations\":{d}", .{max_iter});
        defer allocator.free(field);
        try buf.appendSlice(allocator, field);
    }
    if (opts.tools_json) |tools| {
        // tools_json is already a JSON array string — embed it verbatim
        try buf.appendSlice(allocator, ",\"tools\":");
        try buf.appendSlice(allocator, tools);
    }
    if (opts.state_json) |state| {
        // state_json is already a JSON object/value — embed it verbatim
        try buf.appendSlice(allocator, ",\"state\":");
        try buf.appendSlice(allocator, state);
    }

    try buf.append(allocator, '}');

    return buf.toOwnedSlice(allocator);
}

/// Append a JSON-encoded string (with surrounding quotes and escapes) to buf.
fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |byte| {
        switch (byte) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const escaped = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{byte});
                defer allocator.free(escaped);
                try buf.appendSlice(allocator, escaped);
            },
            else => try buf.append(allocator, byte),
        }
    }
    try buf.append(allocator, '"');
}

/// Build the wire-format JSON body for async (MQTT/Redis) dispatch.
/// Includes correlation_id, reply_to topic/stream, timestamp, auth token,
/// the rendered prompt, and a session_key matching the correlation_id.
pub fn buildAsyncRequestBody(
    allocator: std.mem.Allocator,
    worker_token: []const u8,
    correlation_id: []const u8,
    reply_to: []const u8,
    rendered_prompt: []const u8,
) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .correlation_id = correlation_id,
        .reply_to = reply_to,
        .timestamp_ms = ids.nowMs(),
        .token = worker_token,
        .message = rendered_prompt,
        .session_key = correlation_id,
    }, .{});
}

// ── Async Protocol Dispatch ───────────────────────────────────────────

fn dispatchMqtt(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_token: []const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
) !DispatchResult {
    const url_parts = worker_protocol.parseMqttUrl(allocator, worker_url) catch {
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "invalid mqtt:// URL",
        };
    };
    defer allocator.free(url_parts.response_topic);

    const correlation_id = try std.fmt.allocPrint(allocator, "run_{s}_step_{s}", .{ run_id, step_id });

    const body = try buildAsyncRequestBody(
        allocator,
        worker_token,
        correlation_id,
        url_parts.response_topic,
        rendered_prompt,
    );
    defer allocator.free(body);

    // Null-terminate strings for C interop
    const host_z = try allocator.dupeZ(u8, url_parts.host);
    defer allocator.free(host_z);
    const topic_z = try allocator.dupeZ(u8, url_parts.topic);
    defer allocator.free(topic_z);

    var conn = mqtt_client.MqttConn.connect(host_z, url_parts.port) catch {
        allocator.free(correlation_id);
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "mqtt: failed to connect to broker",
        };
    };
    defer conn.disconnect();

    conn.publish(topic_z, body) catch {
        allocator.free(correlation_id);
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "mqtt: failed to publish message",
        };
    };

    return DispatchResult{
        .output = "",
        .success = true,
        .error_text = null,
        .async_pending = true,
        .correlation_id = correlation_id,
    };
}

fn dispatchRedis(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_token: []const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
) !DispatchResult {
    const url_parts = worker_protocol.parseRedisUrl(allocator, worker_url) catch {
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "invalid redis:// URL",
        };
    };
    defer allocator.free(url_parts.response_stream);

    const correlation_id = try std.fmt.allocPrint(allocator, "run_{s}_step_{s}", .{ run_id, step_id });

    const body = try buildAsyncRequestBody(
        allocator,
        worker_token,
        correlation_id,
        url_parts.response_stream,
        rendered_prompt,
    );
    defer allocator.free(body);

    // Null-terminate strings for C interop
    const host_z = try allocator.dupeZ(u8, url_parts.host);
    defer allocator.free(host_z);
    const stream_z = try allocator.dupeZ(u8, url_parts.stream_key);
    defer allocator.free(stream_z);

    const body_z = try allocator.dupeZ(u8, body);
    defer allocator.free(body_z);

    var conn = redis_client.RedisConn.connect(host_z, url_parts.port) catch {
        allocator.free(correlation_id);
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "redis: failed to connect",
        };
    };
    defer conn.disconnect();

    conn.xadd(stream_z, body_z) catch {
        allocator.free(correlation_id);
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "redis: failed to XADD message",
        };
    };

    return DispatchResult{
        .output = "",
        .success = true,
        .error_text = null,
        .async_pending = true,
        .correlation_id = correlation_id,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "selectWorker: finds matching worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\",\"researcher\"]",
            .max_concurrent = 3,
            .status = "active",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("w1", result.?.id);
}

test "selectWorker: skips dead worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 3,
            .status = "dead",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "selectWorker: skips overloaded worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 1,
            .status = "active",
            .current_tasks = 1,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "selectWorker: no matching tags" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"reviewer\"]",
            .max_concurrent = 3,
            .status = "active",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "selectWorker: skips draining worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 3,
            .status = "draining",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "selectWorker: picks least-loaded worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 5,
            .status = "active",
            .current_tasks = 3,
        },
        .{
            .id = "w2",
            .url = "http://localhost:3002",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 5,
            .status = "active",
            .current_tasks = 1,
        },
        .{
            .id = "w3",
            .url = "http://localhost:3003",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 5,
            .status = "active",
            .current_tasks = 2,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("w2", result.?.id);
}

test "selectWorker: empty workers list returns null" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{};
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "selectWorker: empty required tags matches any active worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "[\"coder\"]",
            .max_concurrent = 3,
            .status = "active",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("w1", result.?.id);
}

test "selectWorker: invalid JSON tags skips worker" {
    const allocator = std.testing.allocator;
    const workers = [_]WorkerInfo{
        .{
            .id = "w1",
            .url = "http://localhost:3001",
            .token = "tok",
            .tags_json = "not-json",
            .max_concurrent = 3,
            .status = "active",
            .current_tasks = 0,
        },
    };
    const tags = [_][]const u8{"coder"};
    const result = try selectWorker(allocator, &workers, &tags);
    try std.testing.expect(result == null);
}

test "workerMatchesTags: basic matching" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{"coder"};
    try std.testing.expect(try workerMatchesTags(allocator, "[\"coder\",\"reviewer\"]", &tags));
}

test "workerMatchesTags: no match" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{"deployer"};
    try std.testing.expect(!try workerMatchesTags(allocator, "[\"coder\",\"reviewer\"]", &tags));
}

test "workerMatchesTags: empty required returns true" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{};
    try std.testing.expect(try workerMatchesTags(allocator, "[\"coder\"]", &tags));
}

test "buildRequestBody: openai_chat requires model" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.MissingWorkerModel,
        buildRequestBody(allocator, .openai_chat, null, "run-1", "step-1", "hello", null),
    );
}

test "buildWebhookAgentBody: includes all agent fields when present" {
    const allocator = std.testing.allocator;
    const opts = AgentOpts{
        .mode = "autonomous",
        .callback_url = "http://localhost:8080/internal/agent-events/run-1/step-1",
        .max_iterations = 25,
        .tools_json = "[\"search\",\"code\"]",
        .state_json = "{\"foo\":\"bar\"}",
    };
    const body = try buildRequestBody(allocator, .webhook, null, "run-1", "step-1", "do something", opts);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("do something", obj.get("message").?.string);
    try std.testing.expectEqualStrings("autonomous", obj.get("mode").?.string);
    try std.testing.expectEqualStrings(
        "http://localhost:8080/internal/agent-events/run-1/step-1",
        obj.get("callback_url").?.string,
    );
    try std.testing.expectEqual(@as(i64, 25), obj.get("max_iterations").?.integer);
    // tools and state are embedded JSON — check they round-trip
    const tools_arr = obj.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 2), tools_arr.items.len);
    try std.testing.expectEqualStrings("search", tools_arr.items[0].string);
}

test "buildWebhookAgentBody: omits null agent fields" {
    const allocator = std.testing.allocator;
    const opts = AgentOpts{ .mode = "managed" };
    const body = try buildRequestBody(allocator, .webhook, null, "run-1", "step-1", "hello", opts);
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try std.testing.expectEqualStrings("managed", obj.get("mode").?.string);
    try std.testing.expect(obj.get("callback_url") == null);
    try std.testing.expect(obj.get("max_iterations") == null);
    try std.testing.expect(obj.get("tools") == null);
    try std.testing.expect(obj.get("state") == null);
}

test "buildAsyncRequestBody: produces valid wire-format JSON with all fields" {
    const allocator = std.testing.allocator;
    const before_ms = ids.nowMs();
    const body = try buildAsyncRequestBody(
        allocator,
        "worker-secret",
        "run_xxx_step_yyy",
        "nullclaw/planner/requests/responses",
        "rendered prompt text",
    );
    defer allocator.free(body);
    const after_ms = ids.nowMs();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Verify all 6 fields are present and correct
    try std.testing.expectEqualStrings("run_xxx_step_yyy", obj.get("correlation_id").?.string);
    try std.testing.expectEqualStrings("nullclaw/planner/requests/responses", obj.get("reply_to").?.string);
    try std.testing.expectEqualStrings("worker-secret", obj.get("token").?.string);
    try std.testing.expectEqualStrings("rendered prompt text", obj.get("message").?.string);
    try std.testing.expectEqualStrings("run_xxx_step_yyy", obj.get("session_key").?.string);

    // timestamp_ms must be a positive integer within the test window
    const ts = obj.get("timestamp_ms").?.integer;
    try std.testing.expect(ts >= before_ms);
    try std.testing.expect(ts <= after_ms);
}

test "dispatchMqtt: returns async_pending with correlation_id" {
    const allocator = std.testing.allocator;
    const result = try dispatchMqtt(
        allocator,
        "mqtt://broker:1883/nullclaw/planner/requests",
        "secret-token",
        "run-123",
        "step-456",
        "hello world",
    );
    defer allocator.free(result.correlation_id.?);
    try std.testing.expect(result.async_pending);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("run_run-123_step_step-456", result.correlation_id.?);
}

test "dispatchRedis: returns async_pending with correlation_id" {
    const allocator = std.testing.allocator;
    const result = try dispatchRedis(
        allocator,
        "redis://redis:6379/nullclaw:builder:requests",
        "secret-token",
        "run-abc",
        "step-def",
        "build this",
    );
    defer allocator.free(result.correlation_id.?);
    try std.testing.expect(result.async_pending);
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("run_run-abc_step_step-def", result.correlation_id.?);
}

test "dispatchMqtt: invalid URL returns error" {
    const allocator = std.testing.allocator;
    const result = try dispatchMqtt(allocator, "http://wrong", "token", "r", "s", "prompt");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("invalid mqtt:// URL", result.error_text.?);
}

test "dispatchRedis: invalid URL returns error" {
    const allocator = std.testing.allocator;
    const result = try dispatchRedis(allocator, "http://wrong", "token", "r", "s", "prompt");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("invalid redis:// URL", result.error_text.?);
}
