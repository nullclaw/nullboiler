const std = @import("std");
const log = std.log.scoped(.mqtt_client);
const c = @cImport(@cInclude("mosquitto.h"));
const async_dispatch = @import("async_dispatch.zig");
const worker_protocol = @import("worker_protocol.zig");

// ── MqttConn ─────────────────────────────────────────────────────────

pub const MqttConn = struct {
    mosq: *c.struct_mosquitto,

    pub fn connect(host: [*:0]const u8, port: u16) !MqttConn {
        _ = c.mosquitto_lib_init();
        const mosq = c.mosquitto_new(null, true, null) orelse return error.MqttCreateFailed;
        const rc = c.mosquitto_connect(mosq, host, @intCast(port), 60);
        if (rc != c.MOSQ_ERR_SUCCESS) {
            c.mosquitto_destroy(mosq);
            return error.MqttConnectionFailed;
        }
        return .{ .mosq = mosq };
    }

    pub fn disconnect(self: *MqttConn) void {
        _ = c.mosquitto_disconnect(self.mosq);
        c.mosquitto_destroy(self.mosq);
    }

    pub fn publish(self: *MqttConn, topic: [*:0]const u8, payload: []const u8) !void {
        const rc = c.mosquitto_publish(
            self.mosq,
            null,
            topic,
            @intCast(payload.len),
            payload.ptr,
            1, // QoS 1
            false,
        );
        if (rc != c.MOSQ_ERR_SUCCESS) return error.MqttPublishFailed;
    }

    pub fn subscribe(self: *MqttConn, topic: [*:0]const u8) !void {
        const rc = c.mosquitto_subscribe(self.mosq, null, topic, 1);
        if (rc != c.MOSQ_ERR_SUCCESS) return error.MqttSubscribeFailed;
    }
};

// ── Listener ─────────────────────────────────────────────────────────

pub const ListenerConfig = struct {
    host: [*:0]const u8,
    port: u16,
    response_topic: [*:0]const u8,
};

pub fn runListener(
    response_queue: *async_dispatch.ResponseQueue,
    shutdown: *std.atomic.Value(bool),
    configs: []const ListenerConfig,
) void {
    // Stub: the real implementation will connect to the MQTT broker,
    // subscribe to the configured response topics, set a message callback
    // that parses JSON payloads and inserts them into response_queue,
    // and run the mosquitto loop. For now, just loop checking the
    // shutdown flag.
    _ = response_queue;
    _ = configs;

    while (!shutdown.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
    log.info("mqtt listener stopped", .{});
}

// ── Helpers ──────────────────────────────────────────────────────────

pub fn parseResponsePayload(
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
    const payload = "{\"correlation_id\":\"run_1_step_2\",\"timestamp_ms\":1000,\"response\":\"mqtt result\"}";
    const result = parseResponsePayload(alloc, payload);
    try std.testing.expect(result != null);
    const r = result.?;
    defer alloc.free(r.correlation_id);
    defer alloc.free(r.output);
    try std.testing.expectEqualStrings("run_1_step_2", r.correlation_id);
    try std.testing.expectEqualStrings("mqtt result", r.output);
    try std.testing.expect(r.success);
    try std.testing.expect(r.error_text == null);
    try std.testing.expectEqual(@as(i64, 1000), r.timestamp_ms);
}

test "parseResponsePayload: error response" {
    const alloc = std.testing.allocator;
    const payload = "{\"correlation_id\":\"run_1_step_2\",\"error\":\"mqtt error\"}";
    const result = parseResponsePayload(alloc, payload);
    try std.testing.expect(result != null);
    const r = result.?;
    defer alloc.free(r.correlation_id);
    defer alloc.free(r.error_text.?);
    try std.testing.expectEqualStrings("run_1_step_2", r.correlation_id);
    try std.testing.expect(!r.success);
    try std.testing.expectEqualStrings("mqtt error", r.error_text.?);
}

test "parseResponsePayload: missing correlation_id returns null" {
    const alloc = std.testing.allocator;
    try std.testing.expect(parseResponsePayload(alloc, "{\"response\":\"hi\"}") == null);
}

test "parseResponsePayload: invalid JSON returns null" {
    const alloc = std.testing.allocator;
    try std.testing.expect(parseResponsePayload(alloc, "bad") == null);
}
