//! `zig build template-check`: `template/` is a project that builds and
//! passes its own test against this working copy (ADR 263).
//!
//! `template/build.zig.zon` ships with an empty `.dependencies`, because the
//! commit a release is pinned to does not exist until the release does, and
//! a first project adds nilo with `zig fetch --save`. So the check copies the
//! template to a scratch directory, writes the dependency in as a path to
//! this repository, and runs `zig build test` and `zig build` there. Nothing
//! is downloaded that the repository's own build did not already need: zio
//! comes from the global cache the way it does for `zig build test`.

const std = @import("std");
const Report = @import("main.zig").Report;

pub const TemplateCheck = struct {
    /// The text in `template/build.zig.zon` the dependency replaces.
    const marker = ".dependencies = .{},";

    pub fn run(r: *Report, zig_exe: []const u8, cache_root: []const u8, target: []const u8) anyerror!void {
        const io = r.io;
        const work = try std.fs.path.join(r.gpa, &.{ cache_root, "template-check" });
        // The scratch project is rewritten each run and its caches are kept,
        // so only the first run compiles nilo for it.
        r.root.deleteTree(io, try std.fs.path.join(r.gpa, &.{ work, "app" })) catch {};
        var app = try std.Io.Dir.cwd().createDirPathOpen(io, try std.fs.path.join(r.gpa, &.{ work, "app" }), .{});
        defer app.close(io);

        for ([_][]const u8{ "build.zig", "src/main.zig" }) |name| {
            const from = try std.fs.path.join(r.gpa, &.{ "template", name });
            try r.root.copyFile(from, app, name, io, .{ .make_path = true });
        }
        const manifest = try r.root.readFileAllocOptions(io, "template/build.zig.zon", r.gpa, .limited(1 << 16), .of(u8), 0);
        const at = std.mem.indexOf(u8, manifest, marker) orelse return r.fail(
            "nilo: `template/build.zig.zon` has no `{s}` line, which is where this check writes the path to nilo",
            .{marker},
        );
        // A path dependency is relative to the project that names it.
        const repo = try r.root.realPathFileAlloc(io, ".", r.gpa);
        const to_repo = try std.fs.path.relativeAlloc(r.gpa, repo, r.environ, try std.fs.path.join(r.gpa, &.{ work, "app" }), repo);
        const written = try std.fmt.allocPrint(r.gpa, "{s}.dependencies = .{{ .nilo = .{{ .path = \"{s}\" }} }},{s}", .{
            manifest[0..at], to_repo, manifest[at + marker.len ..],
        });
        try app.writeFile(io, .{ .sub_path = "build.zig.zon", .data = written });

        const app_path = try std.fs.path.join(r.gpa, &.{ work, "app" });
        const local = try std.fs.path.join(r.gpa, &.{ work, "local" });
        // "native" is what a query for the host spells, and is no value to pass.
        const target_flag = if (std.mem.eql(u8, target, "native"))
            "-Dtarget=native-native"
        else
            try std.fmt.allocPrint(r.gpa, "-Dtarget={s}", .{target});
        for ([_][]const u8{ "test", "install" }) |step| {
            const result = try std.process.run(r.gpa, io, .{
                .argv = &.{ zig_exe, "build", step, "--cache-dir", local, target_flag },
                .cwd = .{ .path = app_path },
                .environ_map = r.environ,
            });
            switch (result.term) {
                .exited => |code| if (code == 0) continue,
                else => {},
            }
            std.debug.print("{s}", .{result.stderr});
            return r.fail(
                "nilo: `zig build {s}` failed in `template/` (copied to {s}). A first project is that directory with nilo fetched into it, so it has to build.",
                .{ step, app_path },
            );
        }
    }
};
