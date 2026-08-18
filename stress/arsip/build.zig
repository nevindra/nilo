//! arsip's build, written the way a dependent writes one.
//!
//! The imports list grows one line per milestone and started at one, on purpose:
//! `nilo_sql` drags pg.zig and four transitive dependencies behind a
//! `.lazy = true` flag (ADR 0040), and the only way to find out whether that
//! property survives contact with a real project is to have a project that does
//! not name it yet. Adding a module should be the whole cost of adopting it.
//! When it is not, that goes in `DX.md`.
//!
//! **`niloFor` exists because the first version of this file got it wrong.**
//! `guide/getting-started.md` says to pass `.optimize` through to the
//! dependency, and `guide/testing.md` says to run your own suite in both
//! optimize modes. Do both the obvious way — resolve `b.dependency` once from
//! `standardOptimizeOption`, then loop over two modes building tests — and the
//! ReleaseSafe test binary links a **Debug** nilo. Nothing warns; the only
//! evidence is `-ODebug` next to `-Mnilo_http=` in a command line nobody reads.
//! One dependency instance per mode is the fix. See item 9 in `DX.md`.

const std = @import("std");

fn niloFor(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) []const std.Build.Module.Import {
    // `.sql = true` is what fetches pg.zig and zqlite, and leaving it out is
    // what stops them being fetched — which is the fix for item 16 in `DX.md`
    // and is the whole of what adopting it cost here (ADR 0075).
    const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .sql = true });
    return b.allocator.dupe(std.Build.Module.Import, &.{
        .{ .name = "nilo_http", .module = nilo.module("nilo_http") },
        // M2. Three tool modules, and three lines is the whole cost of them: no
        // event loop, no transitive dependency, nothing fetched. Still no
        // `nilo_sql`, so pg.zig and its four remain undownloaded.
        .{ .name = "nilo_config", .module = nilo.module("nilo_config") },
        .{ .name = "nilo_id", .module = nilo.module("nilo_id") },
        .{ .name = "nilo_pw", .module = nilo.module("nilo_pw") },
        // M3. A database that is a file, so there is nothing to run beside the
        // process and nothing to configure — which is the whole reason this
        // milestone goes here rather than at Postgres.
        //
        // The line that was supposed to be free until now was not. **Before
        // this line existed**, a clean `zig build` of arsip already downloaded
        // pg.zig, tls, xsync, metrics and zqlite — 11.1 MB of driver for an app
        // whose imports were four HTTP-and-tools modules. See item 16 in
        // `DX.md`; the binary is clean, the download is not.
        .{ .name = "nilo_sql", .module = nilo.module("nilo_sql") },
    }) catch @panic("out of memory");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = niloFor(b, target, optimize),
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
                // Per mode, not once. This is the line the comment above is about.
                .imports = niloFor(b, target, mode),
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
