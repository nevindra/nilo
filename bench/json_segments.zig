//! Whether a JSON answer written into arena segments and sent in one
//! vectored write beats `std.Io.Writer.Allocating`, which is what `sendJson`
//! and a typed handler's answer use today (todo: "body written into arena
//! segments"). A measurement, not a feature: nothing in `http/` uses this.
//!
//! ```
//! taskset -c 5 zig build bench-json-segments -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast [-- --keep 65536]
//! ```
//!
//! **A** is `sendJson`'s writer: `Allocating.initCapacity(arena, json_hint)`
//! and `json.write`, so it grows by reallocating, and a grow past the end of
//! the arena's current block copies everything written so far. **B** and **C**
//! are `Segments`: a `std.Io.Writer` whose buffer is one segment, sealed when
//! it fills and replaced by a fresh one, so nothing already written is ever
//! copied. B starts at `json_hint` (512) and doubles to 4096, C is 4096
//! throughout. The segments are the iovecs of the one `writev` that also
//! carries the head.
//!
//! The arena is nilo's: a `std.heap.ArenaAllocator` over a counting
//! allocator, reset after every request keeping `default_arena_keep` (16 KiB),
//! so a 16 KiB answer that outgrows what is kept pays the backing allocator
//! again on every request, as it does in the server.
//!
//! Instructions are the user-space `INSTRUCTIONS` counter of this process
//! (`perf_event_open`, kernel excluded), because cachegrind is not installed
//! on the machine in `bench/result/http.md`; they are exact and repeat to
//! within a few hundred over a round. Two things are timed per size, each
//! round by round with the three variants interleaved: building the body
//! only, and building it and writing head plus body with one `writev` to
//! `/dev/null` (the syscall's entry and the iovec walk, none of a socket's
//! copying, which both sides pay for the same bytes).

const std = @import("std");
const json = @import("json");

/// What the arena keeps across requests; `--keep N` changes it. The default
/// is `default_arena_keep` of `http/app.zig`.
var arena_keep: usize = 16 * 1024;
const json_hint = 512;
const per_round = 5_000;
const rounds = 21;

// ---- the prototype ----

/// A writer whose buffer is a segment of the arena. `drain` seals the
/// segment that filled and hands the writer a new one; the sealed ones are
/// the answer, in order, and are never copied.
const Segments = struct {
    arena: std.mem.Allocator,
    first: usize,
    cap: usize,
    next_size: usize,
    list: std.ArrayList(std.posix.iovec_const),
    writer: std.Io.Writer,

    fn init(arena: std.mem.Allocator, first: usize, cap: usize) !*Segments {
        const self = try arena.create(Segments);
        self.* = .{
            .arena = arena,
            .first = first,
            .cap = cap,
            .next_size = first,
            .list = try .initCapacity(arena, 8),
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
        try self.fresh();
        return self;
    }

    fn fresh(self: *Segments) !void {
        const buf = try self.arena.alloc(u8, self.next_size);
        self.next_size = @min(self.next_size * 2, self.cap);
        self.writer.buffer = buf;
        self.writer.end = 0;
    }

    fn seal(self: *Segments) !void {
        const w = &self.writer;
        if (w.end == 0) return;
        try self.list.append(self.arena, .{ .base = w.buffer.ptr, .len = w.end });
        w.end = 0;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Segments = @alignCast(@fieldParentPtr("writer", w));
        // `drain` has to consume the buffer (`flush` calls it until `end` is
        // zero), and here consuming it is sealing it: the buffered bytes are
        // already in their segment. `data` is what did not fit, copied into
        // the next one, which is taken only when there is something for it.
        self.seal() catch return error.WriteFailed;
        w.buffer = &.{};
        var taken: usize = 0;
        for (data, 0..) |slice, i| {
            const times: usize = if (i == data.len - 1) splat else 1;
            for (0..times) |_| {
                var rest = slice;
                while (rest.len > 0) {
                    const room = w.buffer.len - w.end;
                    if (room == 0) {
                        self.seal() catch return error.WriteFailed;
                        self.fresh() catch return error.WriteFailed;
                        continue;
                    }
                    const n = @min(room, rest.len);
                    @memcpy(w.buffer[w.end..][0..n], rest[0..n]);
                    w.end += n;
                    rest = rest[n..];
                    taken += n;
                }
            }
        }
        return taken;
    }

    /// Flush, which seals the last segment, and hand back the iovecs.
    fn finish(self: *Segments) ![]std.posix.iovec_const {
        try self.writer.flush();
        return self.list.items;
    }
};

// ---- the answer ----

const Item = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    score: f64,
    active: bool,
    tags: []const []const u8,
};

const tags = [_][]const u8{ "alpha", "beta", "gamma" };

fn makeItems(arena: std.mem.Allocator, count: usize) ![]Item {
    const items = try arena.alloc(Item, count);
    for (items, 0..) |*item, i| item.* = .{
        .id = @intCast(1000 + i),
        .name = "Ayu Pratama Wijaya",
        .email = "ayu.pratama@example.co.id",
        .score = 12.5 + @as(f64, @floatFromInt(i)) * 0.25,
        .active = i % 3 != 0,
        .tags = &tags,
    };
    return items;
}

// ---- the counting arena ----

const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    bytes: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.vtable.alloc(self.child.ptr, len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.vtable.resize(self.child.ptr, m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.vtable.remap(self.child.ptr, m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, m, a, ra);
    }
};

// ---- the variants ----

const Variant = enum { allocating, seg_512_4096, seg_4096 };
const variants = [_]Variant{ .allocating, .seg_512_4096, .seg_4096 };

const Sink = struct {
    fd: i32,
    head: [160]u8 = undefined,
    iov: [64]std.posix.iovec_const = undefined,

    fn headFor(self: *Sink, len: usize) []const u8 {
        return std.fmt.bufPrint(&self.head, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{len}) catch unreachable;
    }
};

/// One request's body, then (when `send`) one `writev` of head and body.
/// Returns the body length so nothing is dead code.
fn request(v: Variant, arena: std.mem.Allocator, items: []const Item, sink: *Sink, send: bool) !usize {
    switch (v) {
        .allocating => {
            var out: std.Io.Writer.Allocating = try .initCapacity(arena, json_hint);
            try json.write(&out.writer, items);
            const body = out.written();
            if (send) {
                sink.iov[0] = .{ .base = sink.headFor(body.len).ptr, .len = sink.headFor(body.len).len };
                sink.iov[1] = .{ .base = body.ptr, .len = body.len };
                _ = std.os.linux.writev(sink.fd, &sink.iov, 2);
            }
            return body.len;
        },
        .seg_512_4096, .seg_4096 => {
            const first: usize = if (v == .seg_4096) 4096 else json_hint;
            const s = try Segments.init(arena, first, 4096);
            try json.write(&s.writer, items);
            const parts = try s.finish();
            var total: usize = 0;
            for (parts) |p| total += p.len;
            if (send) {
                const head = sink.headFor(total);
                sink.iov[0] = .{ .base = head.ptr, .len = head.len };
                @memcpy(sink.iov[1..][0..parts.len], parts);
                _ = std.os.linux.writev(sink.fd, &sink.iov, parts.len + 1);
            }
            return total;
        },
    }
}

// ---- measuring ----

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn openCounter() !i32 {
    var attr: std.os.linux.perf_event_attr = .{
        .type = .HARDWARE,
        .config = @intFromEnum(std.os.linux.PERF.COUNT.HW.INSTRUCTIONS),
        .flags = .{ .disabled = true, .exclude_kernel = true, .exclude_hv = true },
    };
    const rc = std.os.linux.perf_event_open(&attr, 0, -1, -1, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.NoCounter;
    return @intCast(rc);
}

fn readCounter(fd: i32) u64 {
    var v: u64 = 0;
    _ = std.os.linux.read(fd, @ptrCast(&v), 8);
    return v;
}

const Sample = struct { ns: u64, instr: u64, allocs: usize, bytes: usize };

fn round(v: Variant, arena: *std.heap.ArenaAllocator, counting: *Counting, items: []const Item, sink: *Sink, send: bool, counter: i32) !Sample {
    const before_allocs = counting.allocs;
    const before_bytes = counting.bytes;
    _ = std.os.linux.ioctl(counter, 0x2403, 0); // PERF_EVENT_IOC_RESET
    _ = std.os.linux.ioctl(counter, 0x2400, 0); // PERF_EVENT_IOC_ENABLE
    const t0 = nowNs();
    var keep: usize = 0;
    for (0..per_round) |_| {
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
        keep +%= try request(v, arena.allocator(), items, sink, send);
    }
    const t1 = nowNs();
    _ = std.os.linux.ioctl(counter, 0x2401, 0); // DISABLE
    std.mem.doNotOptimizeAway(keep);
    return .{ .ns = t1 - t0, .instr = readCounter(counter), .allocs = counting.allocs - before_allocs, .bytes = counting.bytes - before_bytes };
}

fn lessU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--keep")) arena_keep = try std.fmt.parseInt(usize, args.next() orelse return error.MissingValue, 10);
    }
    std.debug.print("arena keeps {d} bytes\n", .{arena_keep});
    const gpa = std.heap.smp_allocator;
    const counter = try openCounter();
    const devnull = std.os.linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
    var sink: Sink = .{ .fd = @intCast(devnull) };

    const sizes = [_]usize{ 1024, 4096, 16384 };
    for (sizes) |target| {
        // Items of about 130 bytes each; the real length is printed.
        const count = target / 130;
        var probe_arena: std.heap.ArenaAllocator = .init(gpa);
        defer probe_arena.deinit();
        const items = try makeItems(probe_arena.allocator(), count);
        var probe: std.Io.Writer.Allocating = .init(gpa);
        defer probe.deinit();
        try json.write(&probe.writer, items);
        // The segments have to be the same bytes, or the comparison is of
        // two different answers.
        for ([_]usize{ 512, 4096 }) |first| {
            const seg = try Segments.init(probe_arena.allocator(), first, 4096);
            try json.write(&seg.writer, items);
            var joined: std.Io.Writer.Allocating = .init(gpa);
            defer joined.deinit();
            for (try seg.finish()) |part| try joined.writer.writeAll(part.base[0..part.len]);
            if (!std.mem.eql(u8, joined.written(), probe.written())) @panic("the segments are not the answer Allocating writes");
        }
        std.debug.print("\n== {d} items, {d} bytes of JSON (target {d}) ==\n", .{ count, probe.written().len, target });

        for ([_]bool{ false, true }) |send| {
            std.debug.print("-- {s}\n", .{if (send) "build and one writev of head + body to /dev/null" else "build only"});
            var arenas: [variants.len]std.heap.ArenaAllocator = undefined;
            var countings: [variants.len]Counting = undefined;
            var ns: [variants.len][rounds]u64 = undefined;
            var instr: [variants.len][rounds]u64 = undefined;
            var allocs: [variants.len]usize = undefined;
            var bytes: [variants.len]usize = undefined;
            for (0..variants.len) |i| {
                countings[i] = .{ .child = gpa };
                arenas[i] = .init(countings[i].allocator());
                // Warm: the first requests grow the arena to what it keeps.
                _ = try round(variants[i], &arenas[i], &countings[i], items, &sink, send, counter);
            }
            for (0..rounds) |r| {
                // Interleaved, and the order rotates so none is always first.
                for (0..variants.len) |k| {
                    const i = (k + r) % variants.len;
                    const s = try round(variants[i], &arenas[i], &countings[i], items, &sink, send, counter);
                    ns[i][r] = s.ns;
                    instr[i][r] = s.instr;
                    allocs[i] = s.allocs;
                    bytes[i] = s.bytes;
                }
            }
            for (0..variants.len) |i| {
                std.mem.sort(u64, &ns[i], {}, lessU64);
                std.mem.sort(u64, &instr[i], {}, lessU64);
                const p = @as(f64, per_round);
                std.debug.print(
                    "{s:>13}: {d:8.1} ns/req (min) {d:8.1} (median) {d:8.1} (max) | {d:8.0} instr/req (min) {d:8.0} (max) | {d:5.2} backing allocs/req {d:7.0} B/req\n",
                    .{
                        @tagName(variants[i]),
                        @as(f64, @floatFromInt(ns[i][0])) / p,
                        @as(f64, @floatFromInt(ns[i][rounds / 2])) / p,
                        @as(f64, @floatFromInt(ns[i][rounds - 1])) / p,
                        @as(f64, @floatFromInt(instr[i][0])) / p,
                        @as(f64, @floatFromInt(instr[i][rounds - 1])) / p,
                        @as(f64, @floatFromInt(allocs[i])) / p,
                        @as(f64, @floatFromInt(bytes[i])) / p,
                    },
                );
            }
        }
    }
}
