//! Whether gzipping a body gets slower as more threads share the pool
//! (ADR 211).
//!
//! ```
//! zig build bench-compress-scale -Dtarget=x86_64-linux-gnu -Dlibdeflate -- /path/to/dataset.json
//! ```
//!
//! N threads, pinned to the logical cpus 0..N-1, each gzip the body of
//! `GET /json/{25,40,50}?m=4` (rendered from the board's dataset the way the
//! arena entry does) in a loop, in three arrangements:
//!
//! - `shared`: one pool of N slots, every thread calling `gzipAt` with no hint,
//!   which starts every scan at slot 0: what the pool did before ADR 211 was
//!   revised, and what a caller with no executor identity still does.
//! - `owned`: the same pool, every thread calling `gzipAt` with its own
//!   index, which is what `Pool.gzip` does under the engine (ADR 211).
//! - `private`: N pools of one slot, thread i using only pool i. A pool nobody
//!   else can touch: the floor, with nothing to share.
//!
//! The question is whether ns a body at 16 threads is more than at one, and
//! how much of it `owned` takes back. Counters are the calling thread's
//! user-space `perf_event_open` readings (there is no `perf` binary here):
//! instructions, last-level cache misses and L1 data cache read misses, a
//! body. Each thread times its own loop between a start barrier and its end,
//! and the table's ns is the mean over threads, because the slowest thread is
//! the one the others were waiting on only in a closed loop and a server has
//! none.
//!
//! `ReleaseFast` whatever was asked. Both backends when `-Dlibdeflate` is on.

const std = @import("std");
const linux = std.os.linux;
const nilo = @import("nilo_http");

const Rating = struct { score: i64, count: i64 };
const DatasetItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};
const JsonItem = struct {
    id: i64,
    name: []const u8,
    category: []const u8,
    price: i64,
    quantity: i64,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
    total: i64,
};

fn render(arena: std.mem.Allocator, data: []const DatasetItem, count: usize, m: i64) ![]const u8 {
    const take = @min(count, data.len);
    const out = try arena.alloc(JsonItem, take);
    for (data[0..take], out) |item, *listed| listed.* = .{
        .id = item.id,
        .name = item.name,
        .category = item.category,
        .price = item.price,
        .quantity = item.quantity,
        .active = item.active,
        .tags = item.tags,
        .rating = item.rating,
        .total = item.price * item.quantity * m,
    };
    var buf: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .items = out, .count = take }, .{}, &buf.writer);
    return buf.written();
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn openCounter(kind: linux.PERF.TYPE, config: u64) i32 {
    var attr: linux.perf_event_attr = .{
        .type = kind,
        .config = config,
        .flags = .{ .disabled = true, .exclude_kernel = true, .exclude_hv = true },
    };
    const rc = linux.perf_event_open(&attr, 0, -1, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return -1;
    return @intCast(rc);
}

fn l1dReadMiss() u64 {
    // PERF_COUNT_HW_CACHE_L1D | (OP_READ << 8) | (RESULT_MISS << 16)
    return 0 | (0 << 8) | (1 << 16);
}

fn readCounter(fd: i32) u64 {
    if (fd < 0) return 0;
    var v: u64 = 0;
    _ = linux.read(fd, @ptrCast(&v), 8);
    return v;
}

fn ctl(fd: i32, req: u32) void {
    if (fd >= 0) _ = linux.ioctl(fd, req, 0);
}

const Arrangement = enum { shared, owned, private };

const Worker = struct {
    index: usize,
    arrangement: Arrangement,
    pool: *anyopaque,
    bodies: []const []const u8,
    rounds: usize,
    gap_ns: u64,
    start: *std.atomic.Value(u32),
    ready: *std.atomic.Value(u32),
    which: nilo.compress.Backend,
    // out
    ns: u64 = 0,
    instr: u64 = 0,
    llc: u64 = 0,
    l1d: u64 = 0,
    bytes: usize = 0,
};

fn run(w: *Worker) void {
    switch (w.which) {
        .std => runWith(.std, w),
        .libdeflate => if (comptime nilo.compress.libdeflate_linked) runWith(.libdeflate, w) else unreachable,
    }
}

fn runWith(comptime which: nilo.compress.Backend, w: *Worker) void {
    const P = nilo.compress.PoolOf(which);
    const pool: *P = @ptrCast(@alignCast(w.pool));
    var set: linux.cpu_set_t = @splat(0);
    set[w.index / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(w.index % @bitSizeOf(usize));
    linux.sched_setaffinity(0, &set) catch {};

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const c_instr = openCounter(.HARDWARE, @intFromEnum(linux.PERF.COUNT.HW.INSTRUCTIONS));
    const c_llc = openCounter(.HARDWARE, @intFromEnum(linux.PERF.COUNT.HW.CACHE_MISSES));
    const c_l1d = openCounter(.HW_CACHE, l1dReadMiss());

    const one = struct {
        fn go(p: *P, arr: Arrangement, idx: usize, a: std.mem.Allocator, body: []const u8) usize {
            const out = switch (arr) {
                .shared => p.gzipAt(a, body, null),
                .owned => p.gzipAt(a, body, idx),
                .private => p.gzipAt(a, body, null),
            };
            return (out orelse return 0).len;
        }
    }.go;

    // Warm: every body once, so the slot's tables and the arena are resident.
    for (0..200) |i| {
        _ = one(pool, w.arrangement, w.index, arena.allocator(), w.bodies[i % w.bodies.len]);
        _ = arena.reset(.retain_capacity);
    }

    _ = w.ready.fetchAdd(1, .acq_rel);
    while (w.start.load(.acquire) == 0) std.atomic.spinLoopHint();

    ctl(c_instr, 0x2403);
    ctl(c_llc, 0x2403);
    ctl(c_l1d, 0x2403);
    ctl(c_instr, 0x2400);
    ctl(c_llc, 0x2400);
    ctl(c_l1d, 0x2400);
    const t0 = nowNs();
    var total: usize = 0;
    var inside: u64 = 0;
    for (0..w.rounds) |i| {
        if (w.gap_ns == 0) {
            total +%= one(pool, w.arrangement, w.index, arena.allocator(), w.bodies[i % w.bodies.len]);
            _ = arena.reset(.retain_capacity);
        } else {
            const a = nowNs();
            total +%= one(pool, w.arrangement, w.index, arena.allocator(), w.bodies[i % w.bodies.len]);
            const b = nowNs();
            inside += b - a;
            _ = arena.reset(.retain_capacity);
            // The rest of a request, so the slot is free for somebody else
            // while this thread is away from it.
            while (nowNs() - b < w.gap_ns) std.atomic.spinLoopHint();
        }
    }
    const t1 = nowNs();
    ctl(c_instr, 0x2401);
    ctl(c_llc, 0x2401);
    ctl(c_l1d, 0x2401);
    std.mem.doNotOptimizeAway(total);
    w.ns = if (w.gap_ns == 0) t1 - t0 else inside;
    w.instr = readCounter(c_instr);
    w.llc = readCounter(c_llc);
    w.l1d = readCounter(c_l1d);
    w.bytes = total / w.rounds;
    for ([_]i32{ c_instr, c_llc, c_l1d }) |fd| if (fd >= 0) {
        _ = linux.close(fd);
    };
}

fn measure(comptime which: nilo.compress.Backend, gpa: std.mem.Allocator, bodies: []const []const u8, n: usize, arrangement: Arrangement, rounds: usize, gap_ns: u64) !void {
    const P = nilo.compress.PoolOf(which);
    var shared_pool: P = undefined;
    var privates: []P = &.{};
    switch (arrangement) {
        .shared, .owned => shared_pool = try P.init(gpa, n, .{}),
        .private => {
            privates = try gpa.alloc(P, n);
            for (privates) |*p| p.* = try P.init(gpa, 1, .{});
        },
    }
    defer switch (arrangement) {
        .shared, .owned => shared_pool.deinit(gpa),
        .private => {
            for (privates) |*p| p.deinit(gpa);
            gpa.free(privates);
        },
    };

    var start: std.atomic.Value(u32) = .init(0);
    var ready: std.atomic.Value(u32) = .init(0);
    const workers = try gpa.alloc(Worker, n);
    defer gpa.free(workers);
    const threads = try gpa.alloc(std.Thread, n);
    defer gpa.free(threads);
    for (workers, 0..) |*w, i| {
        w.* = .{
            .index = i,
            .arrangement = arrangement,
            .pool = if (arrangement == .private) @ptrCast(&privates[i]) else @ptrCast(&shared_pool),
            .bodies = bodies,
            .rounds = rounds,
            .gap_ns = gap_ns,
            .start = &start,
            .ready = &ready,
            .which = which,
        };
        threads[i] = try std.Thread.spawn(.{}, run, .{w});
    }
    while (ready.load(.acquire) < n) std.atomic.spinLoopHint();
    start.store(1, .release);
    for (threads) |t| t.join();

    var ns: f64 = 0;
    var instr: f64 = 0;
    var llc: f64 = 0;
    var l1d: f64 = 0;
    for (workers) |w| {
        ns += @as(f64, @floatFromInt(w.ns)) / @as(f64, @floatFromInt(rounds));
        instr += @as(f64, @floatFromInt(w.instr)) / @as(f64, @floatFromInt(rounds));
        llc += @as(f64, @floatFromInt(w.llc)) / @as(f64, @floatFromInt(rounds));
        l1d += @as(f64, @floatFromInt(w.l1d)) / @as(f64, @floatFromInt(rounds));
    }
    const nf: f64 = @floatFromInt(n);
    std.debug.print("{s:>10} {s:>8} {d:>3} {d:>10.0} {d:>10.0} {d:>9.1} {d:>9.1} {d:>6}\n", .{
        @tagName(which), @tagName(arrangement), n, ns / nf, instr / nf, llc / nf, l1d / nf, workers[0].bytes,
    });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    const path = args.next() orelse return error.UsageDatasetPath;
    var rounds: usize = 20_000;
    var gap_ns: u64 = 0;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--rounds")) rounds = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
        if (std.mem.eql(u8, a, "--gap-ns")) gap_ns = try std.fmt.parseInt(u64, args.next() orelse return error.MissingValue, 10);
    }
    const gpa = std.heap.smp_allocator;

    var path_z: [512:0]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const rc = linux.open(&path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.CannotOpenDataset;
    const fd: i32 = @intCast(rc);
    const text = try gpa.alloc(u8, 1 << 20);
    const got = linux.read(fd, text.ptr, text.len);
    _ = linux.close(fd);
    const parsed = try std.json.parseFromSlice([]DatasetItem, gpa, text[0..got], .{ .allocate = .alloc_always, .ignore_unknown_fields = true });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();
    const bodies = [_][]const u8{
        try render(arena, parsed.value, 25, 4),
        try render(arena, parsed.value, 40, 4),
        try render(arena, parsed.value, 50, 4),
    };
    std.debug.print("bodies {d} {d} {d} bytes, {d} rounds a thread, {d} ns of other work between bodies (instr/body then includes it)\n", .{ bodies[0].len, bodies[1].len, bodies[2].len, rounds, gap_ns });
    std.debug.print("{s:>10} {s:>8} {s:>3} {s:>10} {s:>10} {s:>9} {s:>9} {s:>6}\n", .{ "backend", "mode", "N", "ns/body", "instr/body", "llc/body", "l1d/body", "out B" });

    const counts = [_]usize{ 1, 2, 4, 8, 16 };
    inline for (.{ nilo.compress.Backend.std, nilo.compress.Backend.libdeflate }) |which| {
        if (comptime (which == .std or nilo.compress.libdeflate_linked)) {
            for (counts) |n| {
                inline for (.{ Arrangement.shared, Arrangement.owned, Arrangement.private }) |arr| {
                    try measure(which, gpa, &bodies, n, arr, rounds, gap_ns);
                }
            }
        }
    }
}
