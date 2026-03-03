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

    const config_json = try std.json.Stringify.valueAlloc(allocator, .{
        .port = parsed.value.port,
        .db = parsed.value.db_path,
        .api_token = parsed.value.api_token,
    }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer allocator.free(config_json);

    // Write config.json
    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(config_json);
    try file.writeAll("\n");

    // Output success to stdout
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
