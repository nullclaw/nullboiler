const std = @import("std");

const version = "0.1.0";

pub fn main() !void {
    std.debug.print("nullboiler v{s}\n", .{version});
}
