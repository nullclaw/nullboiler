/// Webhook callback notifications module.
///
/// Fires HTTP POST requests to configured callback URLs when events occur
/// (step.completed, step.failed, run.completed, run.failed, etc.).
///
/// Callbacks are fire-and-forget: errors are logged but never propagated.
const std = @import("std");
const log = std.log.scoped(.callbacks);
const ids = @import("ids.zig");
const metrics_mod = @import("metrics.zig");

/// Fire webhook callbacks for a given event.
///
/// Parses callbacks_json (a JSON array of callback objects), filters by
/// event_kind, builds a payload, and POSTs to each matching callback URL.
///
/// Each callback object:
///   {"url": "...", "events": ["step.completed", ...], "headers": {"X-Key": "val"}}
///
/// If "events" is absent or empty, the callback fires for all events.
pub fn fireCallbacks(
    allocator: std.mem.Allocator,
    callbacks_json: []const u8,
    event_kind: []const u8,
    run_id: []const u8,
    step_id: ?[]const u8,
    data_json: []const u8,
    metrics: ?*metrics_mod.Metrics,
) void {
    // Parse callbacks_json as a JSON array of objects
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, callbacks_json, .{}) catch |err| {
        log.debug("callbacks: failed to parse callbacks_json: {}", .{err});
        return;
    };
    // Note: do not deinit — allocator is expected to be an arena

    const root = parsed.value;
    if (root != .array) {
        // Not an array (could be empty object or null) — nothing to fire
        return;
    }

    for (root.array.items) |cb_val| {
        if (cb_val != .object) continue;
        const cb_obj = cb_val.object;

        // Extract URL (required)
        const url = blk: {
            const url_val = cb_obj.get("url") orelse continue;
            if (url_val != .string) continue;
            break :blk url_val.string;
        };

        // Check event filter
        if (cb_obj.get("events")) |events_val| {
            if (events_val == .array and events_val.array.items.len > 0) {
                var matched = false;
                for (events_val.array.items) |ev| {
                    if (ev == .string and std.mem.eql(u8, ev.string, event_kind)) {
                        matched = true;
                        break;
                    }
                }
                if (!matched) continue;
            }
        }

        // Build payload JSON
        const now_ms = ids.nowMs();
        const step_field = if (step_id) |sid|
            std.fmt.allocPrint(allocator, ",\"step_id\":\"{s}\"", .{sid}) catch ""
        else
            "";

        const payload = std.fmt.allocPrint(allocator,
            \\{{"event":"{s}","run_id":"{s}"{s},"timestamp_ms":{d},"data":{s}}}
        , .{
            event_kind,
            run_id,
            step_field,
            now_ms,
            data_json,
        }) catch {
            log.warn("callbacks: failed to build payload for {s}", .{url});
            continue;
        };

        var headers: std.ArrayListUnmanaged(std.http.Header) = .empty;
        appendCustomHeaders(allocator, cb_obj, &headers);

        // Optional callback signing for receiver-side replay protection.
        const hmac_secret = getJsonString(cb_obj, "hmac_secret");
        if (hmac_secret) |secret| {
            const ts = std.fmt.allocPrint(allocator, "{d}", .{now_ms}) catch "";
            const nonce_buf = ids.generateId();
            const nonce = allocator.dupe(u8, &nonce_buf) catch "";
            const signature = buildSignatureHeader(allocator, secret, ts, nonce, payload) catch "";

            headers.append(allocator, .{ .name = "X-NullBoiler-Timestamp", .value = ts }) catch {};
            headers.append(allocator, .{ .name = "X-NullBoiler-Nonce", .value = nonce }) catch {};
            headers.append(allocator, .{ .name = "X-NullBoiler-Signature", .value = signature }) catch {};
        }

        // POST to callback URL
        const ok = postCallback(allocator, url, payload, headers.items);
        if (metrics) |m| {
            if (ok) {
                metrics_mod.Metrics.incr(&m.callback_sent_total);
            } else {
                metrics_mod.Metrics.incr(&m.callback_failed_total);
            }
        }
    }
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    if (val == .string) return val.string;
    return null;
}

/// Internal: extract custom headers from a callback object's "headers" field.
fn appendCustomHeaders(allocator: std.mem.Allocator, cb_obj: std.json.ObjectMap, list: *std.ArrayListUnmanaged(std.http.Header)) void {
    const headers_val = cb_obj.get("headers") orelse return;
    if (headers_val != .object) return;

    var it = headers_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            list.append(allocator, .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.string,
            }) catch continue;
        }
    }
}

/// Internal: POST payload to a URL with custom headers. Fire-and-forget.
fn postCallback(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, custom_headers: []const std.http.Header) bool {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = custom_headers,
        .headers = .{
            .content_type = .{ .override = "application/json" },
        },
    }) catch |err| {
        log.warn("callback POST to {s} failed: {}", .{ url, err });
        return false;
    };

    log.debug("callback fired to {s}", .{url});
    return true;
}

fn buildSignatureHeader(allocator: std.mem.Allocator, secret: []const u8, ts: []const u8, nonce: []const u8, payload: []const u8) ![]const u8 {
    const to_sign = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ ts, nonce, payload });

    var digest: [32]u8 = undefined;
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    HmacSha256.create(&digest, to_sign, secret);

    const hex = std.fmt.bytesToHex(digest, .lower);
    return try std.fmt.allocPrint(allocator, "v1={s}", .{&hex});
}
