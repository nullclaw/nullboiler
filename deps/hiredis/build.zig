const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "hiredis",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = b.path("hiredis.c"),
    });
    lib.installHeader(b.path("hiredis.h"), "hiredis.h");
    b.installArtifact(lib);
}
