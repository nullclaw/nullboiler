const std = @import("std");
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");
const types = @import("types.zig");
const workflow_validation = @import("workflow_validation.zig");
const worker_protocol = @import("worker_protocol.zig");
const metrics_mod = @import("metrics.zig");

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
    const seg0 = getPathSegment(path, 0);
    const seg1 = getPathSegment(path, 1);
    const seg2 = getPathSegment(path, 2);
    const seg3 = getPathSegment(path, 3);
    const seg4 = getPathSegment(path, 4);
    const seg5 = getPathSegment(path, 5);

    const is_get = eql(method, "GET");
    const is_post = eql(method, "POST");
    const is_delete = eql(method, "DELETE");

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

    // POST /runs/{id}/steps/{step_id}/approve
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "approve") and seg5 == null) {
        return handleApproveStep(ctx, seg1.?, seg3.?);
    }

    // POST /runs/{id}/steps/{step_id}/reject
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "reject") and seg5 == null) {
        return handleRejectStep(ctx, seg1.?, seg3.?);
    }

    // POST /runs/{id}/steps/{step_id}/signal
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "signal") and seg5 == null) {
        return handleSignalStep(ctx, seg1.?, seg3.?, body);
    }

    // GET /runs/{id}/steps/{step_id}/chat
    if (is_get and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "chat") and seg5 == null) {
        return handleGetChatTranscript(ctx, seg1.?, seg3.?);
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
        return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"invalid protocol (expected webhook|api_chat|openai_chat)\"}}");
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
    const steps_array = steps_val.array.items;

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

    const run_id_json = jsonQuoted(ctx.allocator, run.id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const run_status_json = jsonQuoted(ctx.allocator, run.status) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":{s},"status":{s}{s},"created_at_ms":{d},"updated_at_ms":{d}{s}{s}{s},"steps":{s}}}
    , .{
        run_id_json,
        run_status_json,
        idempotency_field,
        run.created_at_ms,
        run.updated_at_ms,
        error_field,
        started_field,
        ended_field,
        steps_json,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleListRuns(ctx: *Context, target: []const u8) HttpResponse {
    const status_filter = getQueryParam(target, "status");
    const limit = parseQueryInt(target, "limit", 100, 1, 1000);
    const offset = parseQueryInt(target, "offset", 0, 0, 1_000_000_000);

    // Fetch one extra row to compute has_more.
    const runs = ctx.store.listRuns(ctx.allocator, status_filter, limit + 1, offset) catch {
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
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{s},"status":{s}{s},"created_at_ms":{d},"updated_at_ms":{d}}}
        , .{
            run_id_json,
            run_status_json,
            idempotency_field,
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

    // 6. Return 200
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

fn handleApproveStep(ctx: *Context, run_id: []const u8, step_id: []const u8) HttpResponse {
    // 1. Get step from store
    const step = switch (lookupStepInRun(ctx, run_id, step_id)) {
        .ok => |s| s,
        .err => |resp| return resp,
    };

    // 2. Must be "waiting_approval"
    if (!std.mem.eql(u8, step.status, "waiting_approval")) {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"step is not waiting_approval (current: {s})"}}}}
        , .{step.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"step is not waiting_approval\"}}");
        return jsonResponse(409, resp);
    }

    // 3. Update status to "completed"
    ctx.store.updateStepStatus(step_id, "completed", null, null, null, step.attempt) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update step\"}}");
    };

    // 4. Insert event
    ctx.store.insertEvent(run_id, step_id, "step.approved", "{}") catch {};

    // 5. Return 200
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"step_id":"{s}","status":"completed"}}
    , .{step_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleRejectStep(ctx: *Context, run_id: []const u8, step_id: []const u8) HttpResponse {
    // 1. Get step from store
    const step = switch (lookupStepInRun(ctx, run_id, step_id)) {
        .ok => |s| s,
        .err => |resp| return resp,
    };

    // 2. Must be "waiting_approval"
    if (!std.mem.eql(u8, step.status, "waiting_approval")) {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"step is not waiting_approval (current: {s})"}}}}
        , .{step.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"step is not waiting_approval\"}}");
        return jsonResponse(409, resp);
    }

    // 3. Update status to "failed", set error_text
    ctx.store.updateStepStatus(step_id, "failed", null, null, "rejected by user", step.attempt) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update step\"}}");
    };

    // 4. Insert event
    ctx.store.insertEvent(run_id, step_id, "step.rejected", "{}") catch {};

    // 5. Return 200
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"step_id":"{s}","status":"failed"}}
    , .{step_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleSignalStep(ctx: *Context, run_id: []const u8, step_id: []const u8, body: []const u8) HttpResponse {
    // 1. Get step from store
    const step = switch (lookupStepInRun(ctx, run_id, step_id)) {
        .ok => |s| s,
        .err => |resp| return resp,
    };

    // 2. Must be "waiting_approval" (signal mode uses this status)
    if (!std.mem.eql(u8, step.status, "waiting_approval")) {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"error":{{"code":"conflict","message":"step is not waiting for signal (current: {s})"}}}}
        , .{step.status}) catch return jsonResponse(409, "{\"error\":{\"code\":\"conflict\",\"message\":\"step is not waiting for signal\"}}");
        return jsonResponse(409, resp);
    }

    // 3. Parse optional signal data from body
    var signal_data: []const u8 = "{}";
    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
            // Body is not valid JSON; use empty
            signal_data = "{}";
            // Continue anyway
            const output = std.fmt.allocPrint(ctx.allocator,
                \\{{"output":"signaled","data":{{}}}}
            , .{}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

            ctx.store.updateStepStatus(step_id, "completed", null, output, null, step.attempt) catch {
                return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update step\"}}");
            };
            ctx.store.insertEvent(run_id, step_id, "step.signaled", output) catch {};
            const resp = std.fmt.allocPrint(ctx.allocator,
                \\{{"step_id":"{s}","status":"completed"}}
            , .{step_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
            return jsonResponse(200, resp);
        };
        _ = parsed;
        signal_data = body;
    }

    // 4. Build output with signal data
    const output = std.fmt.allocPrint(ctx.allocator,
        \\{{"output":"signaled","data":{s}}}
    , .{signal_data}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // 5. Update step to "completed"
    ctx.store.updateStepStatus(step_id, "completed", null, output, null, step.attempt) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to update step\"}}");
    };

    // 6. Insert event
    ctx.store.insertEvent(run_id, step_id, "step.signaled", output) catch {};

    // 7. Return 200
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"step_id":"{s}","status":"completed"}}
    , .{step_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
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

// ── Chat Transcript Handler ──────────────────────────────────────────

fn handleGetChatTranscript(ctx: *Context, run_id: []const u8, step_id: []const u8) HttpResponse {
    _ = switch (lookupStepInRun(ctx, run_id, step_id)) {
        .ok => |s| s,
        .err => |resp| return resp,
    };

    const messages = ctx.store.getChatMessages(ctx.allocator, step_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get chat messages\"}}");
    };

    // Build JSON array of chat messages
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (messages, 0..) |msg, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }

        const worker_field = if (msg.worker_id) |wid| blk: {
            const wid_json = jsonQuoted(ctx.allocator, wid) catch "";
            break :blk std.fmt.allocPrint(ctx.allocator, ",\"worker_id\":{s}", .{wid_json}) catch "";
        } else "";
        const msg_run_id_json = jsonQuoted(ctx.allocator, msg.run_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const msg_step_id_json = jsonQuoted(ctx.allocator, msg.step_id) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const role_json = jsonQuoted(ctx.allocator, msg.role) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        const message_json = jsonQuoted(ctx.allocator, msg.message) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{d},"run_id":{s},"step_id":{s},"round":{d},"role":{s}{s},"message":{s},"ts_ms":{d}}}
        , .{
            msg.id,
            msg_run_id_json,
            msg_step_id_json,
            msg.round,
            role_json,
            worker_field,
            message_json,
            msg.ts_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
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
        error.LoopBodyRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"loop step requires 'body' field\"}}"),
        error.SubWorkflowRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"sub_workflow step requires 'workflow' field\"}}"),
        error.WaitConditionRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"wait step requires 'duration_ms', 'until_ms', or 'signal'\"}}"),
        error.WaitDurationInvalid => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"wait.duration_ms must be a non-negative integer\"}}"),
        error.WaitUntilInvalid => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"wait.until_ms must be a non-negative integer\"}}"),
        error.WaitSignalInvalid => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"wait.signal must be a non-empty string\"}}"),
        error.RouterRoutesRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"router step requires 'routes' field\"}}"),
        error.SagaBodyRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"saga step requires 'body' field\"}}"),
        error.DebateCountRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"debate step requires 'count' field\"}}"),
        error.GroupChatParticipantsRequired => jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"group_chat step requires 'participants' field\"}}"),
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

test "API: create run rejects invalid wait duration string" {
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
        \\{"steps":[{"id":"w1","type":"wait","duration_ms":"abc"}]}
    ;

    const resp = handleRequest(&ctx, "POST", "/runs", body);
    try std.testing.expectEqual(@as(u16, 400), resp.status_code);
}

test "API: create run rejects invalid wait signal type" {
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
        \\{"steps":[{"id":"w1","type":"wait","signal":1}]}
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

test "API: chat transcript escapes message content" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("run-chat", null, "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertStep("step-chat-1", "run-chat", "chat", "group_chat", "completed", "{}", 1, null, null, null);
    try store.insertChatMessage("run-chat", "step-chat-1", 1, "agent", null, "He said \"go\"\\nline");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const resp = handleRequest(&ctx, "GET", "/runs/run-chat/steps/step-chat-1/chat", "");
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const msg = parsed.value.array.items[0].object.get("message").?;
    try std.testing.expectEqualStrings("He said \"go\"\\nline", msg.string);
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

test "API: approve route does not match extra path segment" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, ":memory:");
    defer store.deinit();

    try store.insertRun("r1", null, "running", "{\"steps\":[]}", "{}", "[]");
    try store.insertStep("s1", "r1", "approve-1", "approval", "waiting_approval", "{}", 1, null, null, null);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = Context{
        .store = &store,
        .allocator = arena.allocator(),
    };

    const resp = handleRequest(&ctx, "POST", "/runs/r1/steps/s1/approve/extra", "");
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "endpoint not found") != null);

    const step = (try store.getStep(arena.allocator(), "s1")).?;
    try std.testing.expectEqualStrings("waiting_approval", step.status);
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
