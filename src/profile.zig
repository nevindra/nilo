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
const str_mod = @import("str.zig");
const fail = @import("fail.zig");
const clock = @import("bulkhead.zig").monotonicNanos;
const App = @import("app.zig").App;
const cors = @import("cors.zig");
const websocket = @import("websocket.zig");
const stream_mod = @import("stream.zig");
const body_mod = @import("body.zig");
const range = @import("range.zig");

const rounds = 300_000;
const arena_keep = 16 * 1024;

/// The shape of the primary metric: a routed GET with a path param
/// answering JSON, keep-alive, with CORS installed.
const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
    "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

const User = struct { id: u32, name: []const u8 };
const Db = struct {
    fn find(_: *Db, id: u32) ?User {
        return if (id == 7) .{ .id = 7, .name = "wati" } else null;
    }
};

fn getUser(db: *Db, id: u32) !User {
    return db.find(id) orelse fail.notFound("no user {d}", .{id});
}

var sink: usize = 0;

pub fn main() !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var db = Db{};
    var app = App.init(gpa);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    var t = clock();
    for (0..rounds) |_| {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&buf);
        sink += @intFromBool(app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out));
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    const whole = clock() - t;

    t = clock();
    for (0..rounds) |_| {
        var in = std.Io.Reader.fixed(request);
        sink += (try http1.readHead(&in)).len;
    }
    const read_head = clock() - t;

    t = clock();
    for (0..rounds) |_| {
        sink += (try arena.allocator().dupe(u8, request)).len;
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    const dupe = clock() - t;

    t = clock();
    for (0..rounds) |_| {
        var r = http1.Request{};
        try http1.parseHead(request, &r);
        sink += r.target.len;
    }
    const parse_head = clock() - t;

    t = clock();
    for (0..rounds) |_| sink += (app.router.match(.GET, "/users/7") orelse unreachable).n_params;
    const route = clock() - t;

    const user = User{ .id = 7, .name = "wati" };
    t = clock();
    for (0..rounds) |_| {
        var w = try std.Io.Writer.Allocating.initCapacity(arena.allocator(), ctx_mod.json_hint);
        try std.json.Stringify.value(user, .{}, &w.writer);
        sink += w.written().len;
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    const json = clock() - t;

    t = clock();
    for (0..rounds) |_| {
        var out = std.Io.Writer.fixed(&buf);
        try http1.writeResponse(&out, 200, "OK", "application/json", "{\"id\":7,\"name\":\"wati\"}", true, &.{
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
        });
        sink += out.buffered().len;
    }
    const write = clock() - t;

    t = clock();
    for (0..rounds) |_| {
        sink += (try arena.allocator().alloc(u8, 200)).len;
        _ = arena.reset(.{ .retain_with_limit = arena_keep });
    }
    const arena_ns = clock() - t;

    std.debug.print("{d} requests, {d}ns each end to end\n\n", .{ rounds, whole / rounds });
    line("read the head", read_head, whole);
    line("parse the head", parse_head, whole);
    line("copy the head to the arena", dupe, whole);
    line("match the route", route, whole);
    line("serialise the body", json, whole);
    line("write the response", write, whole);
    line("arena alloc + reset", arena_ns, whole);
    std.debug.print(
        \\
        \\The end-to-end figure moves with whatever else the machine is doing;
        \\the proportions do not. What is not listed — building the Ctx, the
        \\middleware chain, matching handler arguments, decoding path params —
        \\is the remainder.
        \\
    , .{});

    try longLived(gpa);

    if (sink == 0) unreachable; // keeps the work from being optimised away
}

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
