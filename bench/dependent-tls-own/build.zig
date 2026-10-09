//! A dependent that asks for its own TLS library and so must not download
//! nilo's (ADR 274). The twin of `../dependent/`: `zig build fetch-check
//! -Dnetwork` points `zig build --fetch` at it with an empty package cache and
//! asserts that only zio landed. It never writes the `addImport`, so it builds
//! nothing: the fetch happens while configuring, and compiling it is the
//! other twin's refusal (`../tls-own-missing/`).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true, .tls_own = true });

    _ = nilo.module("nilo_http");
}
