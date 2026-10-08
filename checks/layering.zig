//! The layering rule as a program: `zig build layering` runs this against the
//! repository (ADR 038).
//!
//! Zig 0.17 has no custom build steps, so what 0.16 ran inside the build runner
//! is an executable run by the build (`checks/main.zig` says why they are
//! here). The table of what each module may name stays in `build.zig`, where
//! it can be read next to the modules, and arrives as arguments.

const std = @import("std");
const Report = @import("main.zig").Report;

/// One row of `layers` in `build.zig`.
pub const Layer = struct {
    root: []const u8,
    may_import: []const []const u8,
    in_tests: []const []const u8 = &.{},
};

/// The step that reads `layers` and refuses an import that is not in it.
///
/// A scan rather than a parse, and the trade is stated where the table is:
/// it cannot see that an import is only reached from a `test` block, so the
/// exception is listed. What it *can* see is every other way the layering
/// erodes — a Core file naming the server, a tool module naming a sibling, a
/// relative path climbing out of its own directory — and those are the ways
/// it actually erodes, because they are the ones somebody in a hurry writes.
pub const Layering = struct {
    /// Every module root is scanned but `refusals/` is not: those are
    /// programs written wrong on purpose, and they import their own module
    /// by name the way a stranger's project would.
    const skipped = "refusals";

    pub fn run(r: *Report, layers: []const Layer) anyerror!void {
        const io = r.io;
        var refused: usize = 0;

        for (layers) |layer| {
            var dir = r.root.openDir(io, layer.root, .{ .iterate = true }) catch |err|
                return r.fail("nilo: cannot read `{s}/`: {s}", .{ layer.root, @errorName(err) });
            defer dir.close(io);

            var walker = try dir.walk(r.gpa);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                if (std.mem.indexOf(u8, entry.path, skipped) != null) continue;

                const source = try dir.readFileAlloc(io, entry.path, r.gpa, .limited(4 << 20));
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, source, at, "@import(\"")) |found| {
                    const from = found + "@import(\"".len;
                    const end = std.mem.indexOfScalarPos(u8, source, from, '"') orelse break;
                    at = end + 1;

                    const named = source[from..end];
                    if (notCode(source, found)) continue;
                    if (permits(layer, named)) continue;
                    refused += 1;
                    try r.addError("nilo: {s}/{s}:{d} imports `{s}`, which a module in this layer may not name.\n" ++
                        "  A module imports downward only (ADR 038); `{s}/` may name {f}.", .{
                        layer.root,
                        entry.path,
                        std.mem.count(u8, source[0..found], "\n") + 1,
                        named,
                        layer.root,
                        List{ .of = layer.may_import },
                    });
                }
            }
        }

        if (refused > 0) return error.CheckFailed;
    }

    /// Whether this `@import` is text rather than an import, which happens
    /// two ways here.
    ///
    /// A `//` comment: every module root in this repository opens with a doc
    /// comment showing how somebody else imports it, and a scan that could
    /// not tell those apart would refuse the documentation for saying the
    /// true thing.
    ///
    /// A `\\` multiline string: `sql/migrations.zig` *writes* Zig files, and
    /// the import line in the template it prints belongs to the file it
    /// generates rather than to this module. Without this half the layering
    /// step refuses a code generator for generating correct code.
    ///
    /// Line-level is enough for both, and for the same reason: everything
    /// after a `//` or a `\\` runs to the end of the line, so a real
    /// `@import` is never on the same line after either.
    fn notCode(source: []const u8, found: usize) bool {
        const line = if (std.mem.lastIndexOfScalar(u8, source[0..found], '\n')) |nl| nl + 1 else 0;
        const before = std.mem.trimStart(u8, source[line..found], " \t");
        return std.mem.startsWith(u8, before, "//") or std.mem.startsWith(u8, before, "\\\\");
    }

    fn permits(layer: Layer, named: []const u8) bool {
        if (std.mem.eql(u8, named, "std") or std.mem.eql(u8, named, "builtin")) return true;
        // A module may name itself, which is neither upward nor sideways.
        // `sql/deadline.zig` is a test root of its own rather than a file
        // inside `nilo_sql`, so it reaches the module the way a caller does
        // — and the build hands it the same instance, so there is no second
        // copy of the module for a type to disagree about. `fetch/deadline.zig`
        // does the same since the server names `nilo_fetch` (ADR 247); its
        // other roots still import `fetch.zig` as a file, which the line
        // below already allows.
        if (std.mem.startsWith(u8, named, "nilo_") and
            std.mem.eql(u8, named["nilo_".len..], layer.root)) return true;
        // A file rather than a module. `..` is how one would reach out of
        // its own directory, which is importing sideways by another name.
        if (std.mem.endsWith(u8, named, ".zig"))
            return std.mem.indexOf(u8, named, "..") == null;
        for (layer.may_import) |allowed| if (std.mem.eql(u8, named, allowed)) return true;
        for (layer.in_tests) |allowed| if (std.mem.eql(u8, named, allowed)) return true;
        return false;
    }

    /// The allowed list, written out in the message. A module with an empty
    /// one is the interesting case and it reads as a sentence rather than as
    /// an empty pair of brackets.
    const List = struct {
        of: []const []const u8,

        pub fn format(self: List, w: *std.Io.Writer) !void {
            if (self.of.len == 0) return w.writeAll("nothing but `std` and files beside it");
            for (self.of, 0..) |one, i| {
                if (i > 0) try w.writeAll(", ");
                try w.print("`{s}`", .{one});
            }
        }
    };
};

/// The step that refuses a file outside `http/`'s core for naming one inside
/// it. The table it reads is `http_core`, and the reason it exists is there.
pub const HttpCore = struct {
    pub fn run(r: *Report, core: []const []const u8, above: []const []const u8) anyerror!void {
        const io = r.io;
        var refused: usize = 0;

        var dir = r.root.openDir(io, "http", .{ .iterate = true }) catch |err|
            return r.fail("nilo: cannot read `http/`: {s}", .{@errorName(err)});
        defer dir.close(io);

        var walker = try dir.walk(r.gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const name = entry.path[0 .. entry.path.len - ".zig".len];
            if (listed(core, name) or listed(above, name)) continue;

            const source = try dir.readFileAlloc(io, entry.path, r.gpa, .limited(4 << 20));
            const tests = testsStart(source);

            var at: usize = 0;
            while (std.mem.indexOfPos(u8, source, at, "@import(\"")) |found| {
                const from = found + "@import(\"".len;
                const end = std.mem.indexOfScalarPos(u8, source, from, '"') orelse break;
                at = end + 1;

                if (found >= tests) continue;
                if (Layering.notCode(source, found)) continue;

                const named = source[from..end];
                if (!std.mem.endsWith(u8, named, ".zig")) continue;
                const bare = named[0 .. named.len - ".zig".len];
                if (!listed(core, bare)) continue;

                refused += 1;
                try r.addError("nilo: http/{s} imports `{s}` at line {d}, which is in the App's core.\n" ++
                    "  A file outside that core stays outside it (see `http_core` in build.zig).\n" ++
                    "  If the import is only a test's, move it below this file's first `test` block.", .{
                    entry.path,
                    named,
                    std.mem.count(u8, source[0..found], "\n") + 1,
                });
            }
        }

        if (refused > 0) return error.CheckFailed;
    }

    /// Where the file's tests begin, or its end when it has none. A `test` at
    /// column zero, which is what a top-level test block is.
    fn testsStart(source: []const u8) usize {
        var line: usize = 0;
        while (line < source.len) {
            const end = std.mem.indexOfScalarPos(u8, source, line, '\n') orelse source.len;
            const text = source[line..end];
            if (std.mem.startsWith(u8, text, "test \"") or std.mem.startsWith(u8, text, "test {"))
                return line;
            line = end + 1;
        }
        return source.len;
    }

    fn listed(of: []const []const u8, name: []const u8) bool {
        for (of) |one| if (std.mem.eql(u8, one, name)) return true;
        return false;
    }
};
