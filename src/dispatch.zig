/// Worker dispatch module — protocol-aware HTTP dispatch for external bot workers.
/// Provides worker selection (filtering by status, capacity, and tags) and
/// request/response adapters for webhook/api_chat/openai_chat protocols.
const std = @import("std");
const worker_protocol = @import("worker_protocol.zig");
const worker_response = @import("worker_response.zig");

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
    const protocol = worker_protocol.parse(worker_protocol_raw) orelse {
        const err_msg = try std.fmt.allocPrint(allocator, "unsupported worker protocol: {s}", .{worker_protocol_raw});
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = err_msg,
        };
    };

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
) ![]const u8 {
    const session_key = try std.fmt.allocPrint(allocator, "run_{s}_step_{s}", .{ run_id, step_id });
    defer allocator.free(session_key);

    switch (protocol) {
        .webhook => {
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
    }
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
        buildRequestBody(allocator, .openai_chat, null, "run-1", "step-1", "hello"),
    );
}
