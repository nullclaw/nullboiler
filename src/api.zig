const std = @import("std");
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");
const types = @import("types.zig");
const workflow_validation = @import("workflow_validation.zig");
const worker_protocol = @import("worker_protocol.zig");
const metrics_mod = @import("metrics.zig");
const strategy_mod = @import("strategy.zig");
const tracker_mod = @import("tracker.zig");
const config_mod = @import("config.zig");
const sse_mod = @import("sse.zig");
const state_mod = @import("state.zig");
const engine_mod = @import("engine.zig");

// ── Types ────────────────────────────────────────────────────────────

pub const Context = struct {
    store: *Store,
    allocator: std.mem.Allocator,
    required_api_token: ?[]const u8 = null,
    request_bearer_token: ?[]const u8 = null,
    request_idempotency_key: ?[]const u8 = null,
    request_id: []const u8 = "",
    traceparent: ?[]const u8 = null,
    metrics: ?*metrics_mod.Metrics = null,
    drain_mode: ?*std.atomic.Value(bool) = null,
    strategies: ?*const strategy_mod.StrategyMap = null,
    tracker_state: ?*tracker_mod.TrackerState = null,
    tracker_cfg: ?*const config_mod.TrackerConfig = null,
    sse_hub: ?*sse_mod.SseHub = null,
    rate_limits: ?*std.StringHashMap(engine_mod.RateLimitInfo) = null,
};

pub const HttpResponse = struct {
    status: []const u8,
    body: []const u8,
    status_code: u16,
    content_type: []const u8 = "application/json",
};

// ── Router ───────────────────────────────────────────────────────────

pub fn handleRequest(ctx: *Context, method: []const u8, target: []const u8, body: []const u8) HttpResponse {
    if (ctx.metrics) |m| {
        metrics_mod.Metrics.incr(&m.http_requests_total);
    }

    const path = parsePath(target);
    const seg0 = decodePathSegment(ctx.allocator, getPathSegment(path, 0));
    const seg1 = decodePathSegment(ctx.allocator, getPathSegment(path, 1));
    const seg2 = decodePathSegment(ctx.allocator, getPathSegment(path, 2));
    const seg3 = decodePathSegment(ctx.allocator, getPathSegment(path, 3));
    const seg4 = decodePathSegment(ctx.allocator, getPathSegment(path, 4));

    const is_get = eql(method, "GET");
    const is_post = eql(method, "POST");
    const is_delete = eql(method, "DELETE");
    const is_put = eql(method, "PUT");

    if (!isAuthorized(ctx, seg0, seg1)) {
        return jsonResponse(401, "{\"error\":{\"code\":\"unauthorized\",\"message\":\"missing or invalid bearer token\"}}");
    }

    // GET /health
    if (is_get and eql(seg0, "health") and seg1 == null) {
        return handleHealth(ctx);
    }

    // GET /metrics
    if (is_get and eql(seg0, "metrics") and seg1 == null) {
        return handleMetrics(ctx);
    }

    // POST /runs
    if (is_post and eql(seg0, "runs") and seg1 == null) {
        return handleCreateRun(ctx, body);
    }

    // GET /runs
    if (is_get and eql(seg0, "runs") and seg1 == null) {
        return handleListRuns(ctx, target);
    }

    // GET /runs/{id}
    if (is_get and eql(seg0, "runs") and seg1 != null and seg2 == null) {
        return handleGetRun(ctx, seg1.?);
    }

    // POST /runs/{id}/cancel
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "cancel") and seg3 == null) {
        return handleCancelRun(ctx, seg1.?);
    }

    // POST /runs/{id}/retry
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "retry") and seg3 == null) {
        return handleRetryRun(ctx, seg1.?);
    }

    // GET /runs/{id}/steps
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 == null) {
        return handleListSteps(ctx, seg1.?);
    }

    // GET /runs/{id}/steps/{step_id}
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and seg4 == null) {
        return handleGetStep(ctx, seg1.?, seg3.?);
    }

    // GET /runs/{id}/events
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "events") and seg3 == null) {
        return handleListEvents(ctx, seg1.?);
    }

    // GET /workers
    if (is_get and eql(seg0, "workers") and seg1 == null) {
        return handleListWorkers(ctx);
    }

    // POST /workers
    if (is_post and eql(seg0, "workers") and seg1 == null) {
        return handleRegisterWorker(ctx, body);
    }

    // DELETE /workers/{id}
    if (is_delete and eql(seg0, "workers") and seg1 != null and seg2 == null) {
        return handleDeleteWorker(ctx, seg1.?);
    }

    // POST /admin/drain
    if (is_post and eql(seg0, "admin") and eql(seg1, "drain") and seg2 == null) {
        return handleEnableDrain(ctx);
    }

    // GET /tracker/status
    if (is_get and eql(seg0, "tracker") and eql(seg1, "status") and seg2 == null) {
        return handleTrackerStatus(ctx);
    }

    // GET /tracker/tasks
    if (is_get and eql(seg0, "tracker") and eql(seg1, "tasks") and seg2 == null) {
        return handleTrackerTasks(ctx);
    }

    // GET /tracker/stats
    if (is_get and eql(seg0, "tracker") and eql(seg1, "stats") and seg2 == null) {
        return handleTrackerStats(ctx);
    }

    // GET /tracker/tasks/{task_id}
    if (is_get and eql(seg0, "tracker") and eql(seg1, "tasks") and seg2 != null and seg3 == null) {
        return handleTrackerTaskDetail(ctx, seg2.?);
    }

    // POST /tracker/refresh
    if (is_post and eql(seg0, "tracker") and eql(seg1, "refresh") and seg2 == null) {
        return handleTrackerRefresh(ctx);
    }

    // GET /rate-limits
    if (is_get and eql(seg0, "rate-limits") and seg1 == null) {
        return handleGetRateLimits(ctx);
    }

    // ── Workflow CRUD ───────────────────────────────────────────────

    // POST /workflows
    if (is_post and eql(seg0, "workflows") and seg1 == null) {
        return handleCreateWorkflow(ctx, body);
    }

    // GET /workflows
    if (is_get and eql(seg0, "workflows") and seg1 == null) {
        return handleListWorkflows(ctx);
    }

    // GET /workflows/{id}
    if (is_get and eql(seg0, "workflows") and seg1 != null and seg2 == null) {
        return handleGetWorkflow(ctx, seg1.?);
    }

    // PUT /workflows/{id}
    if (is_put and eql(seg0, "workflows") and seg1 != null and seg2 == null) {
        return handleUpdateWorkflow(ctx, seg1.?, body);
    }

    // DELETE /workflows/{id}
    if (is_delete and eql(seg0, "workflows") and seg1 != null and seg2 == null) {
        return handleDeleteWorkflow(ctx, seg1.?);
    }

    // POST /workflows/{id}/validate
    if (is_post and eql(seg0, "workflows") and seg1 != null and eql(seg2, "validate") and seg3 == null) {
        return handleValidateWorkflow(ctx, seg1.?);
    }

    // GET /workflows/{id}/mermaid
    if (is_get and eql(seg0, "workflows") and seg1 != null and eql(seg2, "mermaid") and seg3 == null) {
        return handleGetMermaid(ctx, seg1.?);
    }

    // POST /workflows/{id}/run
    if (is_post and eql(seg0, "workflows") and seg1 != null and eql(seg2, "run") and seg3 == null) {
        return handleRunWorkflow(ctx, seg1.?, body);
    }

    // ── Checkpoint endpoints ────────────────────────────────────────

    // GET /runs/{id}/checkpoints
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "checkpoints") and seg3 == null) {
        return handleListCheckpoints(ctx, seg1.?);
    }

    // GET /runs/{id}/checkpoints/{cpId}
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "checkpoints") and seg3 != null and seg4 == null) {
        return handleGetCheckpoint(ctx, seg1.?, seg3.?);
    }

    // ── State control endpoints ─────────────────────────────────────

    // POST /runs/{id}/resume
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "resume") and seg3 == null) {
        return handleResumeRun(ctx, seg1.?, body);
    }

    // POST /runs/fork
    if (is_post and eql(seg0, "runs") and eql(seg1, "fork") and seg2 == null) {
        return handleForkRun(ctx, body);
    }

    // POST /runs/{id}/state
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "state") and seg3 == null) {
        return handleInjectState(ctx, seg1.?, body);
    }

    // ── SSE stream endpoint ─────────────────────────────────────────

    // GET /runs/{id}/stream
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "stream") and seg3 == null) {
        return handleStream(ctx, seg1.?, target);
    }

    // ── Replay endpoint ────────────────────────────────────────────

    // POST /runs/{id}/replay
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "replay") and seg3 == null) {
        return handleReplayRun(ctx, seg1.?, body);
    }

    // ── Agent events callback ───────────────────────────────────────

    // POST /internal/agent-events/{run_id}/{step_id}
    if (is_post and eql(seg0, "internal") and eql(seg1, "agent-events") and seg2 != null and seg3 != null and seg4 == null) {
        return handleAgentEventCallback(ctx, seg2.?, seg3.?, body);
    }

    return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"endpoint not found\"}}");
}

// ── Handlers ─────────────────────────────────────────────────────────

fn handleHealth(ctx: *Context) HttpResponse {
    // Count active runs
    const active_runs = ctx.store.getActiveRuns(ctx.allocator) catch {
        return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"2026.3.2\",\"active_runs\":0,\"total_workers\":0}");
    };
    const active_count = active_runs.len;

    // Count total workers
    const workers = ctx.store.listWorkers(ctx.allocator) catch {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"status":"ok","version":"2026.3.2","active_runs":{d},"total_workers":0}}
        , .{active_count}) catch return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"2026.3.2\"}");
        return jsonResponse(200, resp);
    };
    const worker_count = workers.len;

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"status":"ok","version":"2026.3.2","active_runs":{d},"total_workers":{d}}}
    , .{ active_count, worker_count }) catch return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"2026.3.2\"}");
    return jsonResponse(200, resp);
}

fn handleMetrics(ctx: *Context) HttpResponse {
    const m = ctx.metrics orelse return plainResponse(200, "nullboiler_metrics_disabled 1\n");
    const body = m.renderPrometheus(ctx.allocator) catch return plainResponse(500, "nullboiler_metrics_render_error 1\n");
    return plainResponse(200, body);
}

fn handleEnableDrain(ctx: *Context) HttpResponse {
    const drain = ctx.drain_mode orelse {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"drain mode is not configured\"}}");
    };
    drain.store(true, .release);
    return jsonResponse(200, "{\"status\":\"draining\"}");
}

// ── Rate Limit Handler ──────────────────────────────────────────────

fn handleGetRateLimits(ctx: *Context) HttpResponse {
    const rl_map = ctx.rate_limits orelse {
        return jsonResponse(200, "[]");
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    var it = rl_map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) {
            buf.append(ctx.allocator, ',') catch continue;
        }
        first = false;

        const rl = entry.value_ptr.*;
        const wid_json = jsonQuoted(ctx.allocator, rl.worker_id) catch continue;
        const item = std.fmt.allocPrint(ctx.allocator,
            \\{{"worker_id":{s},"remaining":{d},"limit":{d},"reset_ms":{d},"updated_at_ms":{d}}}
        , .{ wid_json, rl.remaining, rl.limit, rl.reset_ms, rl.updated_at_ms }) catch continue;
        buf.appendSlice(ctx.allocator, item) catch continue;
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, buf.items);
}

// ── Worker Handlers ──────────────────────────────────────────────────

fn handleListWorkers(ctx: *Context) HttpResponse {
    const workers = ctx.store.listWorkers(ctx.allocator) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to list workers\"}}");
    };

    // Build JSON array manually
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (workers, 0..) |w, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const id_json = jsonQuoted(ctx.allocator, w.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const url_json = jsonQuoted(ctx.allocator, w.url) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const protocol_json = jsonQuoted(ctx.allocator, w.protocol) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const model_json = if (w.model) |model|
            jsonQuoted(ctx.allocator, model) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}")
        else
            "null";
        const source_json = jsonQuoted(ctx.allocator, w.source) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const status_json = jsonQuoted(ctx.allocator, w.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const circuit_until_field = if (w.circuit_open_until_ms) |ts|
            std.fmt.allocPrint(ctx.allocator, ",\"circuit_open_until_ms\":{d}", .{ts}) catch ""
        else
            "";
        const last_error_field = if (w.last_error_text) |err_text| blk: {
            const err_json = jsonQuoted(ctx.allocator, err_text) catch "";
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"last_error_text\":{s}", .{err_json}) catch "";
        } else "";
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{s},"url":{s},"protocol":{s},"model":{s},"tags":{s},"max_concurrent":{d},"source":{s},"status":{s},"consecutive_failures":{d}{s}{s},"created_at_ms":{d}}}
        , .{
            id_json,
            url_json,
            protocol_json,
            model_json,
            w.tags_json,
            w.max_concurrent,
            source_json,
            status_json,
            w.consecutive_failures,
            circuit_until_field,
            last_error_field,
            w.created_at_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleRegisterWorker(ctx: *Context, body: []const u8) HttpResponse {
    // Parse JSON body
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }

    const obj = root.object;

    // Extract required fields
    const worker_id = getJsonString(obj, "id") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: id\"}}");
    };
    const url = getJsonString(obj, "url") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: url\"}}");
    };
    const token = getJsonString(obj, "token") orelse "";
    const protocol_raw = getJsonString(obj, "protocol") orelse "webhook";
    const model = getJsonString(obj, "model");

    const protocol = worker_protocol.parse(protocol_raw) orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid protocol (expected webhook|api_chat|openai_chat|mqtt|redis_stream|a2a)\"}}");
    };
    if (!worker_protocol.validateUrlForProtocol(url, protocol)) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"webhook protocol requires explicit URL path (for example /webhook)\"}}");
    }
    if (worker_protocol.requiresModel(protocol) and model == null) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"openai_chat protocol requires model\"}}");
    }

    const existing = ctx.store.getWorker(ctx.allocator, worker_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to check worker id\"}}");
    };
    if (existing != null) {
        return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"worker id already exists\"}}");
    }

    // Extract tags as JSON string
    const tags_json = if (obj.get("tags")) |tags_val| blk: {
        if (tags_val != .array) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"tags must be an array of strings\"}}");
        }
        for (tags_val.array.items) |tag_item| {
            if (tag_item != .string) {
                return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"tags must be an array of strings\"}}");
            }
        }
        var out: std.io.Writer.Allocating = .init(ctx.allocator);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.write(tags_val) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize tags\"}}");
        break :blk out.toOwnedSlice() catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    } else "[]";

    // Extract max_concurrent
    const max_concurrent: i64 = if (obj.get("max_concurrent")) |mc| blk: {
        if (mc != .integer) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"max_concurrent must be a positive integer\"}}");
        }
        if (mc.integer < 1) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"max_concurrent must be >= 1\"}}");
        }
        break :blk mc.integer;
    } else 1;

    ctx.store.insertWorker(worker_id, url, token, protocol_raw, model, tags_json, max_concurrent, "registered") catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert worker\"}}");
    };

    const worker_id_json = jsonQuoted(ctx.allocator, worker_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const protocol_json = jsonQuoted(ctx.allocator, protocol_raw) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"active","protocol":{s}}}
    , .{ worker_id_json, protocol_json }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(201, resp);
}

fn handleDeleteWorker(ctx: *Context, id: []const u8) HttpResponse {
    ctx.store.deleteWorker(id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to delete worker\"}}");
    };
    return jsonResponse(200, "{\"ok\":true}");
}

// ── Run Handlers ─────────────────────────────────────────────────────

fn handleCreateRun(ctx: *Context, body: []const u8) HttpResponse {
    if (ctx.drain_mode) |drain| {
        if (drain.load(.acquire)) {
            return jsonResponse(503, "{\"error\":{\"code\":\"draining\",\"message\":\"orchestrator is draining and does not accept new runs\"}}");
        }
    }

    // Parse body JSON
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }

    const obj = root.object;
    const body_idempotency_key = getJsonString(obj, "idempotency_key");
    const idempotency_key = ctx.request_idempotency_key orelse body_idempotency_key;
    if (idempotency_key) |ik| {
        if (ik.len == 0) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"idempotency key must not be empty\"}}");
        }
        const existing_run = ctx.store.getRunByIdempotencyKey(ctx.allocator, ik) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to check idempotency key\"}}");
        };
        if (existing_run) |run| {
            if (!std.mem.eql(u8, run.workflow_json, body)) {
                return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"idempotency key already used with different payload\"}}");
            }
            if (ctx.metrics) |m| {
                metrics_mod.Metrics.incr(&m.runs_idempotent_replays_total);
            }
            const run_id_json = jsonQuoted(ctx.allocator, run.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            const status_json = jsonQuoted(ctx.allocator, run.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            const replay_resp = std.fmt.allocPrint(ctx.allocator,
                \\{{"id":{s},"status":{s},"idempotent_replay":true}}
            , .{ run_id_json, status_json }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            return jsonResponse(200, replay_resp);
        }
    }

    // Extract steps array
    const steps_val = obj.get("steps") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: steps\"}}");
    };
    if (steps_val != .array) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"steps must be an array\"}}");
    }
    // Expand strategy if present
    const effective_steps = if (obj.get("strategy") != null and ctx.strategies != null) blk: {
        const expanded = strategy_mod.expandStrategy(ctx.allocator, ctx.strategies.?.*, obj) catch |err| {
            return switch (err) {
                error.UnknownStrategy => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"unknown strategy\"}}"),
                error.DependsOnConflict => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"cannot use depends_on with strategy\"}}"),
                error.StepsMissing => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: steps\"}}"),
                error.StepMustBeObject => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"steps items must be objects\"}}"),
                error.OutOfMemory => jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"strategy expansion failed\"}}"),
            };
        };
        if (expanded != .array) {
            break :blk steps_val.array.items;
        }
        break :blk expanded.array.items;
    } else steps_val.array.items;

    const steps_array = effective_steps;

    if (steps_array.len == 0) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"steps array must not be empty\"}}");
    }

    workflow_validation.validateStepsForCreateRun(ctx.allocator, steps_array) catch |err| {
        return validationErrorResponse(err);
    };

    // Serialize input and callbacks back to JSON for storage
    const input_json = serializeJsonValue(ctx.allocator, obj.get("input")) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize input\"}}");
    };
    const callbacks_json = serializeJsonValue(ctx.allocator, obj.get("callbacks")) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize callbacks\"}}");
    };

    ctx.store.beginTransaction() catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to start transaction\"}}");
    };
    var tx_committed = false;
    defer {
        if (!tx_committed) {
            ctx.store.rollbackTransaction() catch {};
        }
    }

    // Generate run_id
    const run_id_buf = ids.generateId();
    const run_id = ctx.allocator.dupe(u8, &run_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // Insert run — workflow_json = the original body (frozen snapshot)
    ctx.store.insertRun(run_id, idempotency_key, "running", body, input_json, callbacks_json) catch {
        if (idempotency_key) |ik| {
            const existing = ctx.store.getRunByIdempotencyKey(ctx.allocator, ik) catch null;
            if (existing) |run| {
                if (!std.mem.eql(u8, run.workflow_json, body)) {
                    return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"idempotency key already used with different payload\"}}");
                }
                if (ctx.metrics) |m| {
                    metrics_mod.Metrics.incr(&m.runs_idempotent_replays_total);
                }
                const run_id_json = jsonQuoted(ctx.allocator, run.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
                const status_json = jsonQuoted(ctx.allocator, run.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
                const replay_resp = std.fmt.allocPrint(ctx.allocator,
                    \\{{"id":{s},"status":{s},"idempotent_replay":true}}
                , .{ run_id_json, status_json }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
                return jsonResponse(200, replay_resp);
            }
        }
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert run\"}}");
    };

    // Build mapping from def_step_id -> generated step_id
    // Use parallel arrays for simplicity
    var def_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var gen_ids: std.ArrayListUnmanaged([]const u8) = .empty;

    // First pass: create all steps
    for (steps_array) |step_val| {
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validated step missing id\"}}");
        };
        const step_type = getJsonString(step_obj, "type") orelse "task";

        // Generate step_id
        const step_id_buf = ids.generateId();
        const step_id = ctx.allocator.dupe(u8, &step_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

        // Determine initial status: "ready" if no depends_on, "pending" otherwise
        const has_deps = if (step_obj.get("depends_on")) |deps| blk: {
            if (deps == .array and deps.array.items.len > 0) break :blk true;
            break :blk false;
        } else false;
        const initial_status: []const u8 = if (has_deps) "pending" else "ready";

        // Extract max_attempts from retry config (default 1)
        const max_attempts: i64 = if (step_obj.get("retry")) |retry_val| blk: {
            if (retry_val == .object) {
                if (retry_val.object.get("max_attempts")) |ma| {
                    if (ma == .integer) break :blk ma.integer;
                }
            }
            break :blk 1;
        } else 1;

        // Extract timeout_ms (nullable)
        const timeout_ms: ?i64 = if (step_obj.get("timeout_ms")) |t| blk: {
            if (t == .integer) break :blk t.integer;
            break :blk null;
        } else null;

        ctx.store.insertStep(step_id, run_id, def_step_id, step_type, initial_status, "{}", max_attempts, timeout_ms, null, null) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert step\"}}");
        };

        def_ids.append(ctx.allocator, def_step_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        gen_ids.append(ctx.allocator, step_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    // Second pass: insert step dependencies
    for (steps_array) |step_val| {
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validated step missing id\"}}");
        };

        // Find the generated step_id for this def_step_id
        const step_id = lookupGenId(def_ids.items, gen_ids.items, def_step_id) orelse {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validated step id lookup failed\"}}");
        };

        // Process depends_on
        const deps_val = step_obj.get("depends_on") orelse continue;
        if (deps_val != .array) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on must be an array\"}}");
        }

        for (deps_val.array.items) |dep_item| {
            if (dep_item != .string) {
                return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on items must be strings\"}}");
            }
            const dep_def_id = dep_item.string;

            // Find the generated step_id for this dependency
            const dep_step_id = lookupGenId(def_ids.items, gen_ids.items, dep_def_id) orelse {
                return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validated dependency lookup failed\"}}");
            };

            ctx.store.insertStepDep(step_id, dep_step_id) catch {
                return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert step dependency\"}}");
            };
        }
    }

    // Return 201 with run info
    const run_id_json = jsonQuoted(ctx.allocator, run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    ctx.store.commitTransaction() catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to commit transaction\"}}");
    };
    tx_committed = true;
    if (ctx.metrics) |m| {
        metrics_mod.Metrics.incr(&m.runs_created_total);
    }
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"running","idempotent_replay":false}}
    , .{run_id_json}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(201, resp);
}

fn handleGetRun(ctx: *Context, id: []const u8) HttpResponse {
    const run = ctx.store.getRun(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    const steps = ctx.store.getStepsByRun(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get steps\"}}");
    };

    // Build steps JSON array
    const steps_json = buildStepsJson(ctx.allocator, steps) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to build steps JSON\"}}");
    };

    const error_field = if (run.error_text) |et| blk: {
        const et_json = jsonQuoted(ctx.allocator, et) catch "";
        break :blk std.fmt.allocPrint(ctx.allocator, ",\"error_text\":{s}", .{et_json}) catch "";
    } else "";

    const started_field = if (run.started_at_ms) |s|
        std.fmt.allocPrint(ctx.allocator, ",\"started_at_ms\":{d}", .{s}) catch ""
    else
        "";

    const ended_field = if (run.ended_at_ms) |e|
        std.fmt.allocPrint(ctx.allocator, ",\"ended_at_ms\":{d}", .{e}) catch ""
    else
        "";

    const idempotency_field = if (run.idempotency_key) |ik| blk: {
        const ik_json = jsonQuoted(ctx.allocator, ik) catch "";
        break :blk std.fmt.allocPrint(ctx.allocator, ",\"idempotency_key\":{s}", .{ik_json}) catch "";
    } else "";
    const workflow_id_field = if (run.workflow_id) |wid| blk: {
        const wid_json = jsonQuoted(ctx.allocator, wid) catch "";
        break :blk std.fmt.allocPrint(ctx.allocator, ",\"workflow_id\":{s}", .{wid_json}) catch "";
    } else "";

    // Include state_json if present
    const state_field = if (run.state_json) |sj|
        std.fmt.allocPrint(ctx.allocator, ",\"state_json\":{s}", .{sj}) catch ""
    else
        "";

    // Count checkpoints
    const checkpoints = ctx.store.listCheckpoints(ctx.allocator, id) catch &.{};
    const checkpoint_count: i64 = @intCast(checkpoints.len);
    const checkpoint_field = std.fmt.allocPrint(ctx.allocator, ",\"checkpoint_count\":{d}", .{checkpoint_count}) catch "";

    // Token accounting (Gap 2)
    var token_input: i64 = 0;
    var token_output: i64 = 0;
    var token_total: i64 = 0;
    if (ctx.store.getRunTokens(id)) |t| {
        token_input = t.input;
        token_output = t.output;
        token_total = t.total;
    } else |_| {}
    const token_field = std.fmt.allocPrint(ctx.allocator, ",\"total_input_tokens\":{d},\"total_output_tokens\":{d},\"total_tokens\":{d}", .{ token_input, token_output, token_total }) catch "";

    const run_id_json = jsonQuoted(ctx.allocator, run.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const run_status_json = jsonQuoted(ctx.allocator, run.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":{s}{s},"created_at_ms":{d},"updated_at_ms":{d}{s}{s}{s}{s}{s}{s}{s},"steps":{s}}}
    , .{
        run_id_json,
        run_status_json,
        idempotency_field,
        run.created_at_ms,
        run.updated_at_ms,
        workflow_id_field,
        error_field,
        started_field,
        ended_field,
        state_field,
        checkpoint_field,
        token_field,
        steps_json,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleListRuns(ctx: *Context, target: []const u8) HttpResponse {
    const status_filter = getQueryParam(target, "status");
    const workflow_id_filter = getQueryParam(target, "workflow_id");
    const limit = parseQueryInt(target, "limit", 100, 1, 1000);
    const offset = parseQueryInt(target, "offset", 0, 0, 1_000_000_000);

    // Fetch one extra row to compute has_more.
    const runs = ctx.store.listRuns(ctx.allocator, status_filter, workflow_id_filter, limit + 1, offset) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to list runs\"}}");
    };

    const has_more = @as(i64, @intCast(runs.len)) > limit;
    const items_len: usize = if (has_more) @intCast(limit) else runs.len;

    var items_buf: std.ArrayListUnmanaged(u8) = .empty;
    items_buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (runs[0..items_len], 0..) |r, i| {
        if (i > 0) {
            items_buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const run_id_json = jsonQuoted(ctx.allocator, r.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const run_status_json = jsonQuoted(ctx.allocator, r.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const idempotency_field = if (r.idempotency_key) |ik| blk: {
            const ik_json = jsonQuoted(ctx.allocator, ik) catch "";
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"idempotency_key\":{s}", .{ik_json}) catch "";
        } else "";
        const workflow_id_field = if (r.workflow_id) |wid| blk: {
            const wid_json = jsonQuoted(ctx.allocator, wid) catch "";
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"workflow_id\":{s}", .{wid_json}) catch "";
        } else "";
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{s},"status":{s}{s}{s},"created_at_ms":{d},"updated_at_ms":{d}}}
        , .{
            run_id_json,
            run_status_json,
            idempotency_field,
            workflow_id_field,
            r.created_at_ms,
            r.updated_at_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        items_buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    items_buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const items_json = items_buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    const next_offset = if (has_more) offset + limit else offset + @as(i64, @intCast(items_len));
    const response = std.fmt.allocPrint(ctx.allocator,
        \\{{"items":{s},"limit":{d},"offset":{d},"next_offset":{d},"has_more":{s}}}
    , .{
        items_json,
        limit,
        offset,
        next_offset,
        if (has_more) "true" else "false",
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, response);
}

// ── Step Handlers ────────────────────────────────────────────────────

fn handleListSteps(ctx: *Context, run_id: []const u8) HttpResponse {
    // Verify run exists
    _ = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    const steps = ctx.store.getStepsByRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get steps\"}}");
    };

    const steps_json = buildStepsJson(ctx.allocator, steps) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to build steps JSON\"}}");
    };

    return jsonResponse(200, steps_json);
}

fn handleGetStep(ctx: *Context, run_id: []const u8, step_id: []const u8) HttpResponse {
    const step = switch (lookupStepInRun(ctx, run_id, step_id)) {
        .ok => |s| s,
        .err => |resp| return resp,
    };

    const step_json = buildSingleStepJson(ctx.allocator, step) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to build step JSON\"}}");
    };

    return jsonResponse(200, step_json);
}

// ── Stub Handlers (not yet implemented) ──────────────────────────────

fn handleCancelRun(ctx: *Context, run_id: []const u8) HttpResponse {
    // 1. Get run from store
    const run = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    // 2. If already in a terminal state, return 409
    if (std.mem.eql(u8, run.status, "completed") or
        std.mem.eql(u8, run.status, "failed") or
        std.mem.eql(u8, run.status, "cancelled"))
    {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"run is already {s}"}}}}
        , .{run.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"run is in a terminal state\"}}");
        return jsonResponse(409, resp);
    }

    // 3. Update run status to "cancelled"
    ctx.store.updateRunStatus(run_id, "cancelled", null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to cancel run\"}}");
    };

    // 4. Mark all pending/ready steps as "skipped"
    const steps = ctx.store.getStepsByRun(ctx.allocator, run_id) catch {
        // Run is cancelled but steps may not be updated — log and continue
        return jsonResponse(200, std.fmt.allocPrint(ctx.allocator,
            \\{{"id":"{s}","status":"cancelled"}}
        , .{run_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}"));
    };

    for (steps) |step| {
        if (std.mem.eql(u8, step.status, "pending") or std.mem.eql(u8, step.status, "ready")) {
            ctx.store.updateStepStatus(step.id, "skipped", null, null, null, step.attempt) catch {};
        }
    }

    // 5. Insert event
    ctx.store.insertEvent(run_id, null, "run.cancelled", "{}") catch {};

    // 6. Mark SSE queue closed but keep buffered events available for late subscribers.
    if (ctx.sse_hub) |hub| hub.closeQueue(run_id);

    // 7. Return 200
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":"{s}","status":"cancelled"}}
    , .{run_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleRetryRun(ctx: *Context, run_id: []const u8) HttpResponse {
    // 1. Get run from store
    const run = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    // 2. Can only retry a failed run
    if (!std.mem.eql(u8, run.status, "failed")) {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"run is not failed (current: {s})"}}}}
        , .{run.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"run is not failed\"}}");
        return jsonResponse(409, resp);
    }

    // 3. Find all failed steps, reset to "ready", increment attempt
    const steps = ctx.store.getStepsByRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get steps\"}}");
    };

    for (steps) |step| {
        if (std.mem.eql(u8, step.status, "failed")) {
            ctx.store.updateStepStatus(step.id, "ready", null, null, null, step.attempt + 1) catch {};
        }
    }

    // 4. Set run status back to "running"
    ctx.store.updateRunStatus(run_id, "running", null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run status\"}}");
    };

    // 5. Insert event
    ctx.store.insertEvent(run_id, null, "run.retried", "{}") catch {};

    // 6. Return 200
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":"{s}","status":"running"}}
    , .{run_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleListEvents(ctx: *Context, run_id: []const u8) HttpResponse {
    // 1. Get events from store
    const events = ctx.store.getEventsByRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get events\"}}");
    };

    // 2. Build JSON array
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (events, 0..) |ev, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }

        const step_field = if (ev.step_id) |sid| blk: {
            const sid_json = jsonQuoted(ctx.allocator, sid) catch "";
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"step_id\":{s}", .{sid_json}) catch "";
        } else "";
        const run_id_json = jsonQuoted(ctx.allocator, ev.run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const kind_json = jsonQuoted(ctx.allocator, ev.kind) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{d},"run_id":{s}{s},"kind":{s},"data":{s},"ts_ms":{d}}}
        , .{
            ev.id,
            run_id_json,
            step_field,
            kind_json,
            ev.data_json,
            ev.ts_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

// ── Workflow CRUD Handlers ───────────────────────────────────────────

fn handleCreateWorkflow(ctx: *Context, body: []const u8) HttpResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    const name = getJsonString(obj, "name") orelse "untitled";

    // Use provided id or generate one
    const wf_id = if (getJsonString(obj, "id")) |provided_id|
        ctx.allocator.dupe(u8, provided_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}")
    else blk: {
        const id_buf = ids.generateId();
        break :blk ctx.allocator.dupe(u8, &id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    };

    // If definition_json is a sub-key, extract it; otherwise use the whole body
    const definition_json = if (obj.get("definition_json")) |def_val| blk: {
        break :blk serializeJsonValue(ctx.allocator, def_val) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize definition\"}}");
    } else body;

    // Extract version from body (default 1)
    const version: i64 = if (obj.get("version")) |v| blk: {
        if (v == .integer) break :blk v.integer;
        break :blk 1;
    } else 1;

    ctx.store.createWorkflowWithVersion(wf_id, name, definition_json, version) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create workflow\"}}");
    };

    const id_json = jsonQuoted(ctx.allocator, wf_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const name_json = jsonQuoted(ctx.allocator, name) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"name":{s},"version":{d}}}
    , .{ id_json, name_json, version }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(201, resp);
}

fn handleListWorkflows(ctx: *Context) HttpResponse {
    const workflows = ctx.store.listWorkflows(ctx.allocator) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to list workflows\"}}");
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (workflows, 0..) |wf, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const id_json = jsonQuoted(ctx.allocator, wf.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const name_json = jsonQuoted(ctx.allocator, wf.name) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{s},"name":{s},"version":{d},"definition":{s},"created_at_ms":{d},"updated_at_ms":{d}}}
        , .{
            id_json,
            name_json,
            wf.version,
            wf.definition_json,
            wf.created_at_ms,
            wf.updated_at_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleGetWorkflow(ctx: *Context, id: []const u8) HttpResponse {
    const wf = ctx.store.getWorkflow(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    const id_json = jsonQuoted(ctx.allocator, wf.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const name_json = jsonQuoted(ctx.allocator, wf.name) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"name":{s},"version":{d},"definition":{s},"created_at_ms":{d},"updated_at_ms":{d}}}
    , .{
        id_json,
        name_json,
        wf.version,
        wf.definition_json,
        wf.created_at_ms,
        wf.updated_at_ms,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleUpdateWorkflow(ctx: *Context, id: []const u8, body: []const u8) HttpResponse {
    // Verify workflow exists
    _ = ctx.store.getWorkflow(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    const name = getJsonString(obj, "name") orelse "untitled";
    const definition_json = if (obj.get("definition_json")) |def_val| blk: {
        break :blk serializeJsonValue(ctx.allocator, def_val) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize definition\"}}");
    } else body;

    // Extract version if provided
    const version: ?i64 = if (obj.get("version")) |v| blk: {
        if (v == .integer) break :blk v.integer;
        break :blk null;
    } else null;

    ctx.store.updateWorkflowWithVersion(id, name, definition_json, version) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update workflow\"}}");
    };

    return jsonResponse(200, "{\"ok\":true}");
}

fn handleDeleteWorkflow(ctx: *Context, id: []const u8) HttpResponse {
    // Verify workflow exists
    _ = ctx.store.getWorkflow(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    ctx.store.deleteWorkflow(id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to delete workflow\"}}");
    };

    return jsonResponse(200, "{\"ok\":true}");
}

fn handleValidateWorkflow(ctx: *Context, id: []const u8) HttpResponse {
    const wf = ctx.store.getWorkflow(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    const errors = workflow_validation.validate(ctx.allocator, wf.definition_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validation failed\"}}");
    };

    // Build validation result
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.appendSlice(ctx.allocator, "{\"valid\":") catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    buf.appendSlice(ctx.allocator, if (errors.len == 0) "true" else "false") catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    buf.appendSlice(ctx.allocator, ",\"errors\":[") catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (errors, 0..) |ve, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const err_type_json = jsonQuoted(ctx.allocator, ve.err_type) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const node_field = if (ve.node) |n| blk: {
            const n_json = jsonQuoted(ctx.allocator, n) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"node\":{s}", .{n_json}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        } else "";
        const key_field = if (ve.key) |k| blk: {
            const k_json = jsonQuoted(ctx.allocator, k) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"key\":{s}", .{k_json}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        } else "";
        const msg_json = jsonQuoted(ctx.allocator, ve.message) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"type":{s}{s}{s},"message":{s}}}
        , .{
            err_type_json,
            node_field,
            key_field,
            msg_json,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.appendSlice(ctx.allocator, "]") catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // Include Mermaid diagram in validation response
    const mermaid_str = engine_mod.generateMermaid(ctx.allocator, wf.definition_json) catch null;
    if (mermaid_str) |ms| {
        const mermaid_json = jsonQuoted(ctx.allocator, ms) catch null;
        if (mermaid_json) |mj| {
            buf.appendSlice(ctx.allocator, ",\"mermaid\":") catch {};
            buf.appendSlice(ctx.allocator, mj) catch {};
        }
    }

    buf.appendSlice(ctx.allocator, "}") catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleGetMermaid(ctx: *Context, id: []const u8) HttpResponse {
    const wf = ctx.store.getWorkflow(ctx.allocator, id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    const mermaid = engine_mod.generateMermaid(ctx.allocator, wf.definition_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to generate mermaid diagram\"}}");
    };

    return plainResponse(200, mermaid);
}

fn handleRunWorkflow(ctx: *Context, workflow_id: []const u8, body: []const u8) HttpResponse {
    // Load workflow
    const wf = ctx.store.getWorkflow(ctx.allocator, workflow_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get workflow\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"workflow not found\"}}");
    };

    // Validate
    const errors = workflow_validation.validate(ctx.allocator, wf.definition_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"validation failed\"}}");
    };
    if (errors.len > 0) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"workflow has validation errors\"}}");
    }

    // Parse definition to extract state_schema for initState
    const def_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, wf.definition_json, .{}) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to parse workflow definition\"}}");
    };
    defer def_parsed.deinit();

    const schema_json = if (def_parsed.value == .object) blk: {
        if (def_parsed.value.object.get("state_schema")) |ss| {
            break :blk serializeJsonValue(ctx.allocator, ss) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize schema\"}}");
        }
        break :blk "{}";
    } else "{}";

    // Parse input from request body (or default to {})
    const input_json = if (body.len > 0) blk: {
        const bp = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch break :blk "{}";
        defer bp.deinit();
        if (bp.value == .object) {
            if (bp.value.object.get("input")) |input_val| {
                break :blk serializeJsonValue(ctx.allocator, input_val) catch break :blk "{}";
            }
        }
        break :blk "{}";
    } else "{}";

    // Init state
    const initial_state = state_mod.initState(ctx.allocator, input_json, schema_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to initialize state\"}}");
    };

    // Generate run ID
    const run_id_buf = ids.generateId();
    const run_id = ctx.allocator.dupe(u8, &run_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // Create run directly with "running" status to avoid race window where
    // engine could miss a run created as "pending" then updated to "running".
    ctx.store.createRunWithStateAndStatus(run_id, workflow_id, wf.definition_json, input_json, initial_state, "running") catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create run\"}}");
    };

    // Create initial checkpoint (version 0, no completed nodes)
    const cp_id_buf = ids.generateId();
    const cp_id = ctx.allocator.dupe(u8, &cp_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    ctx.store.createCheckpoint(cp_id, run_id, "__init__", null, initial_state, "[]", 0, null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create checkpoint\"}}");
    };

    const run_id_json = jsonQuoted(ctx.allocator, run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"running"}}
    , .{run_id_json}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(201, resp);
}

// ── Checkpoint Handlers ─────────────────────────────────────────────

fn handleListCheckpoints(ctx: *Context, run_id: []const u8) HttpResponse {
    // Verify run exists
    _ = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    const checkpoints = ctx.store.listCheckpoints(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to list checkpoints\"}}");
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (checkpoints, 0..) |cp, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const entry = buildCheckpointJson(ctx.allocator, cp) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleGetCheckpoint(ctx: *Context, run_id: []const u8, cp_id: []const u8) HttpResponse {
    const cp = ctx.store.getCheckpoint(ctx.allocator, cp_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get checkpoint\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"checkpoint not found\"}}");
    };

    // Verify checkpoint belongs to run
    if (!std.mem.eql(u8, cp.run_id, run_id)) {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"checkpoint not found\"}}");
    }

    const json_body = buildCheckpointJson(ctx.allocator, cp) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn buildCheckpointJson(allocator: std.mem.Allocator, cp: types.CheckpointRow) ![]const u8 {
    const id_json = try jsonQuoted(allocator, cp.id);
    const run_id_json = try jsonQuoted(allocator, cp.run_id);
    const step_id_json = try jsonQuoted(allocator, cp.step_id);
    const parent_field = if (cp.parent_id) |pid| blk: {
        const pid_json = try jsonQuoted(allocator, pid);
        break :blk try std.fmt.allocPrint(allocator, ",\"parent_id\":{s}", .{pid_json});
    } else "";
    const metadata_field = if (cp.metadata_json) |md|
        try std.fmt.allocPrint(allocator, ",\"metadata\":{s}", .{md})
    else
        "";

    return try std.fmt.allocPrint(allocator,
        \\{{"id":{s},"run_id":{s},"step_id":{s}{s},"state":{s},"completed_nodes":{s},"version":{d}{s},"created_at_ms":{d}}}
    , .{
        id_json,
        run_id_json,
        step_id_json,
        parent_field,
        cp.state_json,
        cp.completed_nodes_json,
        cp.version,
        metadata_field,
        cp.created_at_ms,
    });
}

// ── State Control Handlers ──────────────────────────────────────────

fn handleResumeRun(ctx: *Context, run_id: []const u8, body: []const u8) HttpResponse {
    // Load run — must be status=interrupted
    const run = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    if (!std.mem.eql(u8, run.status, "interrupted")) {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"run is not interrupted (current: {s})"}}}}
        , .{run.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"run is not interrupted\"}}");
        return jsonResponse(409, resp);
    }

    // Load latest checkpoint
    const latest_cp = ctx.store.getLatestCheckpoint(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get latest checkpoint\"}}");
    } orelse {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"no checkpoint found for run\"}}");
    };

    // Get current state
    var current_state = latest_cp.state_json;

    // Apply state_updates from body if provided
    if (body.len > 0) {
        const bp = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{});
        if (bp) |body_parsed| {
            defer body_parsed.deinit();

            if (body_parsed.value == .object) {
                if (body_parsed.value.object.get("state_updates")) |updates_val| {
                    const updates_json = serializeJsonValue(ctx.allocator, updates_val) catch {
                        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize updates\"}}");
                    };

                    // Get schema from workflow definition
                    const schema_json = getSchemaFromRun(ctx, run);

                    current_state = state_mod.applyUpdates(ctx.allocator, latest_cp.state_json, updates_json, schema_json) catch {
                        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to apply state updates\"}}");
                    };
                }
            }
        } else |_| {
            // Body is not valid JSON — proceed without updates
        }
    }

    // Save new state
    ctx.store.updateRunState(run_id, current_state) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run state\"}}");
    };

    // Set status to running
    ctx.store.updateRunStatus(run_id, "running", null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run status\"}}");
    };

    const run_id_json = jsonQuoted(ctx.allocator, run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"running"}}
    , .{run_id_json}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleForkRun(ctx: *Context, body: []const u8) HttpResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    // Get checkpoint_id from body
    const checkpoint_id = getJsonString(obj, "checkpoint_id") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: checkpoint_id\"}}");
    };

    // Load checkpoint
    const cp = ctx.store.getCheckpoint(ctx.allocator, checkpoint_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get checkpoint\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"checkpoint not found\"}}");
    };

    // Load the original run to get workflow_json
    const orig_run = ctx.store.getRun(ctx.allocator, cp.run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get original run\"}}");
    } orelse {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"original run not found\"}}");
    };

    // Apply state_overrides if provided
    var fork_state = cp.state_json;
    if (obj.get("state_overrides")) |overrides_val| {
        const overrides_json = serializeJsonValue(ctx.allocator, overrides_val) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize overrides\"}}");
        };
        const schema_json = getSchemaFromRun(ctx, orig_run);
        fork_state = state_mod.applyUpdates(ctx.allocator, cp.state_json, overrides_json, schema_json) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to apply state overrides\"}}");
        };
    }

    // Generate new run ID
    const new_run_id_buf = ids.generateId();
    const new_run_id = ctx.allocator.dupe(u8, &new_run_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // Create forked run
    ctx.store.createForkedRun(new_run_id, orig_run.workflow_json, fork_state, cp.run_id, checkpoint_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create forked run\"}}");
    };

    // Create initial checkpoint for forked run
    const cp_id_buf = ids.generateId();
    const cp_id = ctx.allocator.dupe(u8, &cp_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    ctx.store.createCheckpoint(cp_id, new_run_id, "__fork__", checkpoint_id, fork_state, cp.completed_nodes_json, 0, null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create checkpoint\"}}");
    };

    // Set to running
    ctx.store.updateRunStatus(new_run_id, "running", null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run status\"}}");
    };

    const run_id_json = jsonQuoted(ctx.allocator, new_run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"running","forked_from_checkpoint":{s}}}
    , .{ run_id_json, checkpoint_id }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(201, resp);
}

// ── Replay Handler ──────────────────────────────────────────────────

fn handleReplayRun(ctx: *Context, run_id: []const u8, body: []const u8) HttpResponse {
    // Parse replay checkpoint ID. Accept both the canonical
    // `from_checkpoint_id` field and the older `checkpoint_id` alias so
    // existing clients keep working.
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    const checkpoint_id = getJsonString(obj, "from_checkpoint_id") orelse getJsonString(obj, "checkpoint_id") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: from_checkpoint_id or checkpoint_id\"}}");
    };

    // Load checkpoint
    const cp = ctx.store.getCheckpoint(ctx.allocator, checkpoint_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get checkpoint\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"checkpoint not found\"}}");
    };

    // Verify checkpoint belongs to this run
    if (!std.mem.eql(u8, cp.run_id, run_id)) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"checkpoint does not belong to this run\"}}");
    }

    // Load run to verify it exists
    _ = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    // Delete steps and checkpoints created after the replay checkpoint
    // so the engine re-executes from a clean slate.
    ctx.store.deleteStepsAfterTimestamp(run_id, cp.created_at_ms) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to clear old steps\"}}");
    };
    ctx.store.deleteCheckpointsAfterVersion(run_id, cp.version) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to clear old checkpoints\"}}");
    };

    // Reset run state to checkpoint's state
    ctx.store.updateRunState(run_id, cp.state_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run state\"}}");
    };

    // Set run status to running — engine will pick it up on next tick
    // with the checkpoint's completed_nodes
    ctx.store.updateRunStatus(run_id, "running", null) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run status\"}}");
    };

    ctx.store.insertEvent(run_id, null, "run.replayed", "{}") catch {};

    const run_id_json = jsonQuoted(ctx.allocator, run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const cp_id_json = jsonQuoted(ctx.allocator, checkpoint_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":"running","replayed_from_checkpoint":{s}}}
    , .{ run_id_json, cp_id_json }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleInjectState(ctx: *Context, run_id: []const u8, body: []const u8) HttpResponse {
    // Verify run exists
    const run = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    // Get updates
    const updates_val = obj.get("updates") orelse {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"missing required field: updates\"}}");
    };
    const updates_json = serializeJsonValue(ctx.allocator, updates_val) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize updates\"}}");
    };

    // Check apply_after_step
    const apply_after_step = getJsonString(obj, "apply_after_step");

    if (apply_after_step == null) {
        // Apply immediately to run.state_json
        const current_state = run.state_json orelse "{}";
        const schema_json = getSchemaFromRun(ctx, run);
        const new_state = state_mod.applyUpdates(ctx.allocator, current_state, updates_json, schema_json) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to apply state updates\"}}");
        };
        ctx.store.updateRunState(run_id, new_state) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update run state\"}}");
        };
        return jsonResponse(200, "{\"applied\":true}");
    } else {
        // Insert into pending_state_injections
        ctx.store.createPendingInjection(run_id, updates_json, apply_after_step) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create pending injection\"}}");
        };
        return jsonResponse(200, "{\"applied\":false,\"pending\":true}");
    }
}

// ── SSE Stream Handler ──────────────────────────────────────────────

fn handleStream(ctx: *Context, run_id: []const u8, target: []const u8) HttpResponse {
    // For now, return the current state and events as a regular JSON response.
    // Full SSE streaming with held-open connections will be implemented
    // when the threading model is wired in main.zig (Task 12).
    //
    // Supports ?mode=values,tasks,debug,updates,custom query param to filter
    // which streaming modes the client wants. Default: all modes.
    const run = ctx.store.getRun(ctx.allocator, run_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get run\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"run not found\"}}");
    };

    // Parse requested modes from ?mode= query param
    const mode_param = getQueryParam(target, "mode");
    const after_seq = if (getQueryParam(target, "after_seq")) |raw|
        std.fmt.parseInt(u64, raw, 10) catch 0
    else
        0;
    var requested_modes: [5]bool = .{ true, true, true, true, true }; // all modes by default
    if (mode_param) |modes_str| {
        // Reset all to false, then enable requested
        requested_modes = .{ false, false, false, false, false };
        var mode_it = std.mem.splitScalar(u8, modes_str, ',');
        while (mode_it.next()) |mode_name| {
            if (sse_mod.StreamMode.fromString(mode_name)) |m| {
                requested_modes[@intFromEnum(m)] = true;
            }
        }
    }

    const events_json = if (after_seq == 0) blk: {
        const events = ctx.store.getEventsByRun(ctx.allocator, run_id) catch {
            return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get events\"}}");
        };

        // Build events JSON array
        var events_buf: std.ArrayListUnmanaged(u8) = .empty;
        events_buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        for (events, 0..) |ev, i| {
            if (i > 0) {
                events_buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            }
            const kind_json = jsonQuoted(ctx.allocator, ev.kind) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            const entry = std.fmt.allocPrint(ctx.allocator,
                \\{{"kind":{s},"data":{s},"ts_ms":{d}}}
            , .{ kind_json, ev.data_json, ev.ts_ms }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            events_buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        events_buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        break :blk events_buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    } else "[]";

    // If SSE hub available, snapshot queued SSE events filtered by requested modes
    var sse_events_json: []const u8 = "[]";
    var latest_stream_seq: u64 = 0;
    var oldest_stream_seq: u64 = 0;
    var stream_gap = false;
    if (ctx.sse_hub) |hub| {
        const queue = hub.getOrCreateQueue(run_id);
        const snapshot = queue.snapshotSince(ctx.allocator, after_seq);
        latest_stream_seq = snapshot.latest_seq;
        oldest_stream_seq = snapshot.oldest_seq;
        stream_gap = snapshot.gap_detected;
        if (snapshot.events.len > 0) {
            var sse_buf: std.ArrayListUnmanaged(u8) = .empty;
            sse_buf.append(ctx.allocator, '[') catch {};
            var first = true;
            for (snapshot.events) |sse_ev| {
                // Filter by requested modes
                if (!requested_modes[@intFromEnum(sse_ev.mode)]) continue;
                if (!first) {
                    sse_buf.append(ctx.allocator, ',') catch {};
                }
                first = false;
                const mode_str = sse_ev.mode.toString();
                const sse_entry = std.fmt.allocPrint(ctx.allocator,
                    \\{{"seq":{d},"event":{s},"mode":"{s}","data":{s}}}
                , .{
                    sse_ev.seq,
                    jsonQuoted(ctx.allocator, sse_ev.event_type) catch "\"\"",
                    mode_str,
                    sse_ev.data,
                }) catch continue;
                sse_buf.appendSlice(ctx.allocator, sse_entry) catch {};
            }
            sse_buf.append(ctx.allocator, ']') catch {};
            sse_events_json = sse_buf.toOwnedSlice(ctx.allocator) catch "[]";
        }
    }

    const status_json = jsonQuoted(ctx.allocator, run.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const state_field = if (run.state_json) |sj|
        std.fmt.allocPrint(ctx.allocator, ",\"state\":{s}", .{sj}) catch ""
    else
        "";

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"status":{s}{s},"events":{s},"stream_events":{s},"next_stream_seq":{d},"stream_oldest_seq":{d},"stream_gap":{s}}}
    , .{
        status_json,
        state_field,
        events_json,
        sse_events_json,
        latest_stream_seq,
        oldest_stream_seq,
        if (stream_gap) "true" else "false",
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

// ── Agent Events Callback Handler ───────────────────────────────────

fn handleAgentEventCallback(ctx: *Context, run_id: []const u8, step_id: []const u8, body: []const u8) HttpResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid JSON body\"}}");
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"body must be a JSON object\"}}");
    }
    const obj = parsed.value.object;

    const iteration: i64 = if (obj.get("iteration")) |it| blk: {
        if (it == .integer) break :blk it.integer;
        break :blk 0;
    } else 0;

    const tool = getJsonString(obj, "tool");
    const args_json = if (obj.get("args")) |args_val|
        serializeJsonValue(ctx.allocator, args_val) catch null
    else
        null;
    const result_text = getJsonString(obj, "result");
    const status = getJsonString(obj, "status") orelse "running";

    ctx.store.createAgentEvent(run_id, step_id, iteration, tool, args_json, result_text, status) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to create agent event\"}}");
    };

    // If sse_hub is available, broadcast as agent_event
    if (ctx.sse_hub) |hub| {
        const event_data = std.fmt.allocPrint(ctx.allocator,
            \\{{"run_id":"{s}","step_id":"{s}","iteration":{d},"status":"{s}"}}
        , .{ run_id, step_id, iteration, status }) catch "";
        if (event_data.len > 0) {
            hub.broadcast(run_id, .{ .event_type = "agent_event", .data = event_data });
        }
    }

    return jsonResponse(200, "{\"ok\":true}");
}

// ── State Helper ────────────────────────────────────────────────────

fn getSchemaFromRun(ctx: *Context, run: types.RunRow) []const u8 {
    const def_parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, run.workflow_json, .{}) catch return "{}";
    defer def_parsed.deinit();
    if (def_parsed.value != .object) return "{}";
    if (def_parsed.value.object.get("state_schema")) |ss| {
        return serializeJsonValue(ctx.allocator, ss) catch "{}";
    }
    return "{}";
}

// ── Tracker Handlers ─────────────────────────────────────────────────

fn formatRunningTask(allocator: std.mem.Allocator, task: tracker_mod.RunningTask) ![]const u8 {
    const task_id_json = try jsonQuoted(allocator, task.task_id);
    const title_json = try jsonQuoted(allocator, task.task_title);
    const pipeline_json = try jsonQuoted(allocator, task.pipeline_id);
    const role_json = try jsonQuoted(allocator, task.agent_role);
    const exec_json = try jsonQuoted(allocator, task.execution_mode);
    const state_json = try jsonQuoted(allocator, task.state.toString());

    return std.fmt.allocPrint(allocator,
        \\{{"task_id":{s},"task_title":{s},"pipeline_id":{s},"agent_role":{s},"execution":{s},"current_turn":{d},"max_turns":{d},"started_at_ms":{d},"last_activity_ms":{d},"state":{s}}}
    , .{
        task_id_json,
        title_json,
        pipeline_json,
        role_json,
        exec_json,
        task.current_turn,
        task.max_turns,
        task.started_at_ms,
        task.last_activity_ms,
        state_json,
    });
}

fn handleTrackerStatus(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };
    const cfg = ctx.tracker_cfg orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    // Build running tasks array
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (state.running.values(), 0..) |task, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const entry = formatRunningTask(ctx.allocator, task) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const running_json = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"mode":"pull","running_count":{d},"max_concurrent":{d},"completed_count":{d},"failed_count":{d},"poll_interval_ms":{d},"running":{s}}}
    , .{
        state.runningCount(),
        cfg.concurrency.max_concurrent_tasks,
        state.completed_count,
        state.failed_count,
        cfg.poll_interval_ms,
        running_json,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    return jsonResponse(200, resp);
}

fn handleTrackerTasks(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (state.running.values(), 0..) |task, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const entry = formatRunningTask(ctx.allocator, task) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleTrackerTaskDetail(ctx: *Context, task_id: []const u8) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const task = state.running.get(task_id) orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"task not found\"}}");
    };

    const json_body = formatRunningTask(ctx.allocator, task) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
}

fn handleTrackerStats(ctx: *Context) HttpResponse {
    const state = ctx.tracker_state orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };
    const cfg = ctx.tracker_cfg orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"tracker_disabled\",\"message\":\"pull-mode tracker is not configured\"}}");
    };

    state.mutex.lock();
    defer state.mutex.unlock();

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"running":{d},"completed":{d},"failed":{d},"total":{d},"max_concurrent":{d}}}
    , .{
        state.runningCount(),
        state.completed_count,
        state.failed_count,
        state.completed_count + state.failed_count + state.runningCount(),
        cfg.concurrency.max_concurrent_tasks,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleTrackerRefresh(ctx: *Context) HttpResponse {
    _ = ctx;
    return jsonResponse(200, "{\"status\":\"ok\",\"message\":\"refresh requested\"}");
}

// ── JSON Helpers ─────────────────────────────────────────────────────

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

fn serializeJsonValue(allocator: std.mem.Allocator, val: ?std.json.Value) ![]const u8 {
    const v = val orelse return "{}";
    if (v == .null) return "{}";
    var out: std.io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.write(v);
    return try out.toOwnedSlice();
}

fn jsonQuoted(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn validationErrorResponse(err: workflow_validation.ValidateError) HttpResponse {
    return switch (err) {
        error.StepMustBeObject => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"each step must be an object\"}}"),
        error.StepIdMissingOrNotString => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"each step must have string field 'id'\"}}"),
        error.StepIdEmpty => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"step id must not be empty\"}}"),
        error.StepIdDuplicate => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"duplicate step id\"}}"),
        error.DependsOnNotArray => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on must be an array\"}}"),
        error.DependsOnItemNotString => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on items must be strings\"}}"),
        error.DependsOnDuplicate => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on contains duplicate step id\"}}"),
        error.DependsOnUnknownStepId => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"depends_on references unknown step id\"}}"),
        error.RetryMustBeObject => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"retry must be an object\"}}"),
        error.MaxAttemptsMustBePositiveInteger => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"retry.max_attempts must be a positive integer\"}}"),
        error.TimeoutMsMustBePositiveInteger => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"timeout_ms must be a positive integer\"}}"),
        error.OutOfMemory => jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}"),
    };
}

const StepLookup = union(enum) {
    ok: types.StepRow,
    err: HttpResponse,
};

fn lookupStepInRun(ctx: *Context, run_id: []const u8, step_id: []const u8) StepLookup {
    const step = ctx.store.getStep(ctx.allocator, step_id) catch {
        return .{ .err = jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get step\"}}") };
    } orelse {
        return .{ .err = jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}") };
    };
    if (!std.mem.eql(u8, step.run_id, run_id)) {
        return .{ .err = jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}") };
    }
    return .{ .ok = step };
}

fn lookupGenId(def_ids: []const []const u8, gen_ids: []const []const u8, target: []const u8) ?[]const u8 {
    for (def_ids, 0..) |did, i| {
        if (std.mem.eql(u8, did, target)) return gen_ids[i];
    }
    return null;
}

fn buildStepsJson(allocator: std.mem.Allocator, steps: []const @import("types.zig").StepRow) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(allocator, '[');

    for (steps, 0..) |s, i| {
        if (i > 0) {
            try buf.append(allocator, ',');
        }
        const entry = try buildSingleStepJson(allocator, s);
        try buf.appendSlice(allocator, entry);
    }

    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

fn buildSingleStepJson(allocator: std.mem.Allocator, s: @import("types.zig").StepRow) ![]const u8 {
    const id_json = try jsonQuoted(allocator, s.id);
    const run_id_json = try jsonQuoted(allocator, s.run_id);
    const def_step_id_json = try jsonQuoted(allocator, s.def_step_id);
    const type_json = try jsonQuoted(allocator, s.type);
    const status_json = try jsonQuoted(allocator, s.status);

    const worker_field = if (s.worker_id) |wid| blk: {
        const wid_json = try jsonQuoted(allocator, wid);
        break :blk try std.fmt.allocPrint(allocator, ",\"worker_id\":{s}", .{wid_json});
    } else "";

    const output_field = if (s.output_json) |oj|
        try std.fmt.allocPrint(allocator, ",\"output_json\":{s}", .{oj})
    else
        "";

    const error_field = if (s.error_text) |et| blk: {
        const et_json = try jsonQuoted(allocator, et);
        break :blk try std.fmt.allocPrint(allocator, ",\"error_text\":{s}", .{et_json});
    } else "";

    const timeout_field = if (s.timeout_ms) |t|
        try std.fmt.allocPrint(allocator, ",\"timeout_ms\":{d}", .{t})
    else
        "";

    const next_attempt_field = if (s.next_attempt_at_ms) |nxt|
        try std.fmt.allocPrint(allocator, ",\"next_attempt_at_ms\":{d}", .{nxt})
    else
        "";

    const parent_field = if (s.parent_step_id) |pid| blk: {
        const pid_json = try jsonQuoted(allocator, pid);
        break :blk try std.fmt.allocPrint(allocator, ",\"parent_step_id\":{s}", .{pid_json});
    } else "";

    const item_field = if (s.item_index) |idx|
        try std.fmt.allocPrint(allocator, ",\"item_index\":{d}", .{idx})
    else
        "";

    const started_field = if (s.started_at_ms) |st|
        try std.fmt.allocPrint(allocator, ",\"started_at_ms\":{d}", .{st})
    else
        "";

    const ended_field = if (s.ended_at_ms) |en|
        try std.fmt.allocPrint(allocator, ",\"ended_at_ms\":{d}", .{en})
    else
        "";

    const child_run_field = if (s.child_run_id) |crid| blk: {
        const crid_json = try jsonQuoted(allocator, crid);
        break :blk try std.fmt.allocPrint(allocator, ",\"child_run_id\":{s}", .{crid_json});
    } else "";

    return try std.fmt.allocPrint(allocator,
        \\{{"id":{s},"run_id":{s},"def_step_id":{s},"type":{s},"status":{s},"attempt":{d},"max_attempts":{d},"iteration_index":{d},"created_at_ms":{d},"updated_at_ms":{d}{s}{s}{s}{s}{s}{s}{s}{s}{s}{s}}}
    , .{
        id_json,
        run_id_json,
        def_step_id_json,
        type_json,
        status_json,
        s.attempt,
        s.max_attempts,
        s.iteration_index,
        s.created_at_ms,
        s.updated_at_ms,
        worker_field,
        output_field,
        error_field,
        timeout_field,
        next_attempt_field,
        parent_field,
        item_field,
        started_field,
        ended_field,
        child_run_field,
    });
}

// ── Helpers ──────────────────────────────────────────────────────────

const max_segments = 8;

fn parsePath(target: []const u8) [max_segments]?[]const u8 {
    var segments: [max_segments]?[]const u8 = .{null} ** max_segments;
    // Strip query string
    const path = if (std.mem.indexOf(u8, target, "?")) |qi| target[0..qi] else target;
    var it = std.mem.splitScalar(u8, path, '/');
    var i: usize = 0;
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (i >= max_segments) break;
        segments[i] = seg;
        i += 1;
    }
    return segments;
}

fn getQueryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const qi = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qi + 1 ..];
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse {
            if (std.mem.eql(u8, part, key)) return "";
            continue;
        };
        const qk = part[0..eq];
        if (!std.mem.eql(u8, qk, key)) continue;
        return part[eq + 1 ..];
    }
    return null;
}

fn parseQueryInt(target: []const u8, key: []const u8, default_val: i64, min: i64, max: i64) i64 {
    const raw = getQueryParam(target, key) orelse return default_val;
    const parsed = std.fmt.parseInt(i64, raw, 10) catch return default_val;
    if (parsed < min) return min;
    if (parsed > max) return max;
    return parsed;
}

fn getPathSegment(segments: [max_segments]?[]const u8, index: usize) ?[]const u8 {
    if (index >= max_segments) return null;
    return segments[index];
}

fn decodePathSegment(allocator: std.mem.Allocator, segment: ?[]const u8) ?[]const u8 {
    const raw = segment orelse return null;
    if (std.mem.indexOfScalar(u8, raw, '%') == null) return raw;

    const encoded = allocator.dupe(u8, raw) catch return raw;
    return std.Uri.percentDecodeInPlace(encoded);
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    if (a) |val| return std.mem.eql(u8, val, b);
    return false;
}

fn isAuthorized(ctx: *Context, seg0: ?[]const u8, seg1: ?[]const u8) bool {
    const required = ctx.required_api_token orelse return true;

    // Keep health and metrics endpoints unauthenticated for probes/scrapers.
    if (eql(seg0, "health") and seg1 == null) return true;
    if (eql(seg0, "metrics") and seg1 == null) return true;

    const provided = ctx.request_bearer_token orelse return false;
    return std.mem.eql(u8, provided, required);
}

fn jsonResponse(status_code: u16, body: []const u8) HttpResponse {
    const status = switch (status_code) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        401 => "401 Unauthorized",
        400 => "400 Bad Request",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        503 => "503 Service Unavailable",
        500 => "500 Internal Server Error",
        501 => "501 Not Implemented",
        else => "500 Internal Server Error",
    };
    return HttpResponse{
        .status = status,
        .body = body,
        .status_code = status_code,
        .content_type = "application/json",
    };
}

fn plainResponse(status_code: u16, body: []const u8) HttpResponse {
    const status = switch (status_code) {
        200 => "200 OK",
        500 => "500 Internal Server Error",
        else => "500 Internal Server Error",
    };
    return HttpResponse{
        .status = status,
        .body = body,
        .status_code = status_code,
        .content_type = "text/plain; charset=utf-8",
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "API: create run rejects unknown dependency" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work","depends_on":["missing"]}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: create run requires bearer token when auth enabled" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .required_api_token = "secret-token",
        .request_bearer_token = null,
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work"}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 401), resp.status_code);
}

test "API: create run accepts valid bearer token when auth enabled" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .required_api_token = "secret-token",
        .request_bearer_token = "secret-token",
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work"}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
}

test "API: health remains public when auth enabled" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .required_api_token = "secret-token",
        .request_bearer_token = null,
    };

    const resp = handleRequest(&ctx, "GET", "/health", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "API: create run rejects non-object retry field" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work","retry":1}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: create run rejects non-positive retry.max_attempts" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work","retry":{"max_attempts":0}}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: create run rejects non-positive timeout_ms" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work","timeout_ms":0}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: create run rejects duplicate depends_on items" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"steps":[{"id":"a","type":"task","prompt_template":"a"},{"id":"b","type":"task","prompt_template":"b","depends_on":["a","a"]}]}
    ;
    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: get step enforces run ownership" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("run-a", null, "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertRun("run-b", null, "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertStep("step-b-1", "run-b", "s1", "task", "ready", "{}", 1, null, null, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const resp = handleRequest(&ctx, "GET", "/runs/run-a/steps/step-b-1", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "API: register worker rejects non-array tags" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"w1","url":"http://localhost:3000/webhook","tags":"coder"}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: register worker rejects non-string tags items" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"w1","url":"http://localhost:3000/webhook","tags":["ok",123]}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: register webhook worker requires explicit path" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"w1","url":"http://localhost:3000","protocol":"webhook","tags":["ok"]}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: register worker rejects non-positive max_concurrent" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"w1","url":"http://localhost:3000/webhook","max_concurrent":0}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: register openai_chat worker requires model" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"openai-1","url":"http://localhost:42617/v1/chat/completions","protocol":"openai_chat"}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: register worker rejects duplicate id with conflict" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertWorker(
        "dup-worker",
        "http://localhost:3000/webhook",
        "tok",
        "webhook",
        null,
        "[]",
        1,
        "registered",
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"id":"dup-worker","url":"http://localhost:3001/webhook"}
    ;
    const resp = handleRequest(&ctx, "POST", "/workers", body);
    try std.testing.expectEqual(@as(u16, 409), resp.status_code);
}

test "API: create run idempotency key replays existing run" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .request_idempotency_key = "idem-1",
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work"}]}
    ;
    const first = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 201), first.status_code);

    const second = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 200), second.status_code);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"idempotent_replay\":true") != null);
}

test "API: idempotency key with different payload returns conflict" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .request_idempotency_key = "idem-diff",
    };

    const body_a =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"a"}]}
    ;
    const body_b =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"b"}]}
    ;

    const first = handleRequest(&ctx, "POST", "/runs", body_a);
    try std.testing.expectEqual(@as(u16, 201), first.status_code);

    const second = handleRequest(&ctx, "POST", "/runs", body_b);
    try std.testing.expectEqual(@as(u16, 409), second.status_code);
}

test "API: create run returns 503 in drain mode" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var drain_mode = std.atomic.Value(bool).init(true);
    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .drain_mode = &drain_mode,
    };

    const body =
        \\{"steps":[{"id":"s1","type":"task","prompt_template":"do work"}]}
    ;
    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

test "API: metrics endpoint returns text format" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var metrics = metrics_mod.Metrics{};
    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .metrics = &metrics,
    };

    const resp = handleRequest(&ctx, "GET", "/metrics", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.startsWith(u8, resp.content_type, "text/plain"));
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "nullboiler_http_requests_total") != null);
}

test "API: list runs supports workflow_id filter" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createWorkflowWithVersion("wf_1", "WF 1", "{\"nodes\":{},\"edges\":[]}", 1);
    try store.createWorkflowWithVersion("wf_2", "WF 2", "{\"nodes\":{},\"edges\":[]}", 1);
    try store.createRunWithStateAndStatus("r1", "wf_1", "{\"nodes\":{},\"edges\":[]}", "{}", "{}", "running");
    try store.createRunWithStateAndStatus("r2", "wf_2", "{\"nodes\":{},\"edges\":[]}", "{}", "{}", "running");

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const resp = handleRequest(&ctx, "GET", "/runs?workflow_id=wf_1", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"workflow_id\":\"wf_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"workflow_id\":\"wf_2\"") == null);
}

test "API: replay run from checkpoint" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create a run with a checkpoint
    try store.createRunWithState("r1", null, "{\"nodes\":{}}", "{}", "{\"x\":1}");
    try store.updateRunStatus("r1", "completed", null);
    try store.createCheckpoint("cp1", "r1", "step_a", null, "{\"x\":1}", "[\"step_a\"]", 1, null);

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"from_checkpoint_id":"cp1"}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs/r1/replay", body);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "running") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "replayed_from_checkpoint") != null);

    // Verify run state was reset to checkpoint state
    const run = (try store.getRun(arena.allocator(), "r1")).?;
    try std.testing.expectEqualStrings("running", run.status);
    if (run.state_json) |sj| {
        try std.testing.expectEqualStrings("{\"x\":1}", sj);
    }
}

test "API: replay run accepts checkpoint_id alias" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createRunWithState("r1", null, "{\"nodes\":{}}", "{}", "{\"x\":1}");
    try store.updateRunStatus("r1", "completed", null);
    try store.createCheckpoint("cp1", "r1", "step_a", null, "{\"x\":1}", "[\"step_a\"]", 1, null);

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"checkpoint_id":"cp1"}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs/r1/replay", body);
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "replayed_from_checkpoint") != null);
}

test "API: replay run rejects wrong checkpoint" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create two runs, checkpoint belongs to r2
    try store.createRunWithState("r1", null, "{}", "{}", "{}");
    try store.createRunWithState("r2", null, "{}", "{}", "{}");
    try store.createCheckpoint("cp_r2", "r2", "step_a", null, "{}", "[]", 1, null);

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"from_checkpoint_id":"cp_r2"}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs/r1/replay", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "does not belong") != null);
}

test "API: replay run rejects missing checkpoint" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createRunWithState("r1", null, "{}", "{}", "{}");

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const body =
        \\{"from_checkpoint_id":"nonexistent"}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs/r1/replay", body);
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "API: replay run rejects missing field" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createRunWithState("r1", null, "{}", "{}", "{}");

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const resp = handleRequest(&ctx, "POST", "/runs/r1/replay", "{}");
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: stream with mode query param" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createRunWithState("r1", null, "{}", "{}", "{\"x\":1}");
    try store.updateRunStatus("r1", "running", null);

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    // Default (no mode param) — should succeed
    const resp1 = handleRequest(&ctx, "GET", "/runs/r1/stream", "");
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp1.body, "stream_events") != null);

    // With specific modes
    const resp2 = handleRequest(&ctx, "GET", "/runs/r1/stream?mode=values,debug", "");
    try std.testing.expectEqual(@as(u16, 200), resp2.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp2.body, "stream_events") != null);
}

test "API: stream supports independent cursors for multiple consumers" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var hub = sse_mod.SseHub.init(allocator);
    defer hub.deinit();

    try store.createRunWithState("r1", null, "{}", "{}", "{\"x\":1}");
    try store.updateRunStatus("r1", "running", null);

    const queue = hub.getOrCreateQueue("r1");
    queue.push(.{ .event_type = "values", .data = "{\"step\":\"n1\"}", .mode = .values });

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
        .sse_hub = &hub,
    };

    const consumer_a = handleRequest(&ctx, "GET", "/runs/r1/stream", "");
    try std.testing.expectEqual(@as(u16, 200), consumer_a.status_code);
    try std.testing.expect(std.mem.indexOf(u8, consumer_a.body, "\"seq\":1") != null);

    const consumer_b = handleRequest(&ctx, "GET", "/runs/r1/stream", "");
    try std.testing.expectEqual(@as(u16, 200), consumer_b.status_code);
    try std.testing.expect(std.mem.indexOf(u8, consumer_b.body, "\"seq\":1") != null);

    queue.push(.{ .event_type = "updates", .data = "{\"step\":\"n2\"}", .mode = .updates });
    const consumer_a_next = handleRequest(&ctx, "GET", "/runs/r1/stream?after_seq=1", "");
    try std.testing.expectEqual(@as(u16, 200), consumer_a_next.status_code);
    try std.testing.expect(std.mem.indexOf(u8, consumer_a_next.body, "\"seq\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, consumer_a_next.body, "\"events\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, consumer_a_next.body, "\"next_stream_seq\":2") != null);
}

test "API: workflow routes decode percent-encoded ids" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    try store.createWorkflowWithVersion("wf/alpha beta", "Encoded Workflow", "{\"nodes\":{},\"edges\":[]}", 1);

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const get_resp = handleRequest(&ctx, "GET", "/workflows/wf%2Falpha%20beta", "");
    try std.testing.expectEqual(@as(u16, 200), get_resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.body, "\"id\":\"wf/alpha beta\"") != null);

    const validate_resp = handleRequest(&ctx, "POST", "/workflows/wf%2Falpha%20beta/validate", "");
    try std.testing.expectEqual(@as(u16, 200), validate_resp.status_code);
}
