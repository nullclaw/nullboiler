const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(
        struct {
            port: u16 = 8080,
            api_token: ?[]const u8 = null,
            db_path: []const u8 = "nullboiler.db",
        },
        allocator,
        args[0],
        .{ .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    // Build config JSON
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"port\": {d},\n", .{parsed.value.port});
    try w.print("  \"db\": \"{s}\"", .{parsed.value.db_path});
    if (parsed.value.api_token) |token| {
        try w.writeAll(",\n");
        try w.print("  \"api_token\": \"{s}\"", .{token});
    }
    try w.writeAll("\n}\n");

    // Write config.json
    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(buf.items);

    // Output success to stdout
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
