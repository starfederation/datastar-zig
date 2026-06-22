const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const datastar = b.dependency("datastar", .{
        .target = target,
        .optimize = optimize,
    });
    const datastar_module = datastar.module("datastar");

    // --- Kitchen-sink stdlib example ---

    const stdlib_example = b.addExecutable(.{
        .name = "example_stdlib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example_stdlib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stdlib_example.root_module.addImport("datastar", datastar_module);

    const stdlib_install = b.addInstallArtifact(stdlib_example, .{});
    b.getInstallStep().dependOn(&stdlib_install.step);

    const stdlib_step = b.step("stdlib", "Build the stdlib kitchen-sink example");
    stdlib_step.dependOn(&stdlib_install.step);

    // --- http.zig example ---

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const httpz_example = b.addExecutable(.{
        .name = "example_httpz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example_httpz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    httpz_example.root_module.addImport("datastar", datastar_module);
    httpz_example.root_module.addImport("httpz", httpz.module("httpz"));

    const httpz_install = b.addInstallArtifact(httpz_example, .{});
    const httpz_step = b.step("http.zig", "Build the http.zig example");
    httpz_step.dependOn(&httpz_install.step);

    // --- Dusty example ---

    const dusty = b.dependency("dusty", .{
        .target = target,
        .optimize = optimize,
    });

    const dusty_example = b.addExecutable(.{
        .name = "example_dusty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example_dusty.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    dusty_example.root_module.addImport("datastar", datastar_module);
    dusty_example.root_module.addImport("dusty", dusty.module("dusty"));

    const dusty_install = b.addInstallArtifact(dusty_example, .{});
    const dusty_step = b.step("dusty", "Build the dusty example");
    dusty_step.dependOn(&dusty_install.step);
}
