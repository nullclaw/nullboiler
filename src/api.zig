const std = @import("std");
const Store = @import("store.zig").Store;

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

fn handleHealth(_: *Context) HttpResponse {
    return jsonResponse(200, "{\"status\":\"ok\",\"version\":\"0.1.0\"}");
}

fn handleCreateRun(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /runs not implemented\"}}");
}

fn handleListRuns(_: *Context) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /runs not implemented\"}}");
}

fn handleGetRun(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /runs/{id} not implemented\"}}");
}

fn handleCancelRun(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /runs/{id}/cancel not implemented\"}}");
}

fn handleRetryRun(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /runs/{id}/retry not implemented\"}}");
}

fn handleListSteps(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /runs/{id}/steps not implemented\"}}");
}

fn handleGetStep(_: *Context, _: []const u8, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /runs/{id}/steps/{step_id} not implemented\"}}");
}

fn handleApproveStep(_: *Context, _: []const u8, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /runs/{id}/steps/{step_id}/approve not implemented\"}}");
}

fn handleRejectStep(_: *Context, _: []const u8, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /runs/{id}/steps/{step_id}/reject not implemented\"}}");
}

fn handleListEvents(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /runs/{id}/events not implemented\"}}");
}

fn handleListWorkers(_: *Context) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"GET /workers not implemented\"}}");
}

fn handleRegisterWorker(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"POST /workers not implemented\"}}");
}

fn handleDeleteWorker(_: *Context, _: []const u8) HttpResponse {
    return jsonResponse(501, "{\"error\":{\"code\":\"not_implemented\",\"message\":\"DELETE /workers/{id} not implemented\"}}");
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
