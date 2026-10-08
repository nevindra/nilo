//! A dependent that asks for nilo twice, in Debug and in ReleaseSafe, the
//! way a project that tests in both modes does.
//!
//! The configurer compiles nilo's `build.zig` once per process, so its
//! globals are shared by both instances, and the module memo `protoFor` and
//! `fetchFor` keep was a fixed array the second instance ran off the end of
//! (`index out of bounds: index 32, len 32`). `zig build two-modes` runs
//! `zig build -l` here: configuring is where it panicked, so nothing has to
//! compile for the check to mean something.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    for ([_]std.lang.Optimize{ .debug, .safe }) |mode| {
        const nilo = b.dependency("nilo", .{ .target = target, .optimize = mode });
        _ = nilo.module("nilo_http");
    }
}
