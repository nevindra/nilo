//! What reading and writing a protobuf message costs, against a decoder
//! written by hand for the same fields (ADR 245).
//!
//! ```
//! taskset -c 5 zig build bench-proto -Doptimize=ReleaseFast -- [rounds] [milliseconds]
//! ```
//!
//! The message is OTLP's logs shape, 500 records of ten attributes each, built
//! once by the module's own encoder. Three things are timed, interleaved round
//! by round so a drifting clock moves all of them together:
//!
//! - **`decode`**: `proto.decode` into structs, then a walk that adds up what
//!   a consumer would read (every string's length, every number).
//! - **`stream`**: a decoder written by hand against `proto.Reader` that does
//!   the same adding up straight off the wire and never builds a struct. It
//!   refuses what `decode` refuses (UTF-8 in every string). It is the floor
//!   for "decode, then walk": the same bytes read once, with no tree between.
//! - **`encode`**: `proto.encodeInto` of the decoded request into a buffer.
//!
//! Allocator calls for one decode are counted separately, since the arena
//! beneath is reset after every decode and so hides them from the clock.
//! The photon comparison this module was promoted on (a hand-written decoder
//! writing straight into column builders, against `decode` and a walk into the
//! same builders) is in [`result/proto.md`](./result/proto.md), with how to
//! rerun it.

const std = @import("std");
const proto = @import("nilo_proto");

const AnyValue = struct {
    pub const wire = .{};
    value: ?Value = null,
    const Value = union(enum) {
        pub const wire = .{ .string_value = 1, .bool_value = 2, .int_value = 3, .double_value = 4 };
        string_value: []const u8,
        bool_value: bool,
        int_value: i64,
        double_value: f64,
    };
};

const KeyValue = struct {
    pub const wire = .{ .key = 1, .value = 2 };
    key: []const u8 = "",
    value: ?AnyValue = null,
};

const LogRecord = struct {
    pub const wire = .{
        .time_unix_nano = .{ 1, .fixed64 },
        .severity_number = 2,
        .severity_text = 3,
        .body = 5,
        .attributes = 6,
        .trace_id = .{ 9, .bytes },
        .span_id = .{ 10, .bytes },
    };
    time_unix_nano: u64 = 0,
    severity_number: i32 = 0,
    severity_text: []const u8 = "",
    body: ?AnyValue = null,
    attributes: []const KeyValue = &.{},
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
};

const ScopeLogs = struct {
    pub const wire = .{ .log_records = 2 };
    log_records: []const LogRecord = &.{},
};

const ResourceLogs = struct {
    pub const wire = .{ .scope_logs = 2 };
    scope_logs: []const ScopeLogs = &.{},
};

const Request = struct {
    pub const wire = .{ .resource_logs = 1 };
    resource_logs: []const ResourceLogs = &.{},
};

const records_n = 500;
const attrs_n = 10;

fn build(arena: std.mem.Allocator) ![]u8 {
    const records = try arena.alloc(LogRecord, records_n);
    for (records, 0..) |*r, i| {
        const attrs = try arena.alloc(KeyValue, attrs_n);
        for (attrs, 0..) |*a, k| {
            a.* = .{
                .key = try std.fmt.allocPrint(arena, "http.attr.{d}", .{k}),
                .value = switch (k % 4) {
                    0 => .{ .value = .{ .string_value = try std.fmt.allocPrint(arena, "value-{d}-{d}", .{ i, k }) } },
                    1 => .{ .value = .{ .int_value = @intCast(i * 31 + k) } },
                    2 => .{ .value = .{ .bool_value = k % 2 == 0 } },
                    else => .{ .value = .{ .double_value = @as(f64, @floatFromInt(i)) / 7 } },
                },
            };
        }
        r.* = .{
            .time_unix_nano = 1_700_000_000_000_000_000 + i,
            .severity_number = 9,
            .severity_text = "INFO",
            .body = .{ .value = .{ .string_value = try std.fmt.allocPrint(arena, "request {d} completed in {d}ms", .{ i, i % 250 }) } },
            .attributes = attrs,
            .trace_id = &(@as([16]u8, @splat(0xab))),
            .span_id = &(@as([8]u8, @splat(0xcd))),
        };
    }
    return proto.encode(Request, arena, .{ .resource_logs = &.{.{ .scope_logs = &.{.{ .log_records = records }} }} });
}

/// What a consumer reads of a decoded request, so the tree is not dead code.
fn walk(req: Request) u64 {
    var sum: u64 = 0;
    for (req.resource_logs) |rl| for (rl.scope_logs) |sl| for (sl.log_records) |lr| {
        sum +%= lr.time_unix_nano +% @as(u64, @intCast(lr.severity_number)) +% lr.severity_text.len +% lr.trace_id.len +% lr.span_id.len;
        if (lr.body) |b| if (b.value) |v| switch (v) {
            .string_value => |s| sum +%= s.len,
            else => {},
        };
        for (lr.attributes) |kv| {
            sum +%= kv.key.len;
            if (kv.value) |av| if (av.value) |v| switch (v) {
                .string_value => |s| sum +%= s.len,
                .bool_value => |x| sum +%= @intFromBool(x),
                .int_value => |x| sum +%= @bitCast(x),
                .double_value => |x| sum +%= @as(u64, @bitCast(x)),
            };
        }
    };
    return sum;
}

const Bad = proto.Error;

fn streamString(r: *proto.Reader, k: proto.Key) Bad![]const u8 {
    if (k.wire != .len) return error.WrongWireType;
    const b = try r.bytes();
    if (!proto.validUtf8(b)) return error.InvalidUtf8;
    return b;
}

/// The same adding up, read straight off the wire.
fn stream(bytes: []const u8) Bad!u64 {
    var sum: u64 = 0;
    var r1: proto.Reader = .init(bytes);
    while (r1.more()) {
        const k1 = try r1.key();
        if (k1.number != 1 or k1.wire != .len) {
            try r1.skip(k1, proto.max_depth);
            continue;
        }
        var r2: proto.Reader = .init(try r1.bytes());
        while (r2.more()) {
            const k2 = try r2.key();
            if (k2.number != 2 or k2.wire != .len) {
                try r2.skip(k2, proto.max_depth);
                continue;
            }
            var r3: proto.Reader = .init(try r2.bytes());
            while (r3.more()) {
                const k3 = try r3.key();
                if (k3.number != 2 or k3.wire != .len) {
                    try r3.skip(k3, proto.max_depth);
                    continue;
                }
                sum +%= try streamRecord(try r3.bytes());
            }
        }
    }
    return sum;
}

fn streamRecord(bytes: []const u8) Bad!u64 {
    var sum: u64 = 0;
    var r: proto.Reader = .init(bytes);
    while (r.more()) {
        const k = try r.key();
        switch (k.number) {
            1 => {
                if (k.wire != .fixed64) return error.WrongWireType;
                sum +%= try r.fixed64();
            },
            2 => {
                if (k.wire != .varint) return error.WrongWireType;
                sum +%= @as(u32, @truncate(try r.varint()));
            },
            3 => sum +%= (try streamString(&r, k)).len,
            5 => {
                if (k.wire != .len) return error.WrongWireType;
                sum +%= try streamValue(try r.bytes());
            },
            6 => {
                if (k.wire != .len) return error.WrongWireType;
                var kv: proto.Reader = .init(try r.bytes());
                while (kv.more()) {
                    const kk = try kv.key();
                    switch (kk.number) {
                        1 => sum +%= (try streamString(&kv, kk)).len,
                        2 => {
                            if (kk.wire != .len) return error.WrongWireType;
                            sum +%= try streamValue(try kv.bytes());
                        },
                        else => try kv.skip(kk, proto.max_depth),
                    }
                }
            },
            9, 10 => {
                if (k.wire != .len) return error.WrongWireType;
                sum +%= (try r.bytes()).len;
            },
            else => try r.skip(k, proto.max_depth),
        }
    }
    return sum;
}

fn streamValue(bytes: []const u8) Bad!u64 {
    var sum: u64 = 0;
    var r: proto.Reader = .init(bytes);
    while (r.more()) {
        const k = try r.key();
        switch (k.number) {
            1 => sum +%= (try streamString(&r, k)).len,
            2 => {
                if (k.wire != .varint) return error.WrongWireType;
                sum +%= @intFromBool((try r.varint()) != 0);
            },
            3 => {
                if (k.wire != .varint) return error.WrongWireType;
                sum +%= try r.varint();
            },
            4 => {
                if (k.wire != .fixed64) return error.WrongWireType;
                sum +%= try r.fixed64();
            },
            else => try r.skip(k, proto.max_depth),
        }
    }
    return sum;
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Counting = struct {
    child: std.mem.Allocator,
    calls: usize = 0,

    fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return self.child.rawAlloc(len, a, ra);
    }
    fn resize(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(m, a, n, ra);
    }
    fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(m, a, n, ra);
    }
    fn free(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.rawFree(m, a, ra);
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rounds: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 7;
    const slice_ns: u64 = (if (args.len > 2) try std.fmt.parseInt(u64, args[2], 10) else 1000) * std.time.ns_per_ms;

    var fixture = std.heap.ArenaAllocator.init(gpa);
    defer fixture.deinit();
    const bytes = try build(fixture.allocator());
    const out = try gpa.alloc(u8, bytes.len);
    defer gpa.free(out);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One decode counted, and checked against the stream before any timing.
    var counting: Counting = .{ .child = gpa };
    var counted = std.heap.ArenaAllocator.init(counting.allocator());
    const tree_sum = walk(try proto.decode(Request, counted.allocator(), bytes));
    counted.deinit();
    // What `encode` is timed on lives for the whole run.
    const req = try proto.decode(Request, fixture.allocator(), bytes);
    const stream_sum = try stream(bytes);
    if (tree_sum != stream_sum) return error.DecodersDisagree;

    std.debug.print("{d} records, {d} bytes ({d:.0} a record); one decode makes {d} allocator calls\n", .{
        records_n,
        bytes.len,
        @as(f64, @floatFromInt(bytes.len)) / records_n,
        counting.calls,
    });

    const modes = [_][]const u8{ "decode", "stream", "encode" };
    var best: [3]f64 = @splat(std.math.inf(f64));
    var all: [3][64]f64 = undefined;
    var sink: u64 = 0;
    for (0..rounds) |round| {
        for (modes, 0..) |_, m| {
            var iterations: u64 = 0;
            const start = nowNs();
            while (nowNs() - start < slice_ns) : (iterations += 1) {
                switch (m) {
                    0 => {
                        const r = try proto.decode(Request, arena, bytes);
                        sink +%= walk(r);
                        _ = arena_state.reset(.retain_capacity);
                    },
                    1 => sink +%= try stream(bytes),
                    else => sink +%= (try proto.encodeInto(Request, out, req)).len,
                }
            }
            const ns = @as(f64, @floatFromInt(nowNs() - start)) / @as(f64, @floatFromInt(iterations * records_n));
            best[m] = @min(best[m], ns);
            all[m][round] = ns;
        }
    }
    for (modes, 0..) |name, m| {
        const list = all[m][0..rounds];
        std.mem.sort(f64, list, {}, std.sort.asc(f64));
        std.debug.print("{s:7} min {d:6.1} ns/record  median {d:6.1}  max {d:6.1}  ({d:.0} MB/s at the min)\n", .{
            name,
            list[0],
            list[rounds / 2],
            list[rounds - 1],
            @as(f64, @floatFromInt(bytes.len)) / records_n / list[0] * 1000,
        });
    }
    std.debug.print("decode is {d:.1}% over stream at the min, {d:.1}% at the median (sink {d})\n", .{
        100 * (all[0][0] / all[1][0] - 1),
        100 * (all[0][rounds / 2] / all[1][rounds / 2] - 1),
        sink,
    });
}
