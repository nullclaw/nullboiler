const std = @import("std");
const log = std.log.scoped(.redis_client);
const c = @cImport(@cInclude("hiredis.h"));
const async_dispatch = @import("async_dispatch.zig");
const worker_protocol = @import("worker_protocol.zig");

// ── RedisConn ────────────────────────────────────────────────────────

pub const RedisConn = struct {
    ctx: *c.redisContext,

    pub fn connect(host: [*:0]const u8, port: u16) !RedisConn {
        const ctx = c.redisConnect(host, @as(c_int, @intCast(port))) orelse return error.RedisConnectionFailed;
        if (ctx.err != 0) {
            c.redisFree(ctx);
            return error.RedisConnectionFailed;
        }
        return .{ .ctx = ctx };
    }

    pub fn disconnect(self: *RedisConn) void {
        c.redisFree(self.ctx);
    }

    pub fn xadd(self: *RedisConn, stream_key: [*:0]const u8, fields_json: [*:0]const u8) !void {
        const reply: ?*c.redisReply = @ptrCast(@alignCast(c.redisCommand(self.ctx, "XADD %s * payload %s", stream_key, fields_json)));
        if (reply) |r| {
            c.freeReplyObject(r);
        } else {
            return error.RedisCommandFailed;
        }
    }
};

// ── Listener ─────────────────────────────────────────────────────────

pub const ListenerConfig = struct {
    host: [*:0]const u8,
    port: u16,
    response_stream: [*:0]const u8,
    consumer_group: [*:0]const u8,
};

pub fn runListener(
    response_queue: *async_dispatch.ResponseQueue,
    shutdown: *std.atomic.Value(bool),
    configs: []const ListenerConfig,
) void {
    // Stub: the real implementation will connect to Redis and XREADGROUP
    // from the configured response streams, parsing JSON payloads and
    // inserting them into response_queue. For now, just loop checking
    // the shutdown flag.
    _ = response_queue;
    _ = configs;

    while (!shutdown.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    log.info("redis listener stopped", .{});
}

// ── Helpers ──────────────────────────────────────────────────────────

fn parseResponsePayload(
    allocator: std.mem.Allocator,
    payload: []const u8,
) ?async_dispatch.AsyncResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const obj = parsed.value.object;
    const correlation_id = if (obj.get("correlation_id")) |v| (if (v == .string) v.string else null) else null;
    if (correlation_id == null) return null;

    // Check for error response
    if (obj.get("error")) |err_val| {
        if (err_val == .string) {
            return .{
                .correlation_id = allocator.dupe(u8, correlation_id.?) catch return null,
                .output = "",
                .success = false,
                .error_text = allocator.dupe(u8, err_val.string) catch return null,
                .timestamp_ms = extractTimestamp(obj),
            };
        }
    }

    // Check for success response
    if (obj.get("response")) |resp_val| {
        if (resp_val == .string) {
            return .{
                .correlation_id = allocator.dupe(u8, correlation_id.?) catch return null,
                .output = allocator.dupe(u8, resp_val.string) catch return null,
                .success = true,
                .error_text = null,
                .timestamp_ms = extractTimestamp(obj),
            };
        }
    }

    return null;
}

fn extractTimestamp(obj: std.json.ObjectMap) i64 {
    if (obj.get("timestamp_ms")) |ts| {
        if (ts == .integer) return ts.integer;
    }
    return 0;
}

// ── Tests ────────────────────────────────────────────────────────────

test "parseResponsePayload: success response" {
    const alloc = std.testing.allocator;
    const payload = "{\"correlation_id\":\"run_1_step_2\",\"timestamp_ms\":1000,\"response\":\"hello world\"}";
    const result = parseResponsePayload(alloc, payload);
    try std.testing.expect(result != null);
    const r = result.?;
    defer alloc.free(r.correlation_id);
    defer alloc.free(r.output);
    try std.testing.expectEqualStrings("run_1_step_2", r.correlation_id);
    try std.testing.expectEqualStrings("hello world", r.output);
    try std.testing.expect(r.success);
    try std.testing.expect(r.error_text == null);
    try std.testing.expectEqual(@as(i64, 1000), r.timestamp_ms);
}

test "parseResponsePayload: error response" {
    const alloc = std.testing.allocator;
    const payload = "{\"correlation_id\":\"run_1_step_2\",\"error\":\"something broke\"}";
    const result = parseResponsePayload(alloc, payload);
    try std.testing.expect(result != null);
    const r = result.?;
    defer alloc.free(r.correlation_id);
    defer alloc.free(r.error_text.?);
    try std.testing.expectEqualStrings("run_1_step_2", r.correlation_id);
    try std.testing.expect(!r.success);
    try std.testing.expectEqualStrings("something broke", r.error_text.?);
}

test "parseResponsePayload: missing correlation_id returns null" {
    const alloc = std.testing.allocator;
    const payload = "{\"response\":\"hello\"}";
    try std.testing.expect(parseResponsePayload(alloc, payload) == null);
}

test "parseResponsePayload: invalid JSON returns null" {
    const alloc = std.testing.allocator;
    try std.testing.expect(parseResponsePayload(alloc, "not json") == null);
}
