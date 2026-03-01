const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");

const version = "0.1.0";

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
        // Serialize tags to JSON array string
        const tags_json = serializeTagsJson(cfg_arena.allocator(), w.tags) catch |err| {
            std.debug.print("warning: failed to serialize tags for worker {s}: {}\n", .{ w.id, err });
            continue;
        };

        store.insertWorker(w.id, w.url, w.token, tags_json, @intCast(w.max_concurrent), "config") catch |err| {
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
        const conn = server.accept() catch |err| {
            std.debug.print("accept error: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_alloc = arena.allocator();

        var req_buf: [1024 * 1024]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch continue;
        if (n == 0) continue;
        const raw = req_buf[0..n];

        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method_str = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        const body = if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |bi|
            raw[bi + 4 ..]
        else
            "";

        var ctx = api.Context{ .store = &store, .allocator = req_alloc };
        const response = api.handleRequest(&ctx, method_str, target, body);

        const header = std.fmt.allocPrint(req_alloc, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ response.status, response.body.len }) catch continue;

        conn.stream.writeAll(header) catch continue;
        conn.stream.writeAll(response.body) catch continue;
    }
}

fn serializeTagsJson(allocator: std.mem.Allocator, tags: []const []const u8) ![]const u8 {
    if (tags.len == 0) return "[]";

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.append(allocator, '[');
    for (tags, 0..) |tag, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, tag);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
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
}
