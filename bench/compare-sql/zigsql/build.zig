//! The Zig candidates, built out here rather than by the root `build.zig`.
//!
//! `bench/compare/README.md` keeps the foreign candidates out of `zig build`
//! so a Zig repo does not need a Go toolchain to test itself. The same reason
//! puts these here: they are benchmark candidates, not part of the library, and
//! `nilo_sql` reaches them by path dependency without the root build knowing
//! this directory exists.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });
    const pg = b.dependency("pg", .{ .target = target, .optimize = optimize });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "nilo_sql", .module = nilo.module("nilo_sql") },
        .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
        .{ .name = "pg", .module = pg.module("pg") },
    };

    const ops = b.addExecutable(.{
        .name = "zigsql-ops",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ops.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(ops);
}
