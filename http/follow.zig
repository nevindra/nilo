//! A static directory that follows the disk (ADR 277).
//!
//! `app.staticWith(prefix, dir, .{ .follow = true })` keeps the files in
//! memory, as every static directory does (ADR 009), and keeps them in step
//! with the directory while the server runs: replace a file, or the `.br`
//! and `.gz` beside it, add a file, remove one, and the next response says
//! so. A request pays two atomic operations for it and allocates nothing; the
//! work is on one thread that is not an executor and holds nothing a
//! connection needs.
//!
//! **A directory is replaced as a whole, never edited.** The thread notices
//! a change (`inotify` on Linux, where a change is seen in tens of
//! milliseconds; a walk and a `stat` of every file each `follow_poll_ms`
//! everywhere else, and as the backstop where `inotify` has nothing to say, a
//! network or FUSE mount), waits for the directory to hold still, runs the
//! same `static.load` the server started with into a new generation, and swaps
//! the pointer requests read. Every file a request looks at, and its ETag,
//! its chain and its bytes, belong to one generation, so a request cannot see
//! a file half replaced, a `.br` from one write beside a file from another,
//! or a URL list that is neither the old one nor the new.
//!
//! **A response that began on a generation finishes on it.** Each generation
//! counts the responses reading from it (`Lease`); a request takes one before
//! it trusts what it found, and gives it back when it is done, which for an
//! HTTP/2 stream is when the stream is let go of. The thread frees a retired
//! generation when it is at zero and not before, so a slow client holding a
//! 200 KB body keeps the generation it is reading and nothing else.
//!
//! **The count is taken with the check that makes it safe.** A request reads
//! which generation is live, adds one to its count, and reads which is live
//! again: if it changed, it gives the count back and starts over, and it has
//! read nothing of the generation it let go of. The thread publishes the new
//! generation and only then looks at the old one's count, so a request either
//! is counted before it looks (the generation waits for it) or sees the new
//! generation (and never touches the old one). That argument needs the
//! counts and the pointer to be sequentially consistent, and the generation's
//! header (the count itself) to stay allocated after the generation is freed,
//! because a request that lost the race adds one to a header that is already
//! retired. Headers are therefore kept and reused, never given back, and a
//! header's count is never reset, only added to and taken from.
//!
//! **The chains of a generation have one owner at a time.** `attach` replaces
//! the live generation's chains and the hooks they are made with, which the
//! test client does before every request while the thread is running, and the
//! thread makes a generation's chains, swaps it in and frees retired ones.
//! `chain_guard` is held across each of those, so a chain is freed once and
//! never into a generation that has been given back. A request never takes it.

const std = @import("std");
const builtin = @import("builtin");

const static_mod = @import("static.zig");
const bulkhead = @import("bulkhead.zig");
const lease_mod = @import("lease.zig");

pub const Lease = lease_mod.Lease;

/// One loaded state of a followed directory: what `static.load` made, and the
/// middleware chain of each file in it.
pub const Gen = struct {
    /// Counted by the responses reading from this generation. Kept for as long
    /// as the follower is: see the header.
    lease: Lease = .{},
    set: static_mod.Set,
    /// One for each file of `set`, in its order, resolved when the generation
    /// was made (the same lists `listen()` resolves for a directory that does
    /// not follow). Empty without a host to resolve them.
    chains: Chains = &.{},
    /// The retired list and the spare list, which only the thread that swaps
    /// generations reads.
    link: ?*Gen = null,
    /// Every header ever made, for `destroy`.
    all: ?*Gen = null,
};

/// What the follower needs of the App that holds it, as function pointers so
/// that this file does not import it: the chains of a generation's files, and
/// giving them back.
pub const Hooks = struct {
    host: *anyopaque,
    chains: *const fn (host: *anyopaque, set: *const static_mod.Set) anyerror!Chains,
    free: *const fn (host: *anyopaque, chains: Chains) void,
};

/// A file found for a request, and the generation that holds it. The caller
/// owns one count on `gen.lease` and gives it back with `release`.
pub const Found = struct {
    gen: *Gen,
    file: *const static_mod.File,

    pub fn chain(self: Found) []const Link {
        const at = self.gen.set.indexOf(self.file);
        return if (at < self.gen.chains.len) self.gen.chains[at] else &.{};
    }
};

/// One middleware, with its type taken out: `middleware.zig` is in the App's
/// core and this file is not allowed to name it (build.zig, `http_core`), so
/// the code that owns the type casts the chains to and from this.
pub const Link = *const anyopaque;
/// The chains of one generation's files, one entry a file in `Set.files`.
pub const Chains = []const []const Link;

/// How long a change has to hold still before it is loaded, and the longest
/// that is waited for: a file being written (a copy, a build) is not read
/// until its size and modification time stop moving, and a file that never
/// stops is read when the longest has passed and again when it does.
const settle_ms = 60;
const settle_longest_ms = 1000;
/// The slice the thread waits in, which is also how long `halt` can take.
const slice_ms = 50;

pub const Follower = struct {
    gpa: std.mem.Allocator,
    /// The generation requests read. Never null once created.
    live: std.atomic.Value(?*Gen),
    /// Generations that were replaced and may still be read from.
    retired: ?*Gen = null,
    /// Headers of freed generations, waiting to be made again.
    spare: ?*Gen = null,
    all: ?*Gen = null,
    prefix: []u8,
    dir_path: []u8,
    options: static_mod.Options,
    hooks: ?Hooks = null,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// Generations published after the first, and generations freed, for a
    /// test to wait on.
    swaps: std.atomic.Value(u32) = .init(0),
    freed: std.atomic.Value(u32) = .init(0),
    /// The fingerprint a load failed on, so the same tree is not read over and
    /// over to fail the same way.
    failed: u64 = 0,
    /// Whether the last walk could not be made, so it is said once.
    unreadable: bool = false,
    /// Held by whoever changes a generation's chains or the hooks they are
    /// made with: `attach` (the test client calls it before every request,
    /// with the thread running), the thread making a generation and swapping
    /// it in, and the thread freeing one. Never held across a wait, and never
    /// by a request.
    chain_guard: std.atomic.Value(bool) = .init(false),

    /// Take over `first`, the directory as `load` read it at startup.
    pub fn create(
        gpa: std.mem.Allocator,
        first: static_mod.Set,
        prefix: []const u8,
        dir_path: []const u8,
        options: static_mod.Options,
    ) !*Follower {
        const self = try gpa.create(Follower);
        errdefer gpa.destroy(self);
        const owned_prefix = try gpa.dupe(u8, prefix);
        errdefer gpa.free(owned_prefix);
        const owned_dir = try gpa.dupe(u8, dir_path);
        errdefer gpa.free(owned_dir);
        self.* = .{
            .gpa = gpa,
            .live = .init(null),
            .prefix = owned_prefix,
            .dir_path = owned_dir,
            .options = options,
        };
        self.options.follow_poll_ms = @max(options.follow_poll_ms, 100);
        const gen = try self.makeGen(first);
        self.live.store(gen, .seq_cst);
        return self;
    }

    /// Stop the thread and give back everything, the live generation and every
    /// retired one. Nothing can be reading any more: the server has stopped.
    pub fn destroy(self: *Follower) void {
        self.halt();
        const gpa = self.gpa;
        if (self.live.swap(null, .seq_cst)) |g| self.dispose(g);
        while (self.retired) |g| {
            self.retired = g.link;
            self.dispose(g);
        }
        var next = self.all;
        while (next) |g| {
            next = g.all;
            gpa.destroy(g);
        }
        gpa.free(self.prefix);
        gpa.free(self.dir_path);
        gpa.destroy(self);
    }

    /// The chains of the live generation's files, worked out with `hooks`, and
    /// the hooks the thread uses for the generations it makes. Called by
    /// `listen()` where it resolves every other chain, and again if it runs
    /// again.
    pub fn attach(self: *Follower, hooks: Hooks) !void {
        self.lockChains();
        defer self.unlockChains();
        const gen = self.live.load(.seq_cst).?;
        const chains = try hooks.chains(hooks.host, &gen.set);
        if (self.hooks) |old| old.free(old.host, gen.chains);
        self.hooks = hooks;
        gen.chains = chains;
    }

    /// Start the thread that watches the directory. Nothing happens before
    /// this, so a program that builds an App and never listens (a test, the
    /// generator of the API document) has no thread.
    pub fn start(self: *Follower) !void {
        if (self.thread != null) return;
        self.stop.store(false, .release);
        self.thread = try std.Thread.spawn(.{ .stack_size = 16 << 20 }, run, .{self});
    }

    pub fn halt(self: *Follower) void {
        const thread = self.thread orelse return;
        self.stop.store(true, .release);
        thread.join();
        self.thread = null;
    }

    /// Whether `path` is under the prefix files are served from, which is the
    /// same for every generation.
    pub fn under(self: *const Follower, path: []const u8) bool {
        return static_mod.underPrefix(self.prefix, path);
    }

    /// The generation to read from: counted before it is trusted (see the
    /// header). The count is the caller's until `Lease.release`.
    fn enter(self: *Follower) *Gen {
        while (true) {
            const gen = self.live.load(.seq_cst).?;
            gen.lease.retain();
            if (self.live.load(.seq_cst) == gen) return gen;
            gen.lease.release();
        }
    }

    /// The file `path` names, with the count that keeps its generation alive,
    /// or null with nothing counted.
    pub fn acquire(self: *Follower, path: []const u8) ?Found {
        const gen = self.enter();
        if (gen.set.find(path)) |file| return .{ .gen = gen, .file = file };
        gen.lease.release();
        return null;
    }

    /// The page the single-page fallback answers `path` with, counted the same
    /// way.
    pub fn acquireFallback(self: *Follower, path: []const u8, asked: static_mod.Asked) ?Found {
        const gen = self.enter();
        if (gen.set.fallbackFor(path, asked)) |file| return .{ .gen = gen, .file = file };
        gen.lease.release();
        return null;
    }

    // ---- the thread's side ----

    /// A spin, because what it guards is a few allocations and frees and the
    /// critical sections are never long (`std.Io.Mutex` would need an `Io`
    /// from a caller that has none).
    fn lockChains(self: *Follower) void {
        while (self.chain_guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlockChains(self: *Follower) void {
        self.chain_guard.store(false, .release);
    }

    fn makeGen(self: *Follower, set: static_mod.Set) !*Gen {
        var chains: Chains = &.{};
        if (self.hooks) |h| chains = try h.chains(h.host, &set);
        errdefer if (self.hooks) |h| h.free(h.host, chains);
        const gen = if (self.spare) |header| blk: {
            self.spare = header.link;
            break :blk header;
        } else blk: {
            const header = try self.gpa.create(Gen);
            // Only the parts that are not the count: a retired header's count
            // may still have a request adding to it, and taking from it.
            header.lease = .{};
            header.all = self.all;
            self.all = header;
            break :blk header;
        };
        gen.set = set;
        gen.chains = chains;
        gen.link = null;
        return gen;
    }

    /// Free a generation's contents and keep its header.
    fn dispose(self: *Follower, gen: *Gen) void {
        if (self.hooks) |h| h.free(h.host, gen.chains);
        gen.chains = &.{};
        gen.set.deinit();
        gen.link = self.spare;
        self.spare = gen;
        _ = self.freed.fetchAdd(1, .release);
    }

    /// Free every retired generation nothing is reading from. The headers'
    /// counts are looked at only after the swap that retired them was made
    /// (see the header).
    fn reap(self: *Follower) void {
        self.lockChains();
        defer self.unlockChains();
        var link = &self.retired;
        while (link.*) |gen| {
            if (gen.lease.held() == 0) {
                link.* = gen.link;
                self.dispose(gen);
            } else link = &gen.link;
        }
    }

    fn publish(self: *Follower, set: static_mod.Set) !void {
        {
            // From the chains being made to the swap, so an `attach` lands on
            // the generation that is live and not on the one being replaced.
            self.lockChains();
            defer self.unlockChains();
            const gen = try self.makeGen(set);
            const old = self.live.swap(gen, .seq_cst).?;
            old.link = self.retired;
            self.retired = old;
            _ = self.swaps.fetchAdd(1, .release);
        }
        self.reap();
    }

    fn run(self: *Follower) void {
        static_mod.reloading = true;
        var threaded: std.Io.Threaded = .init(self.gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();

        // Without a notifier the walk each `follow_poll_ms` is all there is,
        // and so it is when the first arming finds nothing to watch.
        var notifier = Notifier.open();
        defer if (notifier) |*n| n.close();
        var armed = false;
        if (notifier) |*n| armed = n.arm(io, self.gpa, self.dir_path, self.options.dotfiles) > 0;
        if (!armed) if (notifier) |*n| {
            n.close();
            notifier = null;
        };

        const poll_ns = @as(u64, self.options.follow_poll_ms) * std.time.ns_per_ms;
        var next_sweep = bulkhead.monotonicNanos() + poll_ns;
        while (!self.stop.load(.acquire)) {
            var changed = false;
            if (notifier) |*n| {
                switch (n.wait(slice_ms)) {
                    .quiet => {},
                    .changed => changed = true,
                    .rearm => {
                        changed = true;
                        armed = false;
                    },
                }
            } else pause(io, slice_ms);
            if (self.retired != null) self.reap();
            const now = bulkhead.monotonicNanos();
            if (changed or now >= next_sweep) {
                self.reconcile(io);
                next_sweep = bulkhead.monotonicNanos() + poll_ns;
                // After the walk and not before it, so a directory made while
                // it ran is in what it found. A directory that is gone has
                // nothing to watch until it is back, which a later walk finds.
                if (notifier) |*n| {
                    if (!armed) armed = n.arm(io, self.gpa, self.dir_path, self.options.dotfiles) > 0;
                    // What the walk itself was told about, so one change is
                    // not looked at twice.
                    if (n.wait(0) == .rearm) armed = false;
                }
            }
        }
    }

    /// Look at the directory and, if it is not what the live generation was
    /// read from, read it again.
    fn reconcile(self: *Follower, io: std.Io) void {
        const live_print = self.live.load(.monotonic).?.set.fingerprint;
        var print = static_mod.scan(io, self.gpa, self.dir_path, self.options) catch |err| {
            if (!self.unreadable) std.log.warn(
                "nilo: static directory \"{s}\" cannot be read ({s}), so the files already held go on being served until it can",
                .{ self.dir_path, @errorName(err) },
            );
            self.unreadable = true;
            return;
        };
        self.unreadable = false;
        if (print == live_print) return;

        // Changing: wait until it holds still, so a file being written is read
        // once it is written and not at every size on the way.
        var waited: u32 = 0;
        while (waited < settle_longest_ms and !self.stop.load(.acquire)) {
            pause(io, settle_ms);
            waited += settle_ms;
            const again = static_mod.scan(io, self.gpa, self.dir_path, self.options) catch return;
            if (again == print) break;
            print = again;
        }
        if (print == live_print or print == self.failed) return;

        const set = static_mod.loadOn(io, self.gpa, self.prefix, self.dir_path, self.options, .reported) catch |err| {
            self.failed = print;
            std.log.warn(
                "nilo: static directory \"{s}\" changed and could not be loaded ({s}), so the files already held go on being served",
                .{ self.dir_path, @errorName(err) },
            );
            return;
        };
        self.publish(set) catch |err| {
            var gone = set;
            gone.deinit();
            self.failed = print;
            std.log.warn(
                "nilo: static directory \"{s}\" changed and could not be swapped in ({s}), so the files already held go on being served",
                .{ self.dir_path, @errorName(err) },
            );
            return;
        };
        self.failed = 0;
    }
};

fn pause(io: std.Io, ms: u32) void {
    std.Io.sleep(io, .fromMilliseconds(ms), .awake) catch {};
}

/// What the operating system says about a directory changing, where it says
/// it. `null` from `open` is the walk each `follow_poll_ms` and nothing else.
const Notifier = if (builtin.os.tag == .linux) struct {
    fd: i32,

    const linux = std.os.linux;
    const Verdict = enum { quiet, changed, rearm };

    /// A name made, one removed, a file closed after a write or renamed in or
    /// out, its modification time touched, and the directory itself going.
    const mask: u32 = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.MOVED_FROM |
        linux.IN.CREATE | linux.IN.DELETE | linux.IN.ATTRIB | linux.IN.MODIFY |
        linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR;

    fn open() ?@This() {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .fd = @intCast(rc) };
    }

    fn close(self: *@This()) void {
        _ = linux.close(self.fd);
    }

    /// A watch on the directory and on every directory under it that the
    /// walk would enter. Adding one the descriptor already has is a no-op, so
    /// this is the whole of re-arming. How many were added or already there.
    fn arm(self: *@This(), io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, dotfiles: bool) usize {
        var added: usize = 0;
        if (self.watch(dir_path)) added += 1;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return added;
        defer dir.close(io);
        var walker = dir.walk(gpa) catch return added;
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (!dotfiles and static_mod.hasDotSegment(entry.path)) continue;
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, entry.path }) catch continue;
            if (self.watch(full)) added += 1;
        }
        return added;
    }

    fn watch(self: *@This(), path: []const u8) bool {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
        if (path.len >= buf.len) return false;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return linux.errno(linux.inotify_add_watch(self.fd, @ptrCast(&buf), mask)) == .SUCCESS;
    }

    /// Wait up to `ms` for something to change, and read everything that is
    /// waiting. `rearm` is a directory made, moved or gone, or events lost.
    fn wait(self: *@This(), ms: i32) Verdict {
        var fds = [1]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, ms);
        if (linux.errno(ready) != .SUCCESS or ready == 0) return .quiet;
        var verdict: Verdict = .quiet;
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = linux.read(self.fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var at: usize = 0;
            while (at + @sizeOf(linux.inotify_event) <= n) {
                const event: *const linux.inotify_event = @ptrCast(@alignCast(&buf[at]));
                at += @sizeOf(linux.inotify_event) + event.len;
                if (verdict == .quiet) verdict = .changed;
                const new_dir = event.mask & linux.IN.ISDIR != 0 and
                    event.mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0;
                if (new_dir or event.mask & (linux.IN.Q_OVERFLOW | linux.IN.IGNORED | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0)
                    verdict = .rearm;
            }
        }
        return verdict;
    }
} else struct {
    const Verdict = enum { quiet, changed, rearm };
    fn open() ?@This() {
        return null;
    }
    fn close(_: *@This()) void {}
    fn arm(_: *@This(), _: std.Io, _: std.mem.Allocator, _: []const u8, _: bool) usize {
        return 0;
    }
    fn wait(_: *@This(), _: i32) Verdict {
        return .quiet;
    }
};

// ---- tests ----

// The first test sits above the imports of the others because an import
// below a file's first `test` is a test's, which is how this file may name
// `testing.zig` without joining the App's core (build.zig, `http_core`).
test "a file replaced in the directory is served new within a bound, by a rename and in place" {
    const gpa = testing.allocator;
    const one = filled(2000, 'a');
    const two = filled(2000, 'b');
    const three = filled(2000, 'c');
    var fx = try Fixture.init(gpa, &.{.{ "page.html", &one }});
    defer fx.deinit(gpa);

    var first = (try seen(fx.follower, gpa, "/page.html")).?;
    defer first.free(gpa);
    try testing.expectEqualSlices(u8, &one, first.bytes);

    // Same length and different bytes, replaced by a rename, as the board's
    // probe does it: a cache keyed on the size would never see it.
    try fx.replace("page.html", &two);
    try waitForBytes(fx.follower, gpa, "/page.html", &two);

    // And in place, the way an editor writes.
    try fx.write("page.html", &three);
    try waitForBytes(fx.follower, gpa, "/page.html", &three);
    try testing.expect(fx.follower.swaps.load(.acquire) >= 2);
}

const testing = std.testing;
const nilo_testing = @import("testing.zig");
const compress_mod = @import("compress.zig");

const test_options: static_mod.Options = .{ .follow = true, .follow_poll_ms = 100 };

/// A directory on disk for one test, a follower over it, and the means to
/// change the directory the way a deploy, a build and a person with an editor
/// each do.
const Fixture = struct {
    tmp: nilo_testing.TmpDir,
    path: [:0]u8,
    follower: *Follower,

    fn init(gpa: std.mem.Allocator, files: []const [2][]const u8) !Fixture {
        return initIn(gpa, "", files);
    }

    /// The directory served is `under` inside the temporary one, so a test can
    /// remove it and make it again.
    fn initIn(gpa: std.mem.Allocator, under: []const u8, files: []const [2][]const u8) !Fixture {
        var tmp = nilo_testing.tmpDir();
        errdefer tmp.cleanup();
        if (under.len > 0) try tmp.dir.createDirPath(testing.io, under);
        for (files) |entry| try tmp.dir.writeFile(testing.io, .{ .sub_path = entry[0], .data = entry[1] });
        const path = try tmp.pathAlloc(gpa, under);
        errdefer gpa.free(path);
        const first = try static_mod.load(gpa, "/", path, test_options, .returned);
        const follower = try Follower.create(gpa, first, "/", path, test_options);
        errdefer follower.destroy();
        try follower.start();
        return .{ .tmp = tmp, .path = path, .follower = follower };
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        self.follower.destroy();
        gpa.free(self.path);
        self.tmp.cleanup();
    }

    /// Written in place, which is what an editor and `cp` do: the file is
    /// truncated and then filled, and a reader may meet it half written.
    fn write(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = bytes });
    }

    /// Written whole beside the name and renamed over it, which is what a
    /// deploy tool and `mv` do (and the board's staleness probe).
    fn replace(self: *Fixture, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "replacement.tmp", .data = bytes });
        try self.tmp.dir.rename("replacement.tmp", self.tmp.dir, name, testing.io);
    }

    fn remove(self: *Fixture, name: []const u8) !void {
        try self.tmp.dir.deleteFile(testing.io, name);
    }
};

/// What a request would have been answered with for `url`: the plain bytes and
/// the forms, copied out so that nothing is held.
const Seen = struct {
    bytes: []u8,
    br: ?[]u8,
    gz: ?[]u8,

    fn free(self: Seen, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        if (self.br) |b| gpa.free(b);
        if (self.gz) |g| gpa.free(g);
    }
};

fn seen(follower: *Follower, gpa: std.mem.Allocator, url: []const u8) !?Seen {
    const found = follower.acquire(url) orelse return null;
    defer found.gen.lease.release();
    const held = found.file.contents.held;
    const bytes = try gpa.dupe(u8, held.bytes);
    errdefer gpa.free(bytes);
    const br = if (held.br) |b| try gpa.dupe(u8, b) else null;
    errdefer if (br) |b| gpa.free(b);
    const gz = if (held.gzip) |g| try gpa.dupe(u8, g) else null;
    return .{ .bytes = bytes, .br = br, .gz = gz };
}

/// The longest any test below waits for the thread to notice a change. A
/// change is seen in a few hundred milliseconds, and the board's own window is
/// two seconds; this is the bound a failure gives up at, and nothing waits for
/// it in a run that passes.
const wait_ms = 5000;

fn nap() void {
    std.Io.sleep(testing.io, .fromMilliseconds(20), .awake) catch {};
}

fn elapsedMs(since: u64) u64 {
    return (bulkhead.monotonicNanos() - since) / std.time.ns_per_ms;
}

/// Wait until `url` is answered with exactly `want`, or is not found when
/// `want` is null.
fn waitForBytes(follower: *Follower, gpa: std.mem.Allocator, url: []const u8, want: ?[]const u8) !void {
    const since = bulkhead.monotonicNanos();
    while (elapsedMs(since) < wait_ms) : (nap()) {
        const now = try seen(follower, gpa, url);
        defer if (now) |s| s.free(gpa);
        if (want) |bytes| {
            if (now) |s| if (std.mem.eql(u8, s.bytes, bytes)) return;
        } else if (now == null) return;
    }
    return error.NeverFollowed;
}

fn filled(comptime len: usize, byte: u8) [len]u8 {
    return @splat(byte);
}

test "the forms beside a file follow it, whichever of them is written first" {
    const gpa = testing.allocator;
    const one = filled(3000, 'a');
    const two = filled(3000, 'b');
    const one_br = filled(300, '1');
    const two_br = filled(300, '2');
    const one_gz = (try compress_mod.gzipOnce(gpa, &one)).?;
    defer gpa.free(one_gz);
    const two_gz = (try compress_mod.gzipOnce(gpa, &two)).?;
    defer gpa.free(two_gz);

    var fx = try Fixture.init(gpa, &.{
        .{ "app.js", &one },
        .{ "app.js.br", &one_br },
        .{ "app.js.gz", one_gz },
    });
    defer fx.deinit(gpa);

    var before = (try seen(fx.follower, gpa, "/app.js")).?;
    defer before.free(gpa);
    try testing.expectEqualSlices(u8, &one_br, before.br.?);
    try testing.expectEqualSlices(u8, one_gz, before.gz.?);
    // The forms are not files of their own.
    try testing.expect(try seen(fx.follower, gpa, "/app.js.br") == null);

    // The `.gz` first, so it is older than the file it belongs to; the file
    // next; the `.br` last, as a build writes them. A `.gz` is held to what
    // its trailer says and not to its age, and every state in between has a
    // gzip that is the file's or none, never a stale one beside new bytes.
    try fx.replace("app.js.gz", two_gz);
    try fx.replace("app.js", &two);
    try fx.replace("app.js.br", &two_br);

    const since = bulkhead.monotonicNanos();
    while (elapsedMs(since) < wait_ms) : (nap()) {
        const now = (try seen(fx.follower, gpa, "/app.js")) orelse return error.Vanished;
        defer now.free(gpa);
        if (now.gz) |gz| try testing.expect(static_mod.gzipMatches(gz, now.bytes));
        const settled = std.mem.eql(u8, now.bytes, &two) and
            now.br != null and std.mem.eql(u8, now.br.?, &two_br) and
            now.gz != null and std.mem.eql(u8, now.gz.?, two_gz);
        if (settled) return;
    }
    return error.NeverFollowed;
}

test "a file added is served and a file removed is gone, and a new directory is watched" {
    const gpa = testing.allocator;
    const page = filled(100, 'p');
    const gone = filled(100, 'g');
    const fresh = filled(100, 'f');
    const deep = filled(100, 'd');
    var fx = try Fixture.init(gpa, &.{ .{ "page.txt", &page }, .{ "gone.txt", &gone } });
    defer fx.deinit(gpa);

    try fx.write("fresh.txt", &fresh);
    try waitForBytes(fx.follower, gpa, "/fresh.txt", &fresh);
    try fx.remove("gone.txt");
    try waitForBytes(fx.follower, gpa, "/gone.txt", null);
    // The rest is untouched, and still there.
    try waitForBytes(fx.follower, gpa, "/page.txt", &page);

    // A directory made after the thread started, and a file written into it
    // after that: the second change is heard through a watch the new
    // directory was given.
    try fx.tmp.dir.createDirPath(testing.io, "assets/css");
    try fx.write("assets/css/site.css", &deep);
    try waitForBytes(fx.follower, gpa, "/assets/css/site.css", &deep);
    const more = filled(100, 'm');
    try fx.write("assets/css/site.css", &more);
    try waitForBytes(fx.follower, gpa, "/assets/css/site.css", &more);
}

test "a response that began on a generation finishes on it, and the generation is freed after" {
    const gpa = testing.allocator;
    const one = filled(2000, 'a');
    const two = filled(2000, 'b');
    var fx = try Fixture.init(gpa, &.{.{ "page.html", &one }});
    defer fx.deinit(gpa);

    // A request partway through its response: found, and not yet done.
    const reading = fx.follower.acquire("/page.html").?;
    try testing.expectEqual(@as(u32, 1), reading.gen.lease.held());

    try fx.replace("page.html", &two);
    try waitForBytes(fx.follower, gpa, "/page.html", &two);

    // What it is reading from has not changed under it, and has not been
    // freed, however many times the thread has looked since.
    try testing.expectEqualSlices(u8, &one, reading.file.contents.held.bytes);
    nap();
    nap();
    nap();
    nap();
    try testing.expectEqual(@as(u32, 0), fx.follower.freed.load(.acquire));
    try testing.expectEqualSlices(u8, &one, reading.file.contents.held.bytes);

    // Done, and the thread frees it at its next look.
    reading.gen.lease.release();
    const since = bulkhead.monotonicNanos();
    while (fx.follower.freed.load(.acquire) == 0) : (nap()) {
        if (elapsedMs(since) > wait_ms) return error.NeverFreed;
    }
}

const Torn = struct {
    follower: *Follower,
    done: std.atomic.Value(bool) = .init(false),
    reads: std.atomic.Value(u64) = .init(0),
    torn: std.atomic.Value(u64) = .init(0),
    missing: std.atomic.Value(u64) = .init(0),
    len: usize,

    fn read(self: *Torn) void {
        while (!self.done.load(.acquire)) {
            const found = self.follower.acquire("/page.txt") orelse {
                _ = self.missing.fetchAdd(1, .monotonic);
                continue;
            };
            const bytes = found.file.contents.held.bytes;
            // One version or the other, whole: all one letter, the right length.
            if (bytes.len != self.len or !std.mem.allEqual(u8, bytes, bytes[0]) or
                bytes[0] < 'a' or bytes[0] > 'z')
                _ = self.torn.fetchAdd(1, .monotonic);
            _ = self.reads.fetchAdd(1, .monotonic);
            found.gen.lease.release();
        }
    }
};

test "a reader never sees a file half replaced, however often it is replaced" {
    const gpa = testing.allocator;
    const first = filled(6000, 'a');
    var fx = try Fixture.init(gpa, &.{.{ "page.txt", &first }});
    defer fx.deinit(gpa);

    var torn: Torn = .{ .follower = fx.follower, .len = first.len };
    var readers: [4]std.Thread = undefined;
    for (&readers) |*t| t.* = try std.Thread.spawn(.{}, Torn.read, .{&torn});
    defer for (readers) |t| t.join();
    defer torn.done.store(true, .release);

    var letter: u8 = 'a';
    for (0..14) |_| {
        letter += 1;
        const bytes = filled(6000, letter);
        // In place: a reader of the directory could meet this half written, and
        // a reader of the server must not.
        try fx.write("page.txt", &bytes);
        const since = bulkhead.monotonicNanos();
        while (elapsedMs(since) < 140) nap();
    }
    const last = filled(6000, letter);
    try waitForBytes(fx.follower, gpa, "/page.txt", &last);

    try testing.expectEqual(@as(u64, 0), torn.torn.load(.acquire));
    try testing.expectEqual(@as(u64, 0), torn.missing.load(.acquire));
    try testing.expect(torn.reads.load(.acquire) > 0);
    try testing.expect(fx.follower.swaps.load(.acquire) >= 1);
}

test "a directory that goes away leaves the files held being served, and is followed again when it is back" {
    const gpa = testing.allocator;
    const page = filled(200, 'p');
    const again = filled(200, 'q');
    var fx = try Fixture.initIn(gpa, "site", &.{.{ "site/page.txt", &page }});
    defer fx.deinit(gpa);

    // Removed from under the server, which is said once and changes nothing
    // that is held: several looks later the file is still answered.
    try fx.tmp.dir.deleteTree(testing.io, "site");
    const since = bulkhead.monotonicNanos();
    while (elapsedMs(since) < 600) nap();
    try waitForBytes(fx.follower, gpa, "/page.txt", &page);
    try testing.expectEqual(@as(u32, 0), fx.follower.swaps.load(.acquire));

    // Back, with something else in it, and the watch is made again.
    try fx.tmp.dir.createDirPath(testing.io, "site");
    try fx.write("site/page.txt", &again);
    try waitForBytes(fx.follower, gpa, "/page.txt", &again);
    const changed = filled(200, 'r');
    try fx.write("site/page.txt", &changed);
    try waitForBytes(fx.follower, gpa, "/page.txt", &changed);
}

/// Chains for the test below: one empty chain a file, from the allocator the
/// host points at, so a chain freed twice or freed while it is set is caught
/// by the testing allocator.
fn testChains(host: *anyopaque, set: *const static_mod.Set) anyerror!Chains {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(host));
    const chains = try gpa.alloc([]const Link, set.files.len);
    @memset(chains, &.{});
    return chains;
}

fn testFree(host: *anyopaque, chains: Chains) void {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(host));
    if (chains.len > 0) gpa.free(chains);
}

fn attachOften(follower: *Follower, hooks: Hooks, times: u32, failed: *std.atomic.Value(bool)) void {
    var done: u32 = 0;
    while (done < times) : (done += 1) follower.attach(hooks) catch failed.store(true, .release);
}

test "attaching chains while the thread swaps generations frees every chain once" {
    // The test client resolves the chains before every request, and for a
    // followed directory that is `attach`, which replaces the live generation's
    // chains while the thread may be publishing and freeing generations. It
    // crashed the suite in `Allocator.free` now and then, under load.
    const gpa = testing.allocator;
    var fx = try Fixture.init(gpa, &.{ .{ "a.css", "a" }, .{ "b.css", "b" } });
    defer fx.deinit(gpa);
    // The swaps below are the test's, not the thread's.
    fx.follower.halt();

    var allocator = gpa;
    const hooks: Hooks = .{ .host = &allocator, .chains = testChains, .free = testFree };
    try fx.follower.attach(hooks);

    var failed: std.atomic.Value(bool) = .init(false);
    const attacher = try std.Thread.spawn(.{}, attachOften, .{ fx.follower, hooks, 3000, &failed });
    var swapped: u32 = 0;
    while (swapped < 300) : (swapped += 1) {
        const set = try static_mod.load(gpa, "/", fx.path, test_options, .returned);
        try fx.follower.publish(set);
    }
    attacher.join();
    try testing.expect(!failed.load(.acquire));
}
