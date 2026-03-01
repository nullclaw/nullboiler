const std = @import("std");
const Store = @import("store.zig").Store;
const ids = @import("ids.zig");

// ── Types ────────────────────────────────────────────────────────────

pub const Context = struct {
    store: *Store,
    allocator: std.mem.Allocator,
};

pub const HttpResponse = struct {
    status: []const u8,
    body: []const u8,
    status_code: u16,
};

// ── Router ───────────────────────────────────────────────────────────

pub fn handleRequest(ctx: *Context, method: []const u8, target: []const u8, body: []const u8) HttpResponse {
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

    // GET /health
    if (is_get and eql(seg0, "health") and seg1 == null) {
        return handleHealth(ctx);
    }

    // POST /runs
    if (is_post and eql(seg0, "runs") and seg1 == null) {
        return handleCreateRun(ctx, body);
    }

    // GET /runs
    if (is_get and eql(seg0, "runs") and seg1 == null) {
        return handleListRuns(ctx);
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
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "approve")) {
        return handleApproveStep(ctx, seg1.?, seg3.?);
    }

    // POST /runs/{id}/steps/{step_id}/reject
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "reject")) {
        return handleRejectStep(ctx, seg1.?, seg3.?);
    }

    // POST /runs/{id}/steps/{step_id}/signal
    if (is_post and eql(seg0, "runs") and seg1 != null and eql(seg2, "steps") and seg3 != null and eql(seg4, "signal")) {
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

    return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"endpoint not found\"}}");
}

// ── Handlers ─────────────────────────────────────────────────────────

fn handleHealth(ctx: *Context) HttpResponse {
    // Count active runs
    const active_runs = ctx.store.getActiveRuns(ctx.allocator) catch {
        return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"0.1.0\",\"active_runs\":0,\"total_workers\":0}");
    };
    const active_count = active_runs.len;

    // Count total workers
    const workers = ctx.store.listWorkers(ctx.allocator) catch {
        const resp = std.fmt.allocPrint(ctx.allocator,
            \\{{"status":"ok","version":"0.1.0","active_runs":{d},"total_workers":0}}
        , .{active_count}) catch return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"0.1.0\"}");
        return jsonResponse(200, resp);
    };
    const worker_count = workers.len;

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"status":"ok","version":"0.1.0","active_runs":{d},"total_workers":{d}}}
    , .{ active_count, worker_count }) catch return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"0.1.0\"}");
    return jsonResponse(200, resp);
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
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":"{s}","url":"{s}","tags":{s},"max_concurrent":{d},"source":"{s}","status":"{s}","created_at_ms":{d}}}
        , .{
            w.id,
            w.url,
            w.tags_json,
            w.max_concurrent,
            w.source,
            w.status,
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

    // Extract tags as JSON string
    const tags_json = if (obj.get("tags")) |tags_val| blk: {
        var out: std.io.Writer.Allocating = .init(ctx.allocator);
        var jw: std.json.Stringify = .{ .writer = &out.writer };
        jw.write(tags_val) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize tags\"}}");
        break :blk out.toOwnedSlice() catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    } else "[]";

    // Extract max_concurrent
    const max_concurrent: i64 = if (obj.get("max_concurrent")) |mc| blk: {
        if (mc == .integer) break :blk mc.integer;
        break :blk 1;
    } else 1;

    ctx.store.insertWorker(worker_id, url, token, tags_json, max_concurrent, "registered") catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert worker\"}}");
    };

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":"{s}","status":"active"}}
    , .{worker_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
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

    // Serialize input and callbacks back to JSON for storage
    const input_json = serializeJsonValue(ctx.allocator, obj.get("input")) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize input\"}}");
    };
    const callbacks_json = serializeJsonValue(ctx.allocator, obj.get("callbacks")) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to serialize callbacks\"}}");
    };

    // Generate run_id
    const run_id_buf = ids.generateId();
    const run_id = ctx.allocator.dupe(u8, &run_id_buf) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    // Insert run — workflow_json = the original body (frozen snapshot)
    ctx.store.insertRun(run_id, "running", body, input_json, callbacks_json) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert run\"}}");
    };

    // Build mapping from def_step_id -> generated step_id
    // Use parallel arrays for simplicity
    var def_ids: std.ArrayListUnmanaged([]const u8) = .empty;
    var gen_ids: std.ArrayListUnmanaged([]const u8) = .empty;

    // First pass: create all steps
    for (steps_array) |step_val| {
        if (step_val != .object) continue;
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse continue;
        const step_type = getJsonString(step_obj, "type") orelse "task";

        // Validate required fields for advanced step types
        if (eql(step_type, "loop") and step_obj.get("body") == null) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"loop step requires 'body' field\"}}");
        }
        if (eql(step_type, "sub_workflow") and step_obj.get("workflow") == null) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"sub_workflow step requires 'workflow' field\"}}");
        }
        if (eql(step_type, "wait")) {
            if (step_obj.get("duration_ms") == null and step_obj.get("until_ms") == null and step_obj.get("signal") == null) {
                return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"wait step requires 'duration_ms', 'until_ms', or 'signal'\"}}");
            }
        }
        if (eql(step_type, "router") and step_obj.get("routes") == null) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"router step requires 'routes' field\"}}");
        }
        if (eql(step_type, "saga") and step_obj.get("body") == null) {
            return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"saga step requires 'body' field\"}}");
        }
        if (eql(step_type, "debate")) {
            if (step_obj.get("count") == null) {
                return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"debate step requires 'count' field\"}}");
            }
        }
        if (eql(step_type, "group_chat")) {
            if (step_obj.get("participants") == null) {
                return jsonResponse(400, "{\"error\":{\"code\":\"bad_request\",\"message\":\"group_chat step requires 'participants' field\"}}");
            }
        }

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
        if (step_val != .object) continue;
        const step_obj = step_val.object;

        const def_step_id = getJsonString(step_obj, "id") orelse continue;

        // Find the generated step_id for this def_step_id
        const step_id = lookupGenId(def_ids.items, gen_ids.items, def_step_id) orelse continue;

        // Process depends_on
        const deps_val = step_obj.get("depends_on") orelse continue;
        if (deps_val != .array) continue;

        for (deps_val.array.items) |dep_item| {
            if (dep_item != .string) continue;
            const dep_def_id = dep_item.string;

            // Find the generated step_id for this dependency
            const dep_step_id = lookupGenId(def_ids.items, gen_ids.items, dep_def_id) orelse continue;

            ctx.store.insertStepDep(step_id, dep_step_id) catch {
                return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to insert step dependency\"}}");
            };
        }
    }

    // Return 201 with run info
    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":"{s}","status":"running"}}
    , .{run_id}) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
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

    const error_field = if (run.error_text) |et|
        std.fmt.allocPrint(ctx.allocator, ",\"error_text\":\"{s}\"", .{et}) catch ""
    else
        "";

    const started_field = if (run.started_at_ms) |s|
        std.fmt.allocPrint(ctx.allocator, ",\"started_at_ms\":{d}", .{s}) catch ""
    else
        "";

    const ended_field = if (run.ended_at_ms) |e|
        std.fmt.allocPrint(ctx.allocator, ",\"ended_at_ms\":{d}", .{e}) catch ""
    else
        "";

    const resp = std.fmt.allocPrint(ctx.allocator,
        \\{{"id":"{s}","status":"{s}","created_at_ms":{d},"updated_at_ms":{d}{s}{s}{s},"steps":{s}}}
    , .{
        run.id,
        run.status,
        run.created_at_ms,
        run.updated_at_ms,
        error_field,
        started_field,
        ended_field,
        steps_json,
    }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, resp);
}

fn handleListRuns(ctx: *Context) HttpResponse {
    // For MVP: return all runs, no filtering
    const runs = ctx.store.listRuns(ctx.allocator, null, 100) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to list runs\"}}");
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    buf.append(ctx.allocator, '[') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");

    for (runs, 0..) |r, i| {
        if (i > 0) {
            buf.append(ctx.allocator, ',') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        }
        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":"{s}","status":"{s}","created_at_ms":{d},"updated_at_ms":{d}}}
        , .{
            r.id,
            r.status,
            r.created_at_ms,
            r.updated_at_ms,
        }) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
        buf.appendSlice(ctx.allocator, entry) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    }

    buf.append(ctx.allocator, ']') catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    const json_body = buf.toOwnedSlice(ctx.allocator) catch return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"out of memory\"}}");
    return jsonResponse(200, json_body);
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

fn handleGetStep(ctx: *Context, _: []const u8, step_id: []const u8) HttpResponse {
    const step = ctx.store.getStep(ctx.allocator, step_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get step\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}");
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
    const step = ctx.store.getStep(ctx.allocator, step_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get step\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}");
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
    const step = ctx.store.getStep(ctx.allocator, step_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get step\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}");
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
    const step = ctx.store.getStep(ctx.allocator, step_id) catch {
        return jsonResponse(500, "{\"error\":{\"code\":\"internal\",\"message\":\"failed to get step\"}}");
    } orelse {
        return jsonResponse(404, "{\"error\":{\"code\":\"not_found\",\"message\":\"step not found\"}}");
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

        const step_field = if (ev.step_id) |sid|
            std.fmt.allocPrint(ctx.allocator, ",\"step_id\":\"{s}\"", .{sid}) catch ""
        else
            "";

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{d},"run_id":"{s}"{s},"kind":"{s}","data":{s},"ts_ms":{d}}}
        , .{
            ev.id,
            ev.run_id,
            step_field,
            ev.kind,
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

fn handleGetChatTranscript(ctx: *Context, _: []const u8, step_id: []const u8) HttpResponse {
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

        const worker_field = if (msg.worker_id) |wid|
            std.fmt.allocPrint(ctx.allocator, ",\"worker_id\":\"{s}\"", .{wid}) catch ""
        else
            "";

        const entry = std.fmt.allocPrint(ctx.allocator,
            \\{{"id":{d},"run_id":"{s}","step_id":"{s}","round":{d},"role":"{s}"{s},"message":"{s}","ts_ms":{d}}}
        , .{
            msg.id,
            msg.run_id,
            msg.step_id,
            msg.round,
            msg.role,
            worker_field,
            msg.message,
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
    const worker_field = if (s.worker_id) |wid|
        try std.fmt.allocPrint(allocator, ",\"worker_id\":\"{s}\"", .{wid})
    else
        "";

    const output_field = if (s.output_json) |oj|
        try std.fmt.allocPrint(allocator, ",\"output_json\":{s}", .{oj})
    else
        "";

    const error_field = if (s.error_text) |et|
        try std.fmt.allocPrint(allocator, ",\"error_text\":\"{s}\"", .{et})
    else
        "";

    const timeout_field = if (s.timeout_ms) |t|
        try std.fmt.allocPrint(allocator, ",\"timeout_ms\":{d}", .{t})
    else
        "";

    const parent_field = if (s.parent_step_id) |pid|
        try std.fmt.allocPrint(allocator, ",\"parent_step_id\":\"{s}\"", .{pid})
    else
        "";

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

    const child_run_field = if (s.child_run_id) |crid|
        try std.fmt.allocPrint(allocator, ",\"child_run_id\":\"{s}\"", .{crid})
    else
        "";

    return try std.fmt.allocPrint(allocator,
        \\{{"id":"{s}","run_id":"{s}","def_step_id":"{s}","type":"{s}","status":"{s}","attempt":{d},"max_attempts":{d},"iteration_index":{d},"created_at_ms":{d},"updated_at_ms":{d}{s}{s}{s}{s}{s}{s}{s}{s}{s}}}
    , .{
        s.id,
        s.run_id,
        s.def_step_id,
        s.type,
        s.status,
        s.attempt,
        s.max_attempts,
        s.iteration_index,
        s.created_at_ms,
        s.updated_at_ms,
        worker_field,
        output_field,
        error_field,
        timeout_field,
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

fn getPathSegment(segments: [max_segments]?[]const u8, index: usize) ?[]const u8 {
    if (index >= max_segments) return null;
    return segments[index];
}

fn eql(a: ?[]const u8, b: []const u8) bool {
    if (a) |val| return std.mem.eql(u8, val, b);
    return false;
}

fn jsonResponse(status_code: u16, body: []const u8) HttpResponse {
    const status = switch (status_code) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        500 => "500 Internal Server Error",
        501 => "501 Not Implemented",
        else => "500 Internal Server Error",
    };
    return HttpResponse{
        .status = status,
        .body = body,
        .status_code = status_code,
    };
}
