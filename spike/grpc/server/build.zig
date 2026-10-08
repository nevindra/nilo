const std = @import("std");

/// nilo itself as the server `run.sh` points the clients at, built against
/// this working copy with `.grpc = true` the way a dependent would ask.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .http2 = true, .tls = true });
    const exe = b.addExecutable(.{
        .name = "nilo-grpc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_http", .module = nilo.module("nilo_http") }},
        }),
    });
    b.installArtifact(exe);
}
