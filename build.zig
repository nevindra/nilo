const std = @import("std");

const examples = [_]Example{
    .{ .name = "hello", .about = "The smallest thing that serves" },
    .{ .name = "rest", .about = "Typed handlers, a service, fail functions, middleware" },
    .{ .name = "spa", .about = "A single-page app's files plus a JSON API" },
    .{ .name = "stream", .about = "A streamed report and a stream of events" },
    .{ .name = "chat", .about = "A WebSocket, from the handshake to the last frame" },
};

const Example = struct { name: []const u8, about: []const u8 };

/// The suite runs in both, every time, and `-Doptimize=` does not change it.
/// A lifetime bug passes in `Debug` — where the bytes a dangling pointer
/// points at happen to still be there — and segfaults in a release build,
/// which is the mode the README tells people to deploy in. That is not a
/// hypothetical: `Response.headers` got away with a use-after-return for a
/// whole stage because nothing here ever built the tests any other way
/// ([ADR 0019](docs/adr/0019-a-response-owns-its-headers.md)).
const test_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    // The library itself, under the name it is imported by. Everything
    // else here — the benchmark server, every example — depends on this
    // exactly the way somebody else's project would.
    const zfast = b.addModule("zfast", .{
        .root_source_file = b.path("src/zfast.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });

    // The benchmark target: a routed GET with a path param returning ~1KB
    // of JSON, which is the primary metric in docs/plan.md.
    const bench = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfast", .module = zfast }},
    });

    const exe = b.addExecutable(.{ .name = "zfast-hello", .root_module = bench });
    b.installArtifact(exe);
    b.step("run", "Run the benchmark server").dependOn(&b.addRunArtifact(exe).step);

    // Where the time inside one request goes. Not a test: a number that
    // moves with the weather has no business failing a build.
    const profile = b.addExecutable(.{
        .name = "zfast-profile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/profile.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
        }),
    });
    b.step("profile", "Time the pieces of one request").dependOn(&b.addRunArtifact(profile).step);

    const test_step = b.step("test", "Run all tests, in Debug and in ReleaseSafe");
    for (test_modes) |mode| {
        // Each mode needs its own copy of everything, down to zio: a module
        // carries the optimize mode it was created with.
        const engine = b.dependency("zio", .{ .target = target, .optimize = mode });

        // The library's tests run under their own root, which silences
        // logging — several of them drive a request into failure on
        // purpose, and the stderr that produces makes a passing suite print
        // `failed command`.
        const lib_tests = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zio", .module = engine.module("zio") }},
        });

        const library = b.createModule(.{
            .root_source_file = b.path("src/zfast.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zio", .module = engine.module("zio") }},
        });

        const bench_tests = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = mode,
            .imports = &.{.{ .name = "zfast", .module = library }},
        });

        for ([_]*std.Build.Module{ lib_tests, bench_tests }) |module| {
            const tests = b.addTest(.{ .root_module = module });
            test_step.dependOn(&b.addRunArtifact(tests).step);
        }

        // The examples carry the tests the README promises are possible, so
        // they run with everything else rather than being decoration.
        for (examples) |example| {
            const module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
                .target = target,
                .optimize = mode,
                .imports = &.{.{ .name = "zfast", .module = library }},
            });
            const tests = b.addTest(.{ .root_module = module });
            test_step.dependOn(&b.addRunArtifact(tests).step);
        }
    }

    // Every example is built by `zig build examples`, so one that stops
    // compiling is a failed build rather than a surprise for the first
    // person who copies it.
    const examples_step = b.step("examples", "Build every example");
    for (examples) |example| {
        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{example.name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zfast", .module = zfast }},
        });
        const built = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{example.name}),
            .root_module = module,
        });
        examples_step.dependOn(&b.addInstallArtifact(built, .{}).step);

        const run = b.addRunArtifact(built);
        // Run from the example's own directory: the static one reads its
        // files from a path relative to the working directory.
        run.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        b.step(b.fmt("run-{s}", .{example.name}), example.about).dependOn(&run.step);
    }
}
