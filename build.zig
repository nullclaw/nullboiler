const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite3_dep = b.dependency("sqlite3", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite3_lib = sqlite3_dep.artifact("sqlite3");

    const hiredis_dep = b.dependency("hiredis", .{
        .target = target,
        .optimize = optimize,
    });
    const hiredis_lib = hiredis_dep.artifact("hiredis");

    const mosquitto_dep = b.dependency("mosquitto", .{
        .target = target,
        .optimize = optimize,
    });
    const mosquitto_lib = mosquitto_dep.artifact("mosquitto");

    const exe = b.addExecutable(.{
        .name = "nullboiler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(sqlite3_lib);
    exe.linkLibrary(hiredis_lib);
    exe.linkLibrary(mosquitto_lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run nullboiler");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_unit_tests.linkLibrary(sqlite3_lib);
    exe_unit_tests.linkLibrary(hiredis_lib);
    exe_unit_tests.linkLibrary(mosquitto_lib);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
