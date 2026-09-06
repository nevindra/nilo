const std = @import("std");

/// Out of the way of the repo's own `zig build`, the same way
/// `spike/mailbox/` is: a spike is a question asked once, not something the
/// suite has to keep passing.
///
/// **No dependencies at all, and that is half the finding.** The module this
/// spike is for needs no event loop, so it needs no zio — which is the entry
/// condition for the layer `nilo_id`, `nilo_config` and `nilo_pw` sit in
/// (ADR 0042). If this file ever grows a `b.dependency`, the module belongs
/// somewhere else.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cache-ring-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Ask the ring one of its three questions").dependOn(&run.step);
}
