//! A dependent that brings its own TLS library (ADR 274).
//!
//! `zig build tls-own` builds this with `-Dtarget` and expects it to compile:
//! nilo's pin of tls.zig is not asked for (`.tls_own = true`), the dependent's
//! `tls` dependency is, and the import is written the way the stub's message
//! says. An object rather than an executable, because the claim is that the
//! Engine analyses against the dependent's module, not that it links.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true, .tls_own = true });
    const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });
    nilo.module("nilo_http").addImport("tls", tls.module("tls"));

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
