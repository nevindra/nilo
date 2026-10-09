//! What `json.write` costs on the arena's `json-h2c` answer: the first
//! `count` items of a dataset slice with a derived `total`, wrapped in
//! `{items, count}`, for the seven counts the board rotates (1, 5, 10, 15, 25,
//! 40, 50). A measurement of `http/json.zig` through the writer `sendJson`
//! uses (`Allocating.initCapacity(arena, json_hint)`), nothing else.
//!
//! ```
//! taskset -c 5 zig build bench-json-listing -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
//! ```
//!
//! Instructions are the user-space `INSTRUCTIONS` counter (`perf_event_open`),
//! the minimum and median round of 21 rounds of 5,000 requests a count; the
//! figure to move is `ns` and `instructions` a request averaged over the seven
//! counts, which is the mix the board sends.

const std = @import("std");
const json = @import("json");

const Rating = struct { score: i64, count: i64 };

const Item = struct {
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

const Listing = struct { items: []const Item, count: usize };

const names = [_][]const u8{ "Alpha Widget", "Pro Valve", "Core Relay", "Mega Sensor", "Ultra Gauge" };
const cats = [_][]const u8{ "electronics", "tools", "hardware", "automotive" };
const tag_sets = [_][]const []const u8{
    &.{ "sale", "heavy-duty", "popular" },
    &.{ "fast", "heavy-duty", "new", "wireless" },
    &.{ "premium", "durable" },
    &.{ "eco", "compact", "sale" },
};

fn makeItems(arena: std.mem.Allocator, n: usize) ![]Item {
    const out = try arena.alloc(Item, n);
    for (out, 0..) |*it, i| it.* = .{
        .id = @intCast(i + 1),
        .name = names[i % names.len],
        .category = cats[i % cats.len],
        .price = @intCast(100 + i * 37 % 400),
        .quantity = @intCast(1 + i * 53 % 100),
        .active = i % 3 != 0,
        .tags = tag_sets[i % tag_sets.len],
        .rating = .{ .score = @intCast(10 + i * 7 % 40), .count = @intCast(30 + i * 91 % 300) },
        .total = @intCast((100 + i * 37 % 400) * (1 + i * 53 % 100) * 3),
    };
    return out;
}

const json_hint = 512;
var arena_keep: usize = 4096;
const counts = [_]usize{ 1, 5, 10, 15, 25, 40, 50 };
const per_round = 5_000;
const rounds = 21;

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
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const items = try makeItems(gpa, 50);
    defer gpa.free(items);

    var tot_ns: f64 = 0;
    var tot_instr: f64 = 0;
    var tot_bytes: usize = 0;
    for (counts) |count| {
        var ns: [rounds]u64 = undefined;
        var instr: [rounds]u64 = undefined;
        var bytes: usize = 0;
        for (0..rounds + 1) |r| {
            _ = std.os.linux.ioctl(counter, 0x2403, 0);
            _ = std.os.linux.ioctl(counter, 0x2400, 0);
            const t0 = nowNs();
            for (0..per_round) |_| {
                _ = arena.reset(.{ .retain_with_limit = arena_keep });
                var out: std.Io.Writer.Allocating = try .initCapacity(arena.allocator(), json_hint);
                try json.write(&out.writer, Listing{ .items = items[0..count], .count = count });
                bytes = out.written().len;
                std.mem.doNotOptimizeAway(out.written().ptr);
            }
            const t1 = nowNs();
            _ = std.os.linux.ioctl(counter, 0x2401, 0);
            if (r == 0) continue;
            ns[r - 1] = (t1 - t0) / per_round;
            instr[r - 1] = readCounter(counter) / per_round;
        }
        std.mem.sort(u64, &ns, {}, lessU64);
        std.mem.sort(u64, &instr, {}, lessU64);
        std.debug.print("{d:>3} items {d:>6} bytes  {d:>6} ns (min) {d:>6} ns (median)  {d:>7} instructions\n", .{ count, bytes, ns[0], ns[rounds / 2], instr[rounds / 2] });
        tot_ns += @floatFromInt(ns[0]);
        tot_instr += @floatFromInt(instr[rounds / 2]);
        tot_bytes += bytes;
    }

    // The mix as the board sends it: the seven counts in rotation on one
    // arena, which keeps `arena_keep` bytes across requests. This is the row
    // that sees an answer larger than what the arena keeps, because the
    // arena's node is dropped and asked for again by the next big one.
    var mns: [rounds]u64 = undefined;
    var minstr: [rounds]u64 = undefined;
    for (0..rounds + 1) |r| {
        _ = std.os.linux.ioctl(counter, 0x2403, 0);
        _ = std.os.linux.ioctl(counter, 0x2400, 0);
        const t0 = nowNs();
        for (0..per_round) |i| {
            _ = arena.reset(.{ .retain_with_limit = arena_keep });
            const count = counts[i % counts.len];
            // What the handler allocates before it answers: the derived items.
            const listed = try arena.allocator().alloc(Item, count);
            @memcpy(listed, items[0..count]);
            var out: std.Io.Writer.Allocating = try .initCapacity(arena.allocator(), json_hint);
            try json.write(&out.writer, Listing{ .items = listed, .count = count });
            std.mem.doNotOptimizeAway(out.written().ptr);
        }
        const t1 = nowNs();
        _ = std.os.linux.ioctl(counter, 0x2401, 0);
        if (r == 0) continue;
        mns[r - 1] = (t1 - t0) / per_round;
        minstr[r - 1] = readCounter(counter) / per_round;
    }
    std.mem.sort(u64, &mns, {}, lessU64);
    std.mem.sort(u64, &minstr, {}, lessU64);
    std.debug.print("rotating on one arena: {d} ns (min) {d} ns (median) {d} instructions a request\n", .{ mns[0], mns[rounds / 2], minstr[rounds / 2] });
    std.debug.print("mix: {d} bytes, {d:.0} ns (min), {d:.0} instructions a request\n", .{ tot_bytes / counts.len, tot_ns / counts.len, tot_instr / counts.len });
}
