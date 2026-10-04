const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "dev";

    var build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    const build_options_module = build_options.createModule();

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
    exe.root_module.linkLibrary(sqlite3_lib);
    exe.root_module.linkLibrary(hiredis_lib);
    exe.root_module.linkLibrary(mosquitto_lib);
    exe.root_module.addImport("build_options", build_options_module);
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
    exe_unit_tests.root_module.linkLibrary(sqlite3_lib);
    exe_unit_tests.root_module.linkLibrary(hiredis_lib);
    exe_unit_tests.root_module.linkLibrary(mosquitto_lib);
    exe_unit_tests.root_module.addImport("build_options", build_options_module);
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    // CLI regression tests spawn the installed binary, so install it first.
    const exe_basename = if (target.result.os.tag == .windows) "nullboiler.exe" else "nullboiler";
    run_exe_unit_tests.setEnvironmentVariable("NULLBOILER_TEST_EXE", b.fmt("zig-out/bin/{s}", .{exe_basename}));
    run_exe_unit_tests.setCwd(b.path("."));
    // The Run step itself must wait for the install, not just the test step,
    // or the tests observe a missing binary and skip.
    run_exe_unit_tests.step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_exe_unit_tests.step);
}
