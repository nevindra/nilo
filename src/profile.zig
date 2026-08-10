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

    if (sink == 0) unreachable; // keeps the work from being optimised away
}

fn line(label: []const u8, part: u64, whole: u64) void {
    std.debug.print("  {s:<28}{d:>5}ns {d:>6.1}%\n", .{
        label,
        part / rounds,
        @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole)),
    });
}
