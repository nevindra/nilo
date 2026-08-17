const std = @import("std");

/// Out of the way of the repo's own `zig build`, the same way
/// `spike/mailbox/` and `spike/completion_queue/` are: a spike is a question
/// being asked once, not a thing the test suite has to keep passing.
///
/// **There is no dependency here on purpose.** The question is whether an
/// outbound HTTP client can be tested with no engine, so a `zio` in this file
/// would answer it wrongly before a line ran.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "outbound-spike", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Say what this spike measures and how").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Drive the policy against a loopback server on std.Io.Threaded")
        .dependOn(&b.addRunArtifact(tests).step);
}
