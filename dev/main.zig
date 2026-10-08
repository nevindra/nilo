//! `zig build dev` — the server restarted on every save
//! ([ADR 190](../docs/adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)).
//!
//! ```
//! nilo-dev [--zig <path>] [--build <step>] [--no-incremental] [--keep-cache] [-D<option>…] <exe> [-- <server args>]
//! ```
//!
//! This is not hot reloading and cannot be: a Zig binary does not swap its
//! own code. What it is: one `zig build <step> --watch`, run once and left
//! running, and the server it produces started again every time the binary
//! it writes changes. The watching, the rebuilding and the deciding what to
//! rebuild are all the build system's — this file spawns the build and the
//! server and reads the size and mtime of one file every quarter second.
//!
//! **It watches the build, not the checkout.** What `--watch` reacts to is
//! the set of files the compiler read to make the binary: the `.zig` files
//! the server imports, nilo's own among them, and anything it `@embedFile`s.
//! A front end kept beside the server is not in that set, so a save under
//! it rebuilds nothing and restarts nothing; the front end's own dev server
//! is the loop for that. Neither is `build.zig`, nor a `.zig` file nothing
//! imports yet. `bench/devloop.py` is the check that this stays so.
//!
//! **A build that fails changes nothing, so nothing restarts.** The watch
//! prints the errors, the binary on disk is the last one that compiled, and
//! the server running is the one serving it. There is no code here for
//! that case, and that is the point of watching the output rather than the
//! sources.
//!
//! **The first server is the current one, or none.** Before the
//! watch starts, the same build runs once to the end: the binary on disk is
//! whatever the last run left, and served first it seeded a database with a
//! schema the sources no longer had. If that build fails the stale binary is
//! removed, and the first build that compiles is the first thing started.
//!
//! **The build is incremental unless asked otherwise.** The compiler stays
//! resident and patches what it already made, so a save is served in under
//! a second on Zig 0.17, against about four without it, for 189 MB of
//! resident compiler per artifact the step builds. There is nothing to
//! prune either: a directory the resident compiler is patching in place is
//! not stale, so nothing is. On 0.16 its output only ran under LLVM when
//! libc was linked, which every nilo server does through zio, and it was
//! opt-in for that reason. The numbers are in the ADR.
//!
//! **`--no-incremental` is the other loop, and it deletes what it leaves
//! behind.** A rebuild that is not incremental writes the whole binary into a
//! new `.zig-cache/o/<hash>/` — 27 MB for `examples/hello`, the size of
//! the Debug binary for anything else — and Zig evicts nothing, so a day of
//! saves is a gigabyte. After every restart the runner walks `o/`, keeps
//! the one directory whose copy of the binary is byte for byte what it just
//! started, and deletes the rest. Deleting is safe because the hash is of
//! the content: an undo back to a previous version rebuilds into the same
//! directory rather than failing on a cache hit with nothing behind it,
//! which was tried before it was relied on. `--keep-cache` turns it off.
//!
//! **The old server is asked, not killed.** SIGTERM, which nilo answers by
//! draining what is in flight (ADR 077); SIGKILL only after `drain_ms`.
//! Each child is in a process group of its own, so Ctrl-C reaches this
//! process alone and the two signals a server gets are this file's — a
//! second one would be read by nilo as "stop waiting" and skip the drain.
//!
//! Nothing in this file is linked into a server. It imports `std` and
//! nothing of nilo's, and a release build never names it.

const std = @import("std");
const builtin = @import("builtin");

/// How often the binary is looked at.
const poll_ms = 250;
/// How long a server gets to drain after SIGTERM before SIGKILL.
const drain_ms = 5_000;
/// How long the build is given to stop on the way out.
const build_stop_ms = 3_000;

const Options = struct {
    exe: []const u8,
    zig: []const u8 = "zig",
    step: []const u8 = "install",
    /// `--no-incremental` turns it off; `--incremental`, the flag from when
    /// it was opt-in, is still accepted and changes nothing.
    incremental: bool = true,
    /// `--keep-cache`: leave the stale `o/<hash>/` directories where they
    /// are.
    prune: bool = true,
    /// `--trace`: print the binary's stamp on every poll it changes.
    trace: bool = false,
    /// `-D…` options handed on to `zig build`, so a project can set
    /// something for the dev loop alone: `-Dllvm`, say.
    build_options: []const []const u8 = &.{},
    server_args: []const []const u8 = &.{},
};

/// The size and mtime of the binary as it was last started. Both, because
/// a patched binary can keep its size and a copied one its mtime.
const Stamp = struct {
    size: u64,
    mtime_ns: i96,

    fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

/// A child and the thread waiting on it. `Child.wait` blocks, and the loop
/// below must not, so the wait runs on a thread of its own and reports
/// through `term`.
const Running = struct {
    child: std.process.Child,
    pid: std.posix.pid_t,
    waiter: std.Thread,
    started_ns: u64,
    term: std.atomic.Value(u32) = .init(still_running),
    exit: std.process.Child.Term = .{ .unknown = 0 },

    const still_running: u32 = 0;
    const done: u32 = 1;

    fn start(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !*Running {
        const r = try gpa.create(Running);
        errdefer gpa.destroy(r);
        r.* = .{
            // A group of its own (see the header), which for the build
            // also means the compilers it keeps under it are one `kill`.
            .child = try std.process.spawn(io, .{ .argv = argv, .pgid = 0 }),
            .pid = undefined,
            .waiter = undefined,
            .started_ns = now(io),
        };
        r.pid = r.child.id.?;
        r.waiter = try std.Thread.spawn(.{}, waitOn, .{ r, io });
        return r;
    }

    fn waitOn(r: *Running, io: std.Io) void {
        r.exit = r.child.wait(io) catch .{ .unknown = 0 };
        r.term.store(done, .release);
    }

    fn exited(r: *const Running) bool {
        return r.term.load(.acquire) == done;
    }

    /// SIGTERM to the group, a bounded wait, SIGKILL if it is still there,
    /// then reap. Answers how long the drain took.
    fn stop(r: *Running, io: std.Io, grace_ms: u64) u64 {
        const t0 = now(io);
        if (!r.exited()) std.posix.kill(-r.pid, .TERM) catch {};
        var waited: u64 = 0;
        while (!r.exited() and waited < grace_ms) : (waited += 50) sleep(io, 50);
        if (!r.exited()) {
            std.posix.kill(-r.pid, .KILL) catch {};
            while (!r.exited()) sleep(io, 20);
        }
        r.waiter.join();
        return (now(io) - t0) / std.time.ns_per_ms;
    }

    /// Whether the process died within a second of starting — a binary
    /// that could not be run at all rather than a server that fell over.
    fn diedAtOnce(r: *const Running, io: std.Io) bool {
        return r.exited() and now(io) - r.started_ns < std.time.ns_per_s;
    }

    fn free(r: *Running, gpa: std.mem.Allocator) void {
        gpa.destroy(r);
    }
};

/// Set by SIGINT or SIGTERM; read by the loop.
var stopping: std.atomic.Value(bool) = .init(false);

/// The signal number's type, read off `Sigaction` the way the Engine does.
const SigNum = @typeInfo(@typeInfo(@typeInfo(
    @FieldType(@FieldType(std.posix.Sigaction, "handler"), "handler"),
).optional.child).pointer.child).@"fn".param_types[0].?;

fn onSignal(_: SigNum) callconv(.c) void {
    stopping.store(true, .release);
}

fn installSignals() void {
    if (builtin.os.tag == .windows) return;
    const action = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    // What lives as long as the process — the parsed options, the argv
    // lines — comes out of the arena `Init` frees on exit, so the leak
    // check under Debug has nothing to say about it.
    const arena = init.arena.allocator();
    const opts = parse(arena, init.minimal.args) orelse usage();
    installSignals();

    // The build, once, the same line with and without `--watch`. `--watch`
    // is the whole of the file watching, and `-fincremental` is the whole of
    // the difference between 0.12s and 2.8s (see the header). Its output is
    // the terminal's, so a compile error lands where the person is looking.
    var build_argv: std.ArrayList([]const u8) = .empty;
    defer build_argv.deinit(gpa);
    try build_argv.appendSlice(gpa, &.{ opts.zig, "build", opts.step });
    if (opts.incremental) try build_argv.append(gpa, "-fincremental");
    try build_argv.appendSlice(gpa, opts.build_options);

    // Built through before anything is started. The binary on disk is
    // whatever the last run left, and nothing but a build can say whether
    // it is still what the sources describe: `--watch` rewrites it only
    // once it has compiled, and started first it was served first, seeding
    // a database with the schema the save had just removed.
    //
    // A build that fails says the binary is stale or unknown, and it is
    // removed rather than remembered as seen. Remembered, a fix that put
    // the sources back to the ones it was built from never started: the
    // build compiled, found the file on disk already right, and did not
    // write it, so its stamp never moved. Removed, the first build that
    // compiles writes it, whatever it compiles to.
    say("building with `{s}` before starting anything", .{joined(arena, build_argv.items)});
    const current = try buildOnce(gpa, io, build_argv.items);
    if (stopping.load(.acquire)) return;
    if (!current) {
        std.Io.Dir.cwd().deleteFile(io, opts.exe) catch |err| switch (err) {
            error.FileNotFound => {},
            else => say("could not remove the stale {s}: {s}", .{ opts.exe, @errorName(err) }),
        };
        say("the build failed; nothing is started until one compiles", .{});
    }

    try build_argv.insert(gpa, 3, "--watch");
    say("watching with `{s}`; serving {s} when it is written", .{ joined(arena, build_argv.items), opts.exe });
    const build = try Running.start(gpa, io, build_argv.items);
    defer build.free(gpa);

    var server_argv: std.ArrayList([]const u8) = .empty;
    defer server_argv.deinit(gpa);
    try server_argv.append(gpa, opts.exe);
    try server_argv.appendSlice(gpa, opts.server_args);

    const t_start = now(io);
    var server: ?*Running = null;
    var serving: ?Stamp = null;
    var started_once = false;
    // A change is acted on once it has been seen twice, so a binary still
    // being written is not started half way through.
    var pending: ?Stamp = null;

    while (!stopping.load(.acquire)) {
        if (build.exited()) {
            say("`zig build` stopped ({s}); nothing will be rebuilt", .{termText(build.exit)});
            break;
        }

        if (server) |r| if (r.exited()) {
            say("the server exited ({s}); waiting for the next build", .{termText(r.exit)});
            if (opts.incremental and r.diedAtOnce(io) and r.exit != .signal) say(
                "  if it died at start, try once with --no-incremental: " ++
                    "the release notes list incremental compilation's known bugs",
                .{},
            );
            r.waiter.join();
            r.free(gpa);
            server = null;
        };

        if (stamp(io, opts.exe)) |seen| {
            if (opts.trace) say("TRACE t={d}ms size={d} mtime={d}", .{ (now(io) - t_start) / std.time.ns_per_ms, seen.size, @as(i64, @intCast(@divTrunc(seen.mtime_ns, 1000))) });
            const fresh = if (serving) |s| !s.eql(seen) else true;
            if (fresh) {
                if (pending != null and pending.?.eql(seen)) {
                    var drained: u64 = 0;
                    if (server) |r| {
                        drained = r.stop(io, drain_ms);
                        r.free(gpa);
                        server = null;
                    }
                    server = Running.start(gpa, io, server_argv.items) catch |err| {
                        say("could not start {s}: {s}", .{ opts.exe, @errorName(err) });
                        serving = seen;
                        pending = null;
                        sleep(io, poll_ms);
                        continue;
                    };
                    if (!started_once) {
                        started_once = true;
                        say("started {s} (pid {d})", .{ opts.exe, server.?.pid });
                    } else {
                        say("{s} changed; restarted (pid {d}, the old one drained in {d} ms)", .{ opts.exe, server.?.pid, drained });
                        // After a restart and not at the first start: here
                        // the build has just finished writing and is idle,
                        // and at the first start it is running.
                        if (opts.prune and !opts.incremental) pruneStale(io, gpa, opts.exe);
                    }
                    serving = seen;
                    pending = null;
                } else {
                    pending = seen;
                }
            }
        }

        sleep(io, poll_ms);
    }

    // The way out. Ctrl-C has usually reached both children already; this
    // is what makes sure of it and waits.
    if (server) |r| {
        const drained = r.stop(io, drain_ms);
        say("stopped the server (drained in {d} ms)", .{drained});
        r.free(gpa);
    }
    if (!build.exited()) _ = build.stop(io, build_stop_ms) else build.waiter.join();
    say("done", .{});
}

/// One `zig build` to the end, and whether it compiled. Waited on the way the
/// loop waits, so a Ctrl-C during a slow first build stops it rather than
/// being held until it finishes.
fn buildOnce(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    const build = try Running.start(gpa, io, argv);
    defer build.free(gpa);
    while (!build.exited()) {
        if (stopping.load(.acquire)) {
            _ = build.stop(io, build_stop_ms);
            return false;
        }
        sleep(io, 50);
    }
    build.waiter.join();
    return switch (build.exit) {
        .exited => |code| code == 0,
        else => false,
    };
}

// ---- the small parts ----

fn parse(arena: std.mem.Allocator, args: std.process.Args) ?Options {
    var it: std.process.Args.Iterator = .init(args);
    _ = it.skip(); // the program's own name
    var opts: Options = .{ .exe = "" };
    var rest: std.ArrayList([]const u8) = .empty;
    var build_options: std.ArrayList([]const u8) = .empty;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            while (it.next()) |a| rest.append(arena, a) catch return null;
            break;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            opts.zig = it.next() orelse return null;
        } else if (std.mem.eql(u8, arg, "--build")) {
            opts.step = it.next() orelse return null;
        } else if (std.mem.eql(u8, arg, "--incremental")) {
            opts.incremental = true;
        } else if (std.mem.eql(u8, arg, "--no-incremental")) {
            opts.incremental = false;
        } else if (std.mem.eql(u8, arg, "--keep-cache")) {
            opts.prune = false;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            opts.trace = true;
        } else if (std.mem.startsWith(u8, arg, "-D")) {
            build_options.append(arena, arg) catch return null;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return null;
        } else if (opts.exe.len == 0) {
            opts.exe = arg;
        } else {
            return null;
        }
    }
    if (opts.exe.len == 0) return null;
    opts.server_args = rest.items;
    opts.build_options = build_options.items;
    return opts;
}

fn usage() noreturn {
    std.debug.print(
        \\usage: nilo-dev [--zig <path>] [--build <step>] [--no-incremental] [--keep-cache] [--trace] [-D<option>…] <exe> [-- <server args>]
        \\
        \\  runs `zig build <step> --watch` once, and starts <exe> again every time that
        \\  build writes it. --build defaults to `install`. -D options go to `zig build`.
        \\  The build is incremental: the compiler stays resident, .zig-cache stays
        \\  flat, and a save is served in under a second. --no-incremental rebuilds
        \\  instead, every save leaves the previous binary in .zig-cache/o/, and the
        \\  runner deletes those after each restart; --keep-cache leaves them.
        \\  --trace prints the binary's size and mtime whenever they move.
        \\
    , .{});
    std.process.exit(2);
}

/// Delete every `.zig-cache/o/<hash>/` holding a copy of the served binary
/// that is not the one just started. The cache is the build root's, and
/// the build root is found the way `zig build` finds it: the nearest
/// `build.zig` at or above the working directory.
fn pruneStale(io: std.Io, gpa: std.mem.Allocator, exe: []const u8) void {
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = buildRoot(io, &root_buf) orelse return;
    const o_path = std.fs.path.join(gpa, &.{ root, ".zig-cache", "o" }) catch return;
    defer gpa.free(o_path);
    var o = std.Io.Dir.cwd().openDir(io, o_path, .{ .iterate = true }) catch return;
    defer o.close(io);
    const served = std.Io.Dir.cwd().openFile(io, exe, .{}) catch return;
    defer served.close(io);
    const pruned = pruneStaleIn(io, gpa, o, std.fs.path.basename(exe), served) orelse return;
    if (pruned.dirs > 0) say("pruned {d} stale build(s) of {s} from .zig-cache, {d} MB", .{ pruned.dirs, std.fs.path.basename(exe), pruned.bytes / 1_000_000 });
}

const Pruned = struct { dirs: usize, bytes: u64 };

/// The walk itself, over an `o/` directory opened for iteration: every
/// subdirectory holding a file called `name` that is not byte for byte
/// `served` is deleted. Null when the served file cannot be read.
fn pruneStaleIn(io: std.Io, gpa: std.mem.Allocator, o: std.Io.Dir, name: []const u8, served: std.Io.File) ?Pruned {
    const served_size = (served.stat(io) catch return null).size;

    var stale: std.ArrayList([]const u8) = .empty;
    defer {
        for (stale.items) |s| gpa.free(s);
        stale.deinit(gpa);
    }
    var freed: u64 = 0;
    var it = o.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        var sub = o.openDir(io, entry.name, .{}) catch continue;
        defer sub.close(io);
        const st = sub.statFile(io, name, .{}) catch continue;
        if (st.kind != .file) continue;
        if (st.size == served_size and sameBytes(io, sub, name, served)) continue;
        const kept = gpa.dupe(u8, entry.name) catch continue;
        stale.append(gpa, kept) catch {
            gpa.free(kept);
            continue;
        };
        freed += st.size;
    }
    // Deleted after the walk rather than during it, so the iterator never
    // reads a directory being removed from under it.
    for (stale.items) |dir_name| o.deleteTree(io, dir_name) catch {};
    return .{ .dirs = stale.items.len, .bytes = freed };
}

/// Whether the file `name` under `dir` is byte for byte `served`.
fn sameBytes(io: std.Io, dir: std.Io.Dir, name: []const u8, served: std.Io.File) bool {
    const candidate = dir.openFile(io, name, .{}) catch return false;
    defer candidate.close(io);
    var a: [64 * 1024]u8 = undefined;
    var b: [64 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const na = candidate.readPositionalAll(io, &a, offset) catch return false;
        const nb = served.readPositionalAll(io, &b, offset) catch return false;
        if (na != nb or !std.mem.eql(u8, a[0..na], b[0..nb])) return false;
        if (na == 0) return true;
        offset += na;
    }
}

/// The nearest directory at or above the working directory holding a
/// `build.zig`, which is what `zig build` runs from and where `.zig-cache`
/// is. Null when there is none, in which case nothing is pruned.
fn buildRoot(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const n = std.process.currentPath(io, buf) catch return null;
    var dir: []const u8 = buf[0..n];
    while (true) {
        var probe: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&probe, "{s}/build.zig", .{dir}) catch return null;
        if (std.Io.Dir.cwd().access(io, p, .{})) |_| return dir else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len == dir.len) return null;
        dir = parent;
    }
}

fn stamp(io: std.Io, path: []const u8) ?Stamp {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
}

fn now(io: std.Io) u64 {
    const t = std.Io.Timestamp.now(io, .awake);
    return @intCast(@max(t.nanoseconds, 0));
}

fn sleep(io: std.Io, ms: u64) void {
    io.sleep(.fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("nilo-dev: " ++ fmt ++ "\n", args);
}

fn termText(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) "exit 0" else "a non-zero exit",
        .signal => "a signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

/// The argv as one line, for the first message.
fn joined(arena: std.mem.Allocator, argv: []const []const u8) []const u8 {
    return std.mem.join(arena, " ", argv) catch "zig build";
}

// ---- tests ----

const testing = std.testing;

/// The argument list as `main` receives it, for the parser alone.
fn argsOf(comptime list: []const [:0]const u8) std.process.Args {
    comptime var vector: [list.len][*:0]const u8 = undefined;
    inline for (list, 0..) |arg, i| vector[i] = arg.ptr;
    const held = vector;
    return .{ .vector = &held };
}

test "the exe is the one bare argument, and everything after -- is the server's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const opts = parse(arena.allocator(), argsOf(&.{ "nilo-dev", "zig-out/bin/app", "--", "--port", "9000" })).?;
    try testing.expectEqualStrings("zig-out/bin/app", opts.exe);
    try testing.expectEqualStrings("zig", opts.zig);
    try testing.expectEqualStrings("install", opts.step);
    try testing.expect(opts.incremental);
    try testing.expectEqual(@as(usize, 2), opts.server_args.len);
    try testing.expectEqualStrings("--port", opts.server_args[0]);
    try testing.expectEqualStrings("9000", opts.server_args[1]);
}

test "the flags name the zig, the step, the incremental mode, and -D options go to the build" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const opts = parse(arena.allocator(), argsOf(&.{
        "nilo-dev",         "--zig",  "/opt/zig/zig",  "--build",                   "example-hello",
        "--no-incremental", "-Dllvm", "-Dstrip=false", "zig-out/bin/example-hello",
    })).?;
    try testing.expectEqualStrings("/opt/zig/zig", opts.zig);
    try testing.expectEqualStrings("example-hello", opts.step);
    try testing.expect(!opts.incremental);
    try testing.expectEqual(@as(usize, 2), opts.build_options.len);
    try testing.expectEqualStrings("-Dllvm", opts.build_options[0]);
    try testing.expectEqualStrings("-Dstrip=false", opts.build_options[1]);
    try testing.expectEqualStrings("zig-out/bin/example-hello", opts.exe);
}

test "--incremental, the flag from when it was opt-in, still parses and changes nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const opts = parse(arena.allocator(), argsOf(&.{ "nilo-dev", "--incremental", "zig-out/bin/app" })).?;
    try testing.expect(opts.incremental);
}

test "no exe, two exes, a flag with no value, or a flag nobody knows is usage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(parse(a, argsOf(&.{"nilo-dev"})) == null);
    try testing.expect(parse(a, argsOf(&.{ "nilo-dev", "a", "b" })) == null);
    try testing.expect(parse(a, argsOf(&.{ "nilo-dev", "--zig" })) == null);
    try testing.expect(parse(a, argsOf(&.{ "nilo-dev", "--watch", "src", "a" })) == null);
}

test "pruning deletes the build directories holding another version of the binary, and nothing else" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const d = tmp.dir;
    // What zig-out holds, and three cache directories: the same bytes, a
    // stale build, and one that built something else entirely.
    try d.writeFile(io, .{ .sub_path = "app", .data = "the served binary" });
    try d.createDirPath(io, "o/aaaa");
    try d.createDirPath(io, "o/bbbb");
    try d.createDirPath(io, "o/cccc");
    try d.writeFile(io, .{ .sub_path = "o/aaaa/app", .data = "the served binary" });
    try d.writeFile(io, .{ .sub_path = "o/bbbb/app", .data = "an older binary!!" }); // same length, other bytes
    try d.writeFile(io, .{ .sub_path = "o/bbbb/app_zcu.o", .data = "and its object" });
    try d.writeFile(io, .{ .sub_path = "o/cccc/other", .data = "somebody else's build" });

    const served = try d.openFile(io, "app", .{});
    defer served.close(io);
    var o = try d.openDir(io, "o", .{ .iterate = true });
    defer o.close(io);
    const pruned = pruneStaleIn(io, testing.allocator, o, "app", served).?;
    try testing.expectEqual(@as(usize, 1), pruned.dirs);
    try testing.expectEqual(@as(u64, "an older binary!!".len), pruned.bytes);

    try d.access(io, "o/aaaa/app", .{});
    try d.access(io, "o/cccc/other", .{});
    try testing.expectError(error.FileNotFound, d.access(io, "o/bbbb", .{}));
}

test "a stamp moves when either the size or the mtime does" {
    const a: Stamp = .{ .size = 10, .mtime_ns = 100 };
    try testing.expect(a.eql(.{ .size = 10, .mtime_ns = 100 }));
    try testing.expect(!a.eql(.{ .size = 11, .mtime_ns = 100 }));
    try testing.expect(!a.eql(.{ .size = 10, .mtime_ns = 101 }));
}
