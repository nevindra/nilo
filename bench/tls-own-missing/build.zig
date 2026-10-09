//! A dependent that asks for its own TLS library and never writes the import
//! (ADR 274). `zig build tls-own` runs this and expects it to fail with the
//! message nilo wrote, not Zig's "no module named 'tls'", which names no
//! line to write. The `addImport` below is the line that is missing.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true, .tls_own = true });
    // nilo.module("nilo_http").addImport("tls", ...);   <- forgotten

    const obj = b.addObject(.{
        .name = "dependent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_http", .module = nilo.module("nilo_http") }},
        }),
    });
    b.getInstallStep().dependOn(&obj.step);
}
