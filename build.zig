const std = @import("std");

const examples = [_]Example{
    .{ .name = "hello", .about = "The smallest thing that serves" },
    .{ .name = "rest", .about = "Typed handlers, a service, fail functions, middleware" },
    .{ .name = "spa", .about = "A single-page app's files plus a JSON API" },
};

const Example = struct { name: []const u8, about: []const u8 };

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

    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ zfast, bench }) |module| {
        const tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
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

        // The examples carry the tests the README promises are possible, so
        // they run with everything else rather than being decoration.
        const example_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(example_tests).step);

        const run = b.addRunArtifact(built);
        // Run from the example's own directory: the static one reads its
        // files from a path relative to the working directory.
        run.setCwd(b.path(b.fmt("examples/{s}", .{example.name})));
        b.step(b.fmt("run-{s}", .{example.name}), example.about).dependOn(&run.step);
    }
}
