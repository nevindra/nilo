const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zqlite = b.dependency("zqlite", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "sqlite-facts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the five checks").dependOn(&run.step);
}
