const std = @import("std");
const Store = @import("store.zig").Store;

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

    std.debug.print("port: {d}\n", .{port});
    std.debug.print("database ready\n", .{});
}

comptime {
    _ = @import("ids.zig");
    _ = @import("types.zig");
    _ = @import("store.zig");
}
