//! The repository's own checks, as one program with a subcommand each:
//! `layering`, `http-core`, `adr-check`, `docs-check`, `docs-index`,
//! `fetch-check`, `template-check` and `notice`. `build.zig` builds this for the host and runs
//! it from the repository root, one Run step to a check.
//!
//! **Why programs and not steps.** Zig 0.16 let `build.zig` define a step with
//! a function of its own, and these checks were exactly that: they read the
//! tree and failed with a message. Zig 0.17 has no such step (the build runner
//! only executes the nodes it has a kind for), so each became a program the
//! build runs, with the same scan and the same message. A Run step whose only
//! output is its exit code has side effects, so it runs every time it is
//! asked for, as the old ones did.
//!
//! **Why here and not in `core/`.** These read the repository rather than
//! build anything of it, and no module imports them. The directory is not in
//! `.paths` in `build.zig.zon`, so a dependent never has it, and `build.zig`
//! makes these steps only when it is the package being built.
//!
//! What a check needs from `build.zig` (the table of layers, the compiler's
//! path) arrives as arguments, which keeps the tables where they can be read
//! beside the modules they describe.

const std = @import("std");
const layering = @import("layering.zig");
const adr = @import("adr.zig");
const docs = @import("docs.zig");
const fetch = @import("fetch.zig");
const template = @import("template.zig");

/// Where a check puts what it found. Every message already begins `nilo: `,
/// and is printed as it is found; a check that found any returns
/// `error.CheckFailed` at the end, which is the exit code the Run step reads.
pub const Report = struct {
    io: std.Io,
    /// The process arena: a check is short-lived and never frees.
    gpa: std.mem.Allocator,
    /// The repository root, which is the working directory the Run step sets.
    root: std.Io.Dir,
    environ: *const std.process.Environ.Map,

    pub fn addError(_: *Report, comptime format: []const u8, args: anytype) !void {
        std.debug.print(format ++ "\n", args);
    }

    /// For the failure that stops a check at once.
    pub fn fail(_: *Report, comptime format: []const u8, args: anytype) error{CheckFailed} {
        std.debug.print(format ++ "\n", args);
        return error.CheckFailed;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var report: Report = .{ .io = init.io, .gpa = arena, .root = std.Io.Dir.cwd(), .environ = init.environ_map };
    const args = try init.minimal.args.toSlice(arena);

    const command = if (args.len > 1) args[1] else usage();
    const rest = args[2..];
    const outcome = dispatch(&report, command, rest);
    outcome catch |err| switch (err) {
        error.CheckFailed => std.process.exit(1),
        else => |e| {
            std.debug.print("nilo: `{s}` stopped on {s}\n", .{ command, @errorName(e) });
            std.process.exit(2);
        },
    };
}

fn dispatch(r: *Report, command: []const u8, rest: []const []const u8) !void {
    if (std.mem.eql(u8, command, "layering")) {
        // One argument a row of `layers`: `root=may,import=in,tests`.
        const layers = try r.gpa.alloc(layering.Layer, rest.len);
        for (rest, layers) |arg, *layer| {
            var parts = std.mem.splitScalar(u8, arg, '=');
            layer.* = .{
                .root = parts.next() orelse usage(),
                .may_import = try list(r, parts.next() orelse usage()),
                .in_tests = try list(r, parts.next() orelse usage()),
            };
        }
        return layering.Layering.run(r, layers);
    } else if (std.mem.eql(u8, command, "http-core")) {
        if (rest.len != 2) usage();
        return layering.HttpCore.run(r, try list(r, rest[0]), try list(r, rest[1]));
    } else if (std.mem.eql(u8, command, "adr-check")) {
        return adr.AdrCheck.run(r);
    } else if (std.mem.eql(u8, command, "docs-check")) {
        return docs.DocsCheck.run(r, false);
    } else if (std.mem.eql(u8, command, "docs-index")) {
        return docs.DocsCheck.run(r, true);
    } else if (std.mem.eql(u8, command, "fetch-check")) {
        if (rest.len != 2) usage();
        return fetch.FetchCheck.run(r, rest[0], rest[1]);
    } else if (std.mem.eql(u8, command, "template-check")) {
        if (rest.len != 3) usage();
        return template.TemplateCheck.run(r, rest[0], rest[1], rest[2]);
    } else if (std.mem.eql(u8, command, "notice")) {
        // Say out loud that a step asserted nothing: `error.SkipZigTest` is
        // invisible through `zig build`, so a step that is off says so itself
        // (the reason is on `Checks.notice` in `build.zig`).
        if (rest.len != 1) usage();
        std.debug.print("{s}\n", .{rest[0]});
        return;
    }
    usage();
}

/// `a,b,c`, where an empty string is an empty list.
fn list(r: *Report, csv: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |one| if (one.len > 0) try out.append(r.gpa, one);
    return out.items;
}

fn usage() noreturn {
    std.debug.print(
        "usage: checks layering <root=may,import=in,tests>... | http-core <core,..> <above,..> | " ++
            "adr-check | docs-check | docs-index | fetch-check <zig> <cache> | template-check <zig> <cache> <target> | notice <message>\n",
        .{},
    );
    std.process.exit(2);
}
