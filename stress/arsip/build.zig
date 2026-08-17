//! arsip's build, written the way a dependent writes one.
//!
//! The imports list below grows one line per milestone and starts at one, on
//! purpose: `nilo_sql` drags pg.zig and four transitive dependencies behind a
//! `.lazy = true` flag (ADR 0040), and the only way to find out whether that
//! property survives contact with a real project is to have a project that
//! does not name it yet. Adding a module here should be the whole cost of
//! adopting it. When it is not, that goes in `DX.md`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Same `.optimize` through to the dependency: building nilo in Debug under
    // a ReleaseFast program is legal, slow, and nothing warns about it
    // (guide/getting-started.md).
    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
    };

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });

    const exe = b.addExecutable(.{ .name = "arsip", .root_module = root });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the arsip server").dependOn(&run.step);

    // Both optimize modes, because a lifetime bug passes in Debug and
    // segfaults in the mode people deploy in (CLAUDE.md, Conventions).
    const test_step = b.step("test", "Run the tests in Debug and ReleaseSafe");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = mode,
                .imports = imports,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
