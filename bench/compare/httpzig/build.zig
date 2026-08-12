const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Only so the build-time table can show both columns for both Zig
    // frameworks. Default is null, which is what http.zig would do on its own.
    const strip = b.option(bool, "strip", "Leave debug info out");

    const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "httpzig-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "httpz", .module = httpz.module("httpz") }},
        }),
    });

    b.installArtifact(exe);
}
