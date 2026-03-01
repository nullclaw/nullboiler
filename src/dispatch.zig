/// Worker dispatch module — sends rendered prompts to NullClaw workers via HTTP.
/// Provides worker selection (filtering by status, capacity, and tags) and
/// HTTP dispatch to worker webhook endpoints.

const std = @import("std");

// ── Types ─────────────────────────────────────────────────────────────

pub const WorkerInfo = struct {
    id: []const u8,
    url: []const u8,
    token: []const u8,
    tags_json: []const u8, // JSON array like ["coder","researcher"]
    max_concurrent: i64,
    status: []const u8, // "active", "draining", "dead"
    current_tasks: i64, // how many tasks currently assigned
};

pub const DispatchResult = struct {
    output: []const u8,
    success: bool,
    error_text: ?[]const u8,
};

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

/// Send a rendered prompt to a worker's /webhook endpoint via HTTP POST.
///
/// Builds the request body:
///   {"message": "<rendered_prompt>", "session_key": "run_<run_id>_step_<step_id>"}
///
/// Sets headers:
///   Authorization: Bearer <worker_token>
///   Content-Type: application/json
///
/// Returns DispatchResult with the worker's output on success, or an error
/// description on failure.
pub fn dispatchStep(
    allocator: std.mem.Allocator,
    worker_url: []const u8,
    worker_token: []const u8,
    run_id: []const u8,
    step_id: []const u8,
    rendered_prompt: []const u8,
) !DispatchResult {
    // Build the full webhook URL
    const url = try std.fmt.allocPrint(allocator, "{s}/webhook", .{worker_url});
    defer allocator.free(url);

    // Build the JSON body using the JSON serializer for proper escaping
    const body = std.json.Stringify.valueAlloc(allocator, .{
        .message = rendered_prompt,
        .session_key = try std.fmt.allocPrint(allocator, "run_{s}_step_{s}", .{ run_id, step_id }),
    }, .{}) catch {
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "failed to build request body",
        };
    };
    defer allocator.free(body);

    // Build authorization header
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{worker_token});
    defer allocator.free(auth_header);

    // Create HTTP client and make the request
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    // Set up a response body writer
    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_body.writer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = auth_header },
        },
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

    // Check HTTP status
    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        const err_msg = try std.fmt.allocPrint(allocator, "HTTP {d}", .{status_code});
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = err_msg,
        };
    }

    // Parse response JSON and extract "output" field
    const response_data = response_body.written();
    const parsed = std.json.parseFromSlice(
        struct { output: []const u8 },
        allocator,
        response_data,
        .{ .ignore_unknown_fields = true },
    ) catch {
        return DispatchResult{
            .output = "",
            .success = false,
            .error_text = "failed to parse response JSON",
        };
    };

    // Copy output to caller-owned memory since parsed will be freed
    const output = try allocator.dupe(u8, parsed.value.output);
    defer parsed.deinit();

    return DispatchResult{
        .output = output,
        .success = true,
        .error_text = null,
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
