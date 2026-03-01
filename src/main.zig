const std = @import("std");
const Store = @import("store.zig").Store;
const api = @import("api.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var port: u16 = 8080;
    var db_path: [:0]const u8 = "nullboiler.db";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (std.mem.eql(u8, arg, "--db")) {
            if (args.next()) |val| {
                db_path = val;
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullboiler v{s}\n", .{version});
            return;
        }
    }

    std.debug.print("nullboiler v{s}\n", .{version});
    std.debug.print("opening database: {s}\n", .{db_path});

    var store = try Store.init(allocator, db_path);
    defer store.deinit();

    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch |err| {
        std.debug.print("failed to resolve address: {}\n", .{err});
        return;
    };
    var server = addr.listen(.{ .reuse_address = true }) catch |err| {
        std.debug.print("failed to listen on port {d}: {}\n", .{ port, err });
        return;
    };
    defer server.deinit();

    std.debug.print("listening on http://127.0.0.1:{d}\n", .{port});

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

comptime {
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("store.zig");
    _ = @import("api.zig");
}
