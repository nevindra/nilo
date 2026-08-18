//! A dependent that serves HTTP and names no database, so that what it
//! downloads can be counted.
//!
//! This project is never run and its executable is never linked. `zig build
//! fetch-check -Dnetwork` points `zig build --fetch` at it with an empty
//! package cache and asserts that only zio landed — which is the claim
//! `build.zig.zon` makes about `.lazy = true` and which was false for a year
//! (ADR 0075). Four lines is the whole of it because the fetch happens while
//! *configuring* the build; nothing here has to compile for the check to mean
//! something.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "dependent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nilo_http", .module = nilo.module("nilo_http") }},
        }),
    });
    b.installArtifact(exe);
}
