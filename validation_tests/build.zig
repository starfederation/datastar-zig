const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const datastar = b.dependency("datastar", .{
        .target = target,
        .optimize = optimize,
    });
    const datastar_module = datastar.module("datastar");

    const exe = b.addExecutable(.{
        .name = "validation-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("validation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("datastar", datastar_module);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const build_step = b.step("build", "Build the validation test harness");
    build_step.dependOn(&install.step);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Build and run the validation test harness (port 7331)");
    run_step.dependOn(&run_exe.step);
}
