const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    root.addImport("cachezig", b.dependency("cachezig", .{
        .target = target,
        .optimize = optimize,
    }).module("cache"));

    // zigache is vendored rather than fetched. Its `build.zig` is written for
    // Zig 0.14 and calls `b.addExecutable(.{ .root_source_file = … })`, which
    // 0.16 removed — so `b.dependency` cannot run it at all, whatever its
    // source does. `vendor/zigache/` is its `src/` unchanged except for the
    // one line `vendor/zigache/rwlock.zig` explains.
    root.addImport("zigache", b.createModule(.{
        .root_source_file = b.path("vendor/zigache/zigache.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const exe = b.addExecutable(.{ .name = "cache-zig", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "run the comparison").dependOn(&run.step);
}
