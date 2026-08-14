//! Where the time inside one request goes. `zig build profile`.
//!
//! The counterpart to `bench/bench.sh`: that one measures the server from
//! outside and needs a machine nobody else is using, this one measures the
//! pieces from inside and does not. The end-to-end figure will still wobble
//! on a busy box — what holds steady is the shape, one component against
//! another in the same run.
//!
//! Not a test and not built by `zig build test`, because a number that
//! moves with the weather has no business failing a build.

const std = @import("std");
const http1 = @import("http1.zig");
const ctx_mod = @import("ctx.zig");
const json_mod = @import("json.zig");
const str_mod = @import("str.zig");
const fail = @import("fail.zig");
const clock = @import("bulkhead.zig").monotonicNanos;
const App = @import("app.zig").App;
const cors = @import("cors.zig");
const websocket = @import("websocket.zig");
const stream_mod = @import("stream.zig");
const body_mod = @import("body.zig");
const range = @import("range.zig");
const router_mod = @import("router.zig");

const rounds = 300_000;
const arena_keep = 16 * 1024;

/// How many times each measurement is repeated, with the best kept. A shared
/// machine hands out a stolen timeslice now and then, and the mean carries it
/// while the minimum does not.
const reps = 5;

/// The shape of the primary metric: a routed GET with a path param
/// answering JSON, keep-alive, with CORS installed.
const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
    "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

/// The payload `main.zig` really answers with. It matters that this is the
/// same size, and for a long time it was not: this file profiled a 25-byte
/// `{id,name}` while the benchmark target served a kilobyte, and the ~1µs
/// `std.json` spent escaping that kilobyte was invisible for the whole of v1
/// and v2 as a result. A profiler measuring a different payload from the
/// thing being profiled is worse than no profiler.
const bio = "A systems nerd who writes Zig before breakfast. " ** 19;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    bio: []const u8,
};

const Db = struct {
    fn find(_: *Db, id: u32) ?User {
        if (id != 7) return null;
        return .{ .id = 7, .name = "Routed Tester", .email = "tester@example.dev", .bio = bio };
    }
};

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}

var sink: usize = 0;

/// Run `body` `rounds` times, `reps` times over, and return the quickest
/// average. Warmed first, which is the part that used to be missing: the
/// end-to-end figure was the very first loop in the program, so it paid for a
/// cold arena, a cold instruction cache and a CPU that had not clocked up —
/// and every percentage below was measured against that inflated number.
fn bestOf(comptime body: fn () void) u64 {
    for (0..rounds / 4) |_| body();
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const started = clock();
        for (0..rounds) |_| body();
        const took = clock() - started;
        if (took < best) best = took;
    }
    return best;
}

// The state each measurement below works against. At file scope because a
// nested function in Zig captures nothing, and these have to be reachable from
// the one-line bodies `bestOf` takes.
var app: App = undefined;
var arena: std.heap.ArenaAllocator = undefined;
var lifetime = str_mod.Lifetime{};
var in_flight = fail.InFlight{};
var out_buf: [8192]u8 = undefined;
var body_json: []const u8 = "";

fn wholeRequest() void {
    var in = std.Io.Reader.fixed(request);
    var out = std.Io.Writer.fixed(&out_buf);
    sink += @intFromBool(app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .{}));
    lifetime.end();
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn readHeadOnly() void {
    var in = std.Io.Reader.fixed(request);
    sink += (http1.readHead(&in, .off) catch unreachable).len;
}

fn parseHeadOnly() void {
    var r = http1.Request{};
    http1.parseHead(request, &r) catch unreachable;
    sink += r.target.len;
}

fn copyHead() void {
    sink += (arena.allocator().dupe(u8, request) catch unreachable).len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn matchRoute() void {
    sink += (app.router.match(.GET, "/users/7") orelse unreachable).n_params;
}

fn serialiseBody() void {
    var w = std.Io.Writer.Allocating.initCapacity(arena.allocator(), ctx_mod.json_hint) catch unreachable;
    json_mod.write(&w.writer, Db.find(undefined, 7).?) catch unreachable;
    sink += w.written().len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn writeTheResponse() void {
    var out = std.Io.Writer.fixed(&out_buf);
    http1.writeResponse(&out, 200, "OK", "application/json", body_json, true, &.{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    }) catch unreachable;
    sink += out.buffered().len;
}

fn arenaRound() void {
    sink += (arena.allocator().alloc(u8, 200) catch unreachable).len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var db = Db{};
    app = App.init(gpa);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.resolveChains();

    arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // The real response body, so "write the response" is writing the number of
    // bytes the server really writes.
    var body_out: std.Io.Writer.Allocating = .init(gpa);
    defer body_out.deinit();
    try json_mod.write(&body_out.writer, db.find(7).?);
    body_json = body_out.written();

    const whole = bestOf(wholeRequest);

    std.debug.print(
        "{d} requests, {d}ns each end to end — a routed GET with a path param\n" ++
            "answering {d} bytes of JSON over keep-alive, with CORS installed.\n\n",
        .{ rounds, whole / rounds, body_json.len },
    );
    line("read the head", bestOf(readHeadOnly), whole);
    line("parse the head", bestOf(parseHeadOnly), whole);
    line("copy the head to the arena", bestOf(copyHead), whole);
    line("match the route", bestOf(matchRoute), whole);
    line("serialise the body", bestOf(serialiseBody), whole);
    line("write the response", bestOf(writeTheResponse), whole);
    line("arena alloc + reset", bestOf(arenaRound), whole);
    std.debug.print(
        \\
        \\Each row is the best of five runs, warmed first. What is not listed —
        \\building the Ctx, the middleware chain, matching handler arguments,
        \\decoding path params — is the remainder.
        \\
        \\"Copy the head to the arena" is charged to a request that has a body;
        \\one without does not copy it at all, so on this shape that row is a
        \\cost avoided rather than a cost paid.
        \\
    , .{});

    try longLived(gpa);
    try routerScale(gpa);

    if (sink == 0) unreachable; // keeps the work from being optimised away
}

// ---- one route out of many ----
//
// The row above is measured on the app this file serves, which has one
// route. What the scan costs as routes are added is a different question and
// the one the roadmap has open, so it gets measured here rather than
// reasoned about.
//
// Every pattern carries a `:id`, so nothing is all-literal and the early
// exit never fires; and the wanted route is registered last, so nothing is
// captured until the end. That is the worst case on purpose — the number to
// beat, not the number to quote.

const scale_rounds = 200_000;
const scale_counts = [_]usize{ 1, 5, 25, 50, 100 };

/// Two route sets, because they exercise opposite halves of the scan and a
/// number from one says nothing about the other.
///
/// **Mixed** is what an app looks like: four methods, three depths. Nearly
/// every route is thrown out on the method or the segment count, before any
/// text is read — so this measures the cheap filter.
///
/// **Same shape** is every route `GET /thingN/:id/leaf`. Not one of them can
/// be rejected cheaply: same method, same length, same score. Every single
/// one runs the full segment walk. No real app looks like this and it is the
/// ceiling, which is the useful thing about it.
const Shape = enum { mixed, same };

fn routerScale(gpa: std.mem.Allocator) !void {
    std.debug.print("\n---- matching one route out of many ----\n\n", .{});
    std.debug.print("  {s:<12}{s:>7}{s:>7}{s:>7}{s:>7}{s:>7}\n", .{ "", "1", "5", "25", "50", "100" });

    for ([_]Shape{ .mixed, .same }) |shape| {
        std.debug.print("  {s:<12}", .{@tagName(shape)});
        for (scale_counts) |n| {
            std.debug.print("{d:>5}ns", .{try oneScale(gpa, shape, n)});
        }
        std.debug.print("\n", .{});
    }
}

fn oneScale(gpa: std.mem.Allocator, shape: Shape, n: usize) !u64 {
    const methods = [_]http1.Method{ .GET, .POST, .PUT, .DELETE };
    const depths = 3;

    var patterns = try gpa.alloc([]u8, n);
    defer {
        for (patterns) |p| gpa.free(p);
        gpa.free(patterns);
    }

    var r = router_mod.Router.init(gpa);
    defer r.deinit();

    for (0..n) |i| {
        patterns[i] = switch (shape) {
            .mixed => switch (i % depths) {
                0 => try std.fmt.allocPrint(gpa, "/thing{d}", .{i}),
                1 => try std.fmt.allocPrint(gpa, "/thing{d}/:id", .{i}),
                else => try std.fmt.allocPrint(gpa, "/thing{d}/:id/leaf", .{i}),
            },
            .same => try std.fmt.allocPrint(gpa, "/thing{d}/:id/leaf", .{i}),
        };
        try r.add(switch (shape) {
            .mixed => methods[i % methods.len],
            .same => .GET,
        }, patterns[i], nothing);
    }

    // The last route registered, so nothing is captured before the end.
    const last = n - 1;
    const wanted = switch (shape) {
        .mixed => switch (last % depths) {
            0 => try std.fmt.allocPrint(gpa, "/thing{d}", .{last}),
            1 => try std.fmt.allocPrint(gpa, "/thing{d}/7", .{last}),
            else => try std.fmt.allocPrint(gpa, "/thing{d}/7/leaf", .{last}),
        },
        .same => try std.fmt.allocPrint(gpa, "/thing{d}/7/leaf", .{last}),
    };
    defer gpa.free(wanted);
    const method = switch (shape) {
        .mixed => methods[last % methods.len],
        .same => .GET,
    };

    for (0..scale_rounds / 4) |_| sink += (r.match(method, wanted) orelse unreachable).n_params;
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const started = clock();
        for (0..scale_rounds) |_| sink += (r.match(method, wanted) orelse unreachable).n_params;
        const took = clock() - started;
        if (took < best) best = took;
    }
    return best / scale_rounds;
}

fn nothing(_: *ctx_mod.Ctx) anyerror!void {}

fn line(label: []const u8, part: u64, whole: u64) void {
    std.debug.print("  {s:<28}{d:>5}ns {d:>6.1}%\n", .{
        label,
        part / rounds,
        @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole)),
    });
}

// ---- the connections that last ----
//
// A request-response profile says nothing about the paths added in v2, which
// are shaped the other way round: one request, then work per message, per
// piece or per kilobyte. So these are per-operation numbers rather than
// percentages of a request, and the useful ones are throughputs.

const ws_rounds = 20_000;
const piece_rounds = 20_000;
const message = 16 * 1024;

fn longLived(gpa: std.mem.Allocator) !void {
    std.debug.print("\n---- connections that last ----\n\n", .{});

    // One masked binary frame, the way a browser sends one.
    const wire = try gpa.alloc(u8, message + 14);
    defer gpa.free(wire);
    const frame_len = buildClientFrame(wire, message);

    const empty_wire = try gpa.alloc(u8, 14);
    defer gpa.free(empty_wire);
    const empty_len = buildClientFrame(empty_wire, 0);

    const room = try gpa.alloc(u8, message);
    defer gpa.free(room);
    const away = try gpa.alloc(u8, 64 * 1024);
    defer gpa.free(away);

    // A whole message read, unmasked and echoed back, against in-memory
    // buffers — so what is left is zfast's work, with no kernel in it.
    var t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(wire[0..frame_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        const got = (try socket.receive(room)) orelse unreachable;
        sink += got.data.len;
    }
    const ws_full = (clock() - t) / ws_rounds;

    // The same, with no payload. The difference is what the bytes cost.
    t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(empty_wire[0..empty_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        const got = (try socket.receive(room)) orelse unreachable;
        sink += got.data.len + 1;
    }
    const ws_empty = (clock() - t) / ws_rounds;

    t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(empty_wire[0..empty_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        try socket.send(.binary, room);
        sink += out.buffered().len;
    }
    const ws_send = (clock() - t) / ws_rounds;

    ops("websocket: frame overhead", ws_empty, null);
    ops("websocket: receive 16 KiB", ws_full, throughput(ws_full - ws_empty, message));
    ops("websocket: send 16 KiB", ws_send, throughput(ws_send, message));

    // A streamed response of 200 short pieces, which is the shape a report
    // has: many small writes behind one chunk header per buffer-full.
    var stream_buf: [4 * 1024]u8 = undefined;
    t = clock();
    for (0..piece_rounds) |_| {
        var out = std.Io.Writer.fixed(away);
        var open: ?stream_mod.Open = .{ .chunked = true, .drop = false };
        var body = stream_mod.Stream.init(&stream_buf, &out, null, &open);
        for (0..200) |i| try body.print("{d},wati,{d}\n", .{ i, i * 3 });
        try body.finish();
        sink += out.buffered().len;
    }
    const streamed = (clock() - t) / piece_rounds;

    t = clock();
    for (0..piece_rounds) |_| {
        var out = std.Io.Writer.fixed(away);
        var open: ?stream_mod.Open = .{ .chunked = true, .drop = false };
        var events = stream_mod.Events{ .stream = .init(&stream_buf, &out, null, &open) };
        for (0..200) |i| {
            _ = i;
            try events.send(.{ .name = "token", .data = "hello" });
        }
        try events.close();
        sink += out.buffered().len;
    }
    const sse = (clock() - t) / piece_rounds;

    ops("stream: 200 pieces", streamed, null);
    ops("stream: one piece", streamed / 200, null);
    ops("sse: 200 events", sse, null);
    ops("sse: one event", sse / 200, null);

    // A megabyte of upload, both framings, read in 64 KiB pieces.
    const upload = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(upload);
    @memset(upload, 'x');

    const chunked_wire = try chunkUp(gpa, upload, 8 * 1024);
    defer gpa.free(chunked_wire);

    const body_rounds = 500;
    t = clock();
    for (0..body_rounds) |_| sink += try drainBody(upload, .{ .content_length = upload.len }, away);
    const sized_body = (clock() - t) / body_rounds;

    t = clock();
    for (0..body_rounds) |_| sink += try drainBody(chunked_wire, .{ .chunked = true }, away);
    const chunked_body = (clock() - t) / body_rounds;

    ops("body: 1 MiB, Content-Length", sized_body, throughput(sized_body, upload.len));
    ops("body: 1 MiB, chunked 8 KiB", chunked_body, throughput(chunked_body, upload.len));

    // Two things every request pays that no benchmark has ever looked at.
    t = clock();
    for (0..rounds) |_| sink += @intFromBool(range.parse("bytes=100-200", 1000, true) != .whole);
    const range_ns = (clock() - t) / rounds;

    ops("range: parse one", range_ns, null);
}

fn ops(label: []const u8, ns: u64, per_second: ?f64) void {
    if (per_second) |gb| {
        std.debug.print("  {s:<30}{d:>8}ns   {d:.1} GB/s\n", .{ label, ns, gb });
    } else {
        std.debug.print("  {s:<30}{d:>8}ns\n", .{ label, ns });
    }
}

fn throughput(ns: u64, bytes: usize) f64 {
    if (ns == 0) return 0;
    return @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(ns));
}

/// One masked client frame with `len` bytes of payload, as a browser sends.
fn buildClientFrame(into: []u8, len: usize) usize {
    into[0] = 0x82; // FIN, binary
    var at: usize = 2;
    if (len < 126) {
        into[1] = 0x80 | @as(u8, @intCast(len));
    } else {
        into[1] = 0x80 | 126;
        std.mem.writeInt(u16, into[2..4], @intCast(len), .big);
        at = 4;
    }
    const key = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    @memcpy(into[at..][0..4], &key);
    at += 4;
    for (0..len) |i| into[at + i] = @as(u8, @truncate(i)) ^ key[i % 4];
    return at + len;
}

/// `payload` wrapped in chunks of `each` bytes, as a client streaming an
/// upload sends it.
fn chunkUp(gpa: std.mem.Allocator, payload: []const u8, each: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var at: usize = 0;
    while (at < payload.len) {
        const n = @min(each, payload.len - at);
        try out.writer.print("{x}\r\n", .{n});
        try out.writer.writeAll(payload[at..][0..n]);
        try out.writer.writeAll("\r\n");
        at += n;
    }
    try out.writer.writeAll("0\r\n\r\n");
    return out.toOwnedSlice();
}

fn drainBody(wire: []const u8, head: http1.Request, scratch: []u8) !u64 {
    var in = std.Io.Reader.fixed(wire);
    var progress: body_mod.Progress = .start(&head, 64 * 1024 * 1024);
    var incoming = body_mod.Body.init(&in, &progress);
    var total: u64 = 0;
    while (try incoming.read(scratch)) |part| total += part.len;
    return total;
}
