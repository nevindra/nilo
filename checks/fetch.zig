//! `zig build fetch-check -Dnetwork`: what a dependent downloads (ADR 066), as
//! a program the build runs (`checks/main.zig` says why).

const std = @import("std");
const Report = @import("main.zig").Report;

/// What somebody else's project downloads when it names this one.
///
/// `build.zig.zon` has claimed since ADR 037 that "a project that serves HTTP
/// and never imports `nilo_sql` does not fetch, build or link any of it", and
/// two thirds of that were true. `strings` and `nm` over such a program find no
/// SQLite and no libpq, so *link* held. *Fetch* did not: `b.lazyDependency` is
/// a request rather than a conditional, so both drivers were downloaded by
/// every dependent whatever they imported — 11.1 MB against 2.7 MB used, found
/// by an application that had no database in it at all (ADR 066).
///
/// The sentence lived in four files and none of them ran. This is the version
/// that runs: `bench/dependent/` is a project importing `nilo_http` and nothing
/// else, and `zig build --fetch` against an **empty** package cache says what
/// it actually costs. Anything but zio landing in there fails the step.
///
/// Off `test` on purpose, the way `smoke-tls` is: it needs the internet, and a
/// gate that passes because a machine had no route is worse than no gate.
pub const FetchCheck = struct {
    /// The one package a dependent that serves HTTP is supposed to pay for.
    const allowed = "zio-";

    /// `zig_exe` is the compiler running this build and `cache_root` its local
    /// cache, both of which only the build knows and so arrive as arguments.
    pub fn run(r: *Report, zig_exe: []const u8, cache_root: []const u8) anyerror!void {
        const io = r.io;

        // **Both caches have to be cold, and finding that out is the whole
        // subtlety of this step.** A dependent keeps unpacked packages in its
        // own `zig-pkg/` and downloaded tarballs in the global cache, and
        // either one being warm makes the wrong answer look like the right
        // one: with `zig-pkg/` populated nothing is downloaded, so counting
        // downloads says zero; with the global cache populated everything in
        // the manifest is unpacked whether or not the build asked for it, so
        // counting `zig-pkg/` says everything. The first two versions of this
        // step got one each.
        const cache = try std.fs.path.join(r.gpa, &.{ cache_root, "fetch-check" });
        r.root.deleteTree(io, "bench/dependent/zig-pkg") catch {};
        std.Io.Dir.cwd().deleteTree(io, cache) catch {};
        try std.Io.Dir.cwd().createDirPath(io, cache);

        // **The dependent builds against what `.paths` ships, not against
        // this working copy.** `bench/dependent/` names nilo by path, and a
        // path dependency sees every file on disk, so a file the package
        // leaves out was invisible here while every real dependent failed
        // to configure: `examples/embedded/dist`, read by `embedDir` while
        // configuring, from a directory `.paths` does not ship. So the
        // shipped paths are copied into a staging tree with the dependent
        // beside them at the same relative place, and `../..` resolves to
        // exactly what a fetch would have unpacked.
        const staged = try std.fs.path.join(r.gpa, &.{ cache, "staged" });
        try stageShipped(r, staged);
        const dependent = try std.fs.path.join(r.gpa, &.{ staged, "bench", "dependent" });
        // The global cache is the compiler's to choose, by this variable and
        // not by a flag: the child gets the environment this program has, with
        // the cold cache named in it and nothing left over that would name a
        // warm one.
        var environ = try r.environ.clone(r.gpa);
        try environ.put("ZIG_GLOBAL_CACHE_DIR", cache);
        _ = environ.swapRemove("ZIG_LOCAL_CACHE_DIR");
        _ = environ.swapRemove("ZIG_LOCAL_PKG_DIR");
        const result = try std.process.run(r.gpa, io, .{
            .argv = &.{
                zig_exe,
                "build",
                "--build-file",
                try std.fs.path.join(r.gpa, &.{ dependent, "build.zig" }),
                "--cache-dir",
                try std.fs.path.join(r.gpa, &.{ cache, "local" }),
            },
            .environ_map = &environ,
        });
        switch (result.term) {
            .exited => |code| if (code != 0) {
                // The build runner used to print this for the step; run as a
                // program, the child's own account is all there is of why.
                std.debug.print("{s}", .{result.stderr});
                return r.fail(
                    "nilo: the dependent in `bench/dependent/` did not build, so nothing was counted",
                    .{},
                );
            },
            else => return r.fail("nilo: the dependent's build did not exit normally", .{}),
        }

        // `p/` holds one tarball per package that was actually downloaded.
        // Missing means nothing was, which cannot happen — zio is not lazy —
        // so it is a failure rather than a pass.
        var packages = r.root.openDir(io, try std.fs.path.join(
            r.gpa,
            &.{ cache, "p" },
        ), .{ .iterate = true }) catch |err| return r.fail(
            "nilo: nothing was downloaded into `{s}/p` ({t}), which not even zio should manage",
            .{ cache, err },
        );
        defer packages.close(io);

        var unwanted: usize = 0;
        var iterator = packages.iterate();
        while (try iterator.next(io)) |entry| {
            if (std.mem.startsWith(u8, entry.name, allowed)) continue;
            unwanted += 1;
            try r.addError(
                "nilo: a dependent that imports only `nilo_http` downloaded `{s}`.\n" ++
                    "  Something in build.zig asks for it unconditionally — `b.lazyDependency` is a\n" ++
                    "  request, not a conditional, so it has to sit behind the option that wants it\n" ++
                    "  (ADR 066).",
                .{entry.name},
            );
        }
        if (unwanted > 0) return error.CheckFailed;
    }
};

/// Copy what a fetch of this package would unpack — the entries of
/// `.paths` in `build.zig.zon` — into `staged`, and the fetch-check
/// dependent beside it at `bench/dependent/`. Anything not shipped is not
/// there, which is the point.
fn stageShipped(r: *Report, staged: []const u8) !void {
    const io = r.io;
    const Manifest = struct { paths: []const []const u8 };
    const source = try r.root.readFileAllocOptions(
        io,
        "build.zig.zon",
        r.gpa,
        .limited(1 << 20),
        .of(u8),
        0,
    );
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = r.gpa,
        .arena = r.gpa,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => return r.fail("nilo: build.zig.zon does not parse: {f}", .{diagnostics.fmt("build.zig.zon")}),
    };

    const root = r.root;
    var out = try std.Io.Dir.cwd().createDirPathOpen(io, staged, .{});
    defer out.close(io);

    for (manifest.paths) |entry| try copyEntry(r, root, out, entry);
    for ([_][]const u8{ "build.zig", "build.zig.zon", "main.zig" }) |name| {
        const at = try std.fs.path.join(r.gpa, &.{ "bench", "dependent", name });
        try root.copyFile(at, out, at, io, .{ .make_path = true });
    }
}

fn copyEntry(r: *Report, root: std.Io.Dir, out: std.Io.Dir, entry: []const u8) !void {
    const io = r.io;
    const st = try root.statFile(io, entry, .{});
    if (st.kind != .directory) {
        try root.copyFile(entry, out, entry, io, .{ .make_path = true });
        return;
    }
    var dir = try root.openDir(io, entry, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(r.gpa);
    defer walker.deinit();
    while (try walker.next(io)) |file| {
        if (file.kind != .file) continue;
        const rel = try std.fs.path.join(r.gpa, &.{ entry, file.path });
        try root.copyFile(rel, out, rel, io, .{ .make_path = true });
    }
}
