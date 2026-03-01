/// Webhook callback notifications module.
///
/// Fires HTTP POST requests to configured callback URLs when events occur
/// (step.completed, step.failed, run.completed, run.failed, etc.).
///
/// Callbacks are fire-and-forget: errors are logged but never propagated.

const std = @import("std");
const log = std.log.scoped(.callbacks);
const ids = @import("ids.zig");

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

        // Extract custom headers
        const custom_headers = extractHeaders(allocator, cb_obj);

        // POST to callback URL
        postCallback(allocator, url, payload, custom_headers);
    }
}

/// Internal: extract custom headers from a callback object's "headers" field.
fn extractHeaders(allocator: std.mem.Allocator, cb_obj: std.json.ObjectMap) []std.http.Header {
    const headers_val = cb_obj.get("headers") orelse return &.{};
    if (headers_val != .object) return &.{};

    var list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    var it = headers_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .string) {
            list.append(allocator, .{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.string,
            }) catch continue;
        }
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

/// Internal: POST payload to a URL with custom headers. Fire-and-forget.
fn postCallback(allocator: std.mem.Allocator, url: []const u8, payload: []const u8, custom_headers: []const std.http.Header) void {
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
        return;
    };

    log.debug("callback fired to {s}", .{url});
}
