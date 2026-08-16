const std = @import("std");

/// Out of the way of the repo's own `zig build`, the same way
/// `spike/completion_queue/` and `bench/compare/` are: a spike is a question
/// being asked once, not a thing the test suite has to keep passing.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });

    // A knob rather than a constant, because the answer this spike produces
    // turned out to depend on it in a way worth showing: the machinery is
    // fixed, the ring is the caller's, and the allocator rounds the sum to a
    // size class that neither of them chose.
    const slots = b.option(u32, "slots", "posts a connection's mailbox can hold (default 16)") orelse 16;
    const config = b.addOptions();
    config.addOption(u32, "slots", slots);

    const exe = b.addExecutable(.{
        .name = "mailbox-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "config", .module = config.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Hold idle connections and report what they cost").dependOn(&run.step);
}
