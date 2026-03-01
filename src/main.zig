const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");

const version = "0.1.0";
const max_request_size: usize = 8 * 1024 * 1024;
const request_read_chunk: usize = 4096;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var port_override: ?u16 = null;
    var db_override: ?[:0]const u8 = null;
    var config_path: []const u8 = "config.json";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                port_override = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                db_override = val;
            }
        } else if (std.mem.eql(u8, arg, "--config")) {
            if (args.next()) |val| {
                config_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullboiler v{s}\n", .{version});
            return;
        }
    }

    // Load configuration
    var cfg_arena = std.heap.ArenaAllocator.init(allocator);
    defer cfg_arena.deinit();
    const cfg = config.loadFromFile(cfg_arena.allocator(), config_path) catch |err| {
        std.debug.print("failed to load config from {s}: {}\n", .{ config_path, err });
        return;
    };

    // Determine port and db path (CLI overrides config)
    const port = port_override orelse cfg.port;
    const db_path: [:0]const u8 = db_override orelse blk: {
        // Need to convert cfg.db ([]const u8) to [:0]const u8
        const db_z = cfg_arena.allocator().allocSentinel(u8, cfg.db.len, 0) catch {
            std.debug.print("out of memory\n", .{});
            return;
        };
        @memcpy(db_z, cfg.db);
        break :blk db_z;
    };

    std.debug.print("nullboiler v{s}\n", .{version});
    std.debug.print("opening database: {s}\n", .{db_path});

    var store = try Store.init(allocator, db_path);
    defer store.deinit();

    // Seed workers from config
    store.deleteWorkersBySource("config") catch |err| {
        std.debug.print("warning: failed to clean config workers: {}\n", .{err});
    };

    for (cfg.workers) |w| {
        const protocol_supported =
            std.mem.eql(u8, w.protocol, "webhook") or
            std.mem.eql(u8, w.protocol, "api_chat") or
            std.mem.eql(u8, w.protocol, "openai_chat");
        if (!protocol_supported) {
            std.debug.print("warning: skipped config worker {s}: unsupported protocol {s}\n", .{ w.id, w.protocol });
            continue;
        }

        if (std.mem.eql(u8, w.protocol, "openai_chat") and w.model == null) {
            std.debug.print("warning: skipped config worker {s}: openai_chat protocol requires model\n", .{w.id});
            continue;
        }

        // Serialize tags to JSON array string
        const tags_json = serializeTagsJson(cfg_arena.allocator(), w.tags) catch |err| {
            std.debug.print("warning: failed to serialize tags for worker {s}: {}\n", .{ w.id, err });
            continue;
        };

        store.insertWorker(w.id, w.url, w.token, w.protocol, w.model, tags_json, @intCast(w.max_concurrent), "config") catch |err| {
            std.debug.print("warning: failed to insert config worker {s}: {}\n", .{ w.id, err });
        };
        std.debug.print("registered config worker: {s}\n", .{w.id});
    }

    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch |err| {
        std.debug.print("failed to resolve address: {}\n", .{err});
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("failed to listen on port {d}: {}\n", .{ port, err });
        return;
    };
    defer server.deinit();

    // Start DAG engine on a background thread
    const poll_ms: u64 = cfg.engine.poll_interval_ms;
    var engine = engine_mod.Engine.init(&store, allocator, poll_ms);
    const engine_thread = try std.Thread.spawn(.{}, engine_mod.Engine.run, .{&engine});

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});
    std.debug.print("engine started (poll_interval={d}ms)\n", .{poll_ms});

    defer {
        engine.stop();
        engine_thread.join();
        std.debug.print("engine stopped\n", .{});
    }

    while (true) {
        var conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        const request = readHttpRequest(req_alloc, &conn.stream, max_request_size) catch |err| {
            std.debug.print("request read error: {}\n", .{err});
            continue;
        } orelse continue;

        var ctx = api.Context{ .store = &store, .allocator = req_alloc };
        const response = api.handleRequest(&ctx, request.method, request.target, request.body);

        const header = std.fmt.allocPrint(req_alloc, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ response.status, response.body.len }) catch continue;

        conn.stream.writeAll(header) catch continue;
        conn.stream.writeAll(response.body) catch continue;
    }
}

fn serializeTagsJson(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, tags, .{});
}

const ParsedHttpRequest = struct {
    method: []const u8,
    target: []const u8,
    body: []const u8,
};

fn readHttpRequest(allocator: std.mem.Allocator, stream: *std.net.Stream, max_bytes: usize) !?ParsedHttpRequest {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(allocator);

    var header_end: ?usize = null;
    var content_len: usize = 0;
    var chunk: [request_read_chunk]u8 = undefined;

    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) return null;

        try buffer.appendSlice(allocator, chunk[0..n]);
        if (buffer.items.len > max_bytes) return error.RequestTooLarge;

        if (header_end == null) {
            const hdr_end = std.mem.indexOf(u8, buffer.items, "\r\n\r\n") orelse continue;
            header_end = hdr_end;
            content_len = parseContentLength(buffer.items[0..hdr_end]) orelse return error.InvalidContentLength;

            const required = hdr_end + 4 + content_len;
            if (required > max_bytes) return error.RequestTooLarge;
            if (buffer.items.len >= required) break;
            continue;
        }

        const required = header_end.? + 4 + content_len;
        if (buffer.items.len >= required) break;
    }

    const req_total = header_end.? + 4 + content_len;
    const req_bytes = try allocator.dupe(u8, buffer.items[0..req_total]);

    const first_line_end = std.mem.indexOf(u8, req_bytes, "\r\n") orelse return error.InvalidRequestLine;
    const first_line = req_bytes[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');

    const method = parts.next() orelse return error.InvalidRequestLine;
    const target = parts.next() orelse return error.InvalidRequestLine;
    const body = req_bytes[header_end.? + 4 .. req_total];

    return .{
        .method = method,
        .target = target,
        .body = body,
    };
}

fn parseContentLength(headers_raw: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, headers_raw, "\r\n");
    _ = lines.next(); // request line

    while (lines.next()) |line| {
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "Content-Length")) continue;

        const raw_value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return std.fmt.parseInt(usize, raw_value, 10) catch null;
    }

    return 0;
}

test "serializeTagsJson escapes special chars" {
    const allocator = std.testing.allocator;
    const tags = [_][]const u8{
        "dev\"ops",
        "path\\with\\slashes",
        "line\nbreak",
    };

    const got = try serializeTagsJson(allocator, &tags);
    defer allocator.free(got);

    try std.testing.expectEqualStrings("[\"dev\\\"ops\",\"path\\\\with\\\\slashes\",\"line\\nbreak\"]", got);
}

comptime {
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
    _ = @import("templates.zig");
    _ = @import("dispatch.zig");
    _ = @import("config.zig");
    _ = @import("engine.zig");
    _ = @import("callbacks.zig");
    _ = @import("workflow_validation.zig");
}
