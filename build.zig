const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Check if everything compiles (for ZLS)");

    _ = b.addModule("datastar", .{
        .root_source_file = b.path("src/datastar.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const datastar_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/datastar.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_datastar_tests = b.addRunArtifact(datastar_tests);
    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_datastar_tests.step);
    check.dependOn(&datastar_tests.step);
}
