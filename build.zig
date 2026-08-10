const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zfast-hello",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    b.step("run", "Jalankan server hello").dependOn(&run_cmd.step);

    const tes = b.addTest(.{ .root_module = mod });
    const run_tes = b.addRunArtifact(tes);
    b.step("test", "Jalankan semua tes").dependOn(&run_tes.step);
}
