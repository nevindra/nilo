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
const str_mod = @import("nilo_core");
const fail = @import("fail.zig");
const clock = @import("bulkhead.zig").monotonicNanos;
const App = @import("app.zig").App;
const cors = @import("cors.zig");
const websocket = @import("websocket.zig");
const room_mod = @import("room.zig");
const stream_mod = @import("stream.zig");
const framing_mod = @import("framing.zig");
const body_mod = @import("body.zig");
const range_mod = @import("range.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const h2conn = @import("h2conn.zig");
const h2 = @import("h2.zig");
const hpack = @import("hpack.zig");

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
    sink += @intFromBool(app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{}));
    lifetime.end();
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn readHeadOnly() void {
    var in = std.Io.Reader.fixed(request);
    sink += (http1.readHead(&in, .off) catch unreachable).len;
}

/// The head as a parser really meets it: bytes the compiler cannot see.
/// Handed `request` itself, a constant, LLVM folds part of the parse over
/// the known bytes, and a simpler parser folds more of itself away than a
/// stricter one does, so a before-and-after on the constant measured the
/// folding (ADR 231).
fn unseen(comptime head: []const u8) []const u8 {
    const S = struct {
        var bytes: [head.len]u8 = head[0..head.len].*;
    };
    var out: []const u8 = &S.bytes;
    std.mem.doNotOptimizeAway(&out);
    return out;
}

fn parseHeadOnly() void {
    var r = http1.Request{};
    http1.parseHead(unseen(request), &r) catch unreachable;
    sink += r.target.len;
}

/// What a browser sends on a navigation: fifteen lines, most of them long,
/// where `request` is wrk's five. Every check the parser makes per byte or
/// per name is paid in proportion to this one, so a change to the parser is
/// measured on both (ADR 231).
const browser_head = "GET /dashboard/settings?tab=profile HTTP/1.1\r\n" ++
    "Host: app.example.com\r\n" ++
    "Connection: keep-alive\r\n" ++
    "sec-ch-ua: \"Chromium\";v=\"124\", \"Google Chrome\";v=\"124\", \"Not-A.Brand\";v=\"99\"\r\n" ++
    "sec-ch-ua-mobile: ?0\r\n" ++
    "sec-ch-ua-platform: \"Linux\"\r\n" ++
    "Upgrade-Insecure-Requests: 1\r\n" ++
    "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36\r\n" ++
    "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8\r\n" ++
    "Sec-Fetch-Site: same-origin\r\n" ++
    "Sec-Fetch-Mode: navigate\r\n" ++
    "Sec-Fetch-Dest: document\r\n" ++
    "Accept-Encoding: gzip, deflate, br, zstd\r\n" ++
    "Accept-Language: en-US,en;q=0.9\r\n" ++
    "Cookie: session=4f8a2c9e1b7d3a6f0e5c8b2d9a4f7e1c; theme=dark\r\n\r\n";

fn parseBrowserHead() void {
    var r = http1.Request{};
    http1.parseHead(unseen(browser_head), &r) catch unreachable;
    sink += r.target.len;
}

fn copyHead() void {
    sink += (arena.allocator().dupe(u8, request) catch unreachable).len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn matchRoute() void {
    var m: router.Match = undefined;
    if (!app.router.matchInto(.GET, "/users/7", &m)) unreachable;
    sink += m.n_params;
}

fn serialiseBody() void {
    var w = std.Io.Writer.Allocating.initCapacity(arena.allocator(), ctx_mod.json_hint) catch unreachable;
    json_mod.write(&w.writer, Db.find(undefined, 7).?) catch unreachable;
    sink += w.written().len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

fn writeTheResponse() void {
    var out = std.Io.Writer.fixed(&out_buf);
    http1.writeResponse(&out, 200, "OK", "application/json", body_json, .implied, &.{
        .{ .name = "Access-Control-Allow-Origin", .value = "*" },
    }) catch unreachable;
    sink += out.buffered().len;
}

fn arenaRound() void {
    sink += (arena.allocator().alloc(u8, 200) catch unreachable).len;
    _ = arena.reset(.{ .retain_with_limit = arena_keep });
}

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa_state = std.heap.DebugAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // `zig build profile -- --routes <file>` adds one section: matching on a
    // route table somebody really has, rather than on the synthetic ones
    // below. Nothing else takes an argument.
    var routes_file: ?[]const u8 = null;
    var args: std.process.Args.Iterator = .init(init.args);
    _ = args.skip(); // the program's own name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--routes")) {
            routes_file = args.next() orelse return error.RoutesNeedsAFile;
        } else return error.UnknownArgument;
    }

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
    std.debug.print("  {s:<28}{d:>5}ns   {d} bytes, where the one above is {d}\n", .{ "parse a browser's head", bestOf(parseBrowserHead) / rounds, browser_head.len, request.len });
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
    if (routes_file) |file| try routeTable(gpa, file, whole / rounds);
    try serviceScale(gpa);
    try messageRoutes(gpa);
    // A call is answered through the framing only a `-Dhttp2` build has
    // (ADR 220), so without the flag there is no gRPC call to time.
    if (comptime @import("nilo_build").http2) {
        try grpcCalls();
        try http2Gets(whole / rounds);
    } else std.debug.print(
        "\nA gRPC call and a GET over HTTP/2 are timed by `zig build profile -Dhttp2`.\n",
        .{},
    );

    if (sink == 0) unreachable; // keeps the work from being optimised away
}

// ---- a message read in either spelling (ADR 256) ----
//
// One route whose argument is a protobuf message, sent the same two numbers
// as JSON and as protobuf, beside a control: a plain struct of the same
// shape, which is what the JSON half of a message has to cost no more than.

const message_rounds = 300_000;

const SumRequest = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const SumReply = struct {
    pub const wire = .{ .total = 1 };
    total: i32 = 0,
};

fn sumMessage(in: SumRequest) SumReply {
    return .{ .total = in.a + in.b };
}

fn sumPlain(in: struct { a: i32 = 0, b: i32 = 0 }) struct { total: i32 } {
    return .{ .total = in.a + in.b };
}

fn messageRoutes(gpa: std.mem.Allocator) !void {
    var message_app = App.init(gpa);
    defer message_app.deinit();
    try message_app.post("/sum", sumMessage);
    try message_app.post("/plain", sumPlain);
    try message_app.resolveChains();

    const requests = [_]struct { []const u8, []const u8 }{
        .{ "a plain struct, as JSON (the control)", "POST /plain HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":1,\"b\":2}" },
        .{ "a message, as JSON", "POST /sum HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":1,\"b\":2}" },
        .{ "a message, as protobuf", "POST /sum HTTP/1.1\r\nHost: t\r\nContent-Type: application/proto\r\nContent-Length: 4\r\n\r\n\x08\x01\x10\x02" },
    };
    var message_arena = std.heap.ArenaAllocator.init(gpa);
    defer message_arena.deinit();
    std.debug.print("\nOne POST whose body is two numbers, read and answered in process:\n\n", .{});
    for (requests) |r| {
        var best: u64 = std.math.maxInt(u64);
        for (0..reps + 1) |rep| {
            const started = clock();
            for (0..message_rounds) |_| {
                var in = std.Io.Reader.fixed(r[1]);
                var out = std.Io.Writer.fixed(&out_buf);
                sink += @intFromBool(message_app.handleRequest(message_arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{}));
                lifetime.end();
                _ = message_arena.reset(.{ .retain_with_limit = arena_keep });
            }
            const took = clock() - started;
            if (rep > 0 and took < best) best = took;
        }
        std.debug.print("  {s:<40}{d:>5}ns\n", .{ r[0], best / message_rounds });
    }
}

// ---- one service out of several ----
//
// `Registry.get` walks `entries` comparing type names, once per service
// argument per request, and it is on the request path. The roadmap carried
// "it may well be nothing" on it with nothing under the sentence, which is
// the shape this repository has been wrong about before, so it gets a number
// rather than a reading.
//
// The wanted service is registered **last**, so the scan runs to the end
// every time. That is the worst case on purpose — the number to beat, not the
// number to quote. `sameName` compares the pointers first and `@typeName`
// hands back the same literal, so the content compare behind it never fires
// here either, which is also what a real app gets.

const service_rounds = 1_000_000;
const service_counts = [_]usize{ 1, 4, 8, 16, 32 };

/// A family of distinct types, because the registry holds one of each and
/// rejects a second of the same (ADR 002).
fn Svc(comptime n: usize) type {
    return struct { v: usize = n };
}

fn serviceScale(gpa: std.mem.Allocator) !void {
    std.debug.print("\n---- finding one service out of several ----\n\n", .{});
    std.debug.print("  {s:<12}{s:>8}{s:>8}{s:>8}{s:>8}{s:>8}\n", .{ "", "1", "4", "8", "16", "32" });
    std.debug.print("  {s:<12}", .{"registry.get"});
    inline for (service_counts) |n| std.debug.print("{d:>6.1}ns", .{try oneServiceScale(gpa, n)});
    std.debug.print("\n", .{});
}

fn oneServiceScale(gpa: std.mem.Allocator, comptime n: usize) !f64 {
    var r = service_mod.Registry.init(gpa);
    defer r.deinit();

    // One backing value per service. The registry stores the pointer and
    // never reads through it, but a distinct object each is what a real app
    // has and costs nothing to give it here. Every `Svc` is one `usize`, so
    // the cast is size- and alignment-exact.
    var backing: [n]usize = @splat(0);
    inline for (0..n) |i| try r.add(@as(*Svc(i), @ptrCast(&backing[i])));

    const Wanted = Svc(n - 1);

    for (0..service_rounds / 4) |_| sink += @intFromPtr(r.get(*Wanted).?);
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const started = clock();
        for (0..service_rounds) |_| sink += @intFromPtr(r.get(*Wanted).?);
        const took = clock() - started;
        if (took < best) best = took;
    }
    // A float, unlike the router's row: the whole question is whether this is
    // one nanosecond or ten, and integer division would answer it by rounding.
    return @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(service_rounds));
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

    var r = router.Router.init(gpa);
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

    var m: router.Match = undefined;
    for (0..scale_rounds / 4) |_| {
        if (!r.matchInto(method, wanted, &m)) unreachable;
        sink += m.n_params;
    }
    var best: u64 = std.math.maxInt(u64);
    for (0..reps) |_| {
        const started = clock();
        for (0..scale_rounds) |_| {
            if (!r.matchInto(method, wanted, &m)) unreachable;
            sink += m.n_params;
        }
        const took = clock() - started;
        if (took < best) best = took;
    }
    return best / scale_rounds;
}

fn nothing(_: *ctx_mod.Ctx) anyerror!void {}

// ---- a route table somebody has ----
//
// The two sets above start every route with a different word, so the
// router's first-segment key throws out almost all of them. An application
// that mounts everything under one prefix (`/api`) defeats that key entirely:
// every route has the same first segment, and what is left to separate them
// is the method and the segment count. So the number that decides whether
// the router needs a tree is the one for such a table, read from a file.
//
// The file is one route a line, `METHOD /pattern`, params as `:name`; `#`
// starts a comment. Each route is matched against a path of its own shape,
// with `7` for every param, so the figure is the whole table weighted
// evenly, not a traffic mix nobody has measured.

const table_rounds = 20_000;

const Operation = struct {
    method: http1.Method,
    pattern: []const u8,
    path: []const u8,
    ns: u64 = 0,
};

fn routeTable(gpa: std.mem.Allocator, file: []const u8, request_ns: u64) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const text = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), file, gpa, .limited(4 << 20));
    defer gpa.free(text);

    var table: std.ArrayList(Operation) = .empty;
    defer {
        for (table.items) |op| gpa.free(op.path);
        table.deinit(gpa);
    }
    // After `text` and `table`, so it is torn down first: its routes point
    // into `text`.
    var r = router.Router.init(gpa);
    defer r.deinit();

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r");
        if (entry.len == 0 or entry[0] == '#') continue;
        const space = std.mem.indexOfScalar(u8, entry, ' ') orelse return error.RouteLineHasNoPattern;
        const method = std.meta.stringToEnum(http1.Method, entry[0..space]) orelse return error.RouteLineHasNoMethod;
        const pattern = std.mem.trim(u8, entry[space + 1 ..], " ");
        try r.add(method, pattern, nothing);
        try table.append(gpa, .{ .method = method, .pattern = pattern, .path = try pathFor(gpa, pattern) });
    }
    if (table.items.len == 0) return error.RouteFileIsEmpty;

    for (table.items) |*op| {
        var m: router.Match = undefined;
        for (0..table_rounds / 4) |_| {
            if (!r.matchInto(op.method, op.path, &m)) return error.RouteDidNotMatchItsOwnPath;
            sink += m.n_params;
        }
        var best: u64 = std.math.maxInt(u64);
        for (0..reps) |_| {
            const started = clock();
            for (0..table_rounds) |_| {
                if (!r.matchInto(op.method, op.path, &m)) unreachable;
                sink += m.n_params;
            }
            const took = clock() - started;
            if (took < best) best = took;
        }
        op.ns = best / table_rounds;
    }

    var total: u64 = 0;
    var worst: *const Operation = &table.items[0];
    for (table.items) |*op| {
        total += op.ns;
        if (op.ns > worst.ns) worst = op;
    }
    const mean = total / table.items.len;

    const sorted = try gpa.alloc(u64, table.items.len);
    defer gpa.free(sorted);
    for (sorted, table.items) |*ns, op| ns.* = op.ns;
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    const median = sorted[sorted.len / 2];

    std.debug.print("\n---- matching on the route table in {s} ----\n\n", .{file});
    std.debug.print("  {d} routes, each matched against a path of its own shape\n\n", .{table.items.len});
    std.debug.print("  {s:<8}{d:>6}ns {d:>6.1}% of the {d}ns request above\n", .{ "mean", mean, pct(mean, request_ns), request_ns });
    std.debug.print("  {s:<8}{d:>6}ns {d:>6.1}%\n", .{ "median", median, pct(median, request_ns) });
    std.debug.print("  {s:<8}{d:>6}ns {d:>6.1}%  {s} {s}\n", .{ "worst", worst.ns, pct(worst.ns, request_ns), @tagName(worst.method), worst.pattern });
}

/// A path the pattern matches: `7` for a param, `x` for a trailing `*`.
fn pathFor(gpa: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var parts = std.mem.tokenizeScalar(u8, pattern, '/');
    while (parts.next()) |part| {
        try out.append(gpa, '/');
        if (part[0] == ':') {
            try out.append(gpa, '7');
        } else if (std.mem.eql(u8, part, "*")) {
            try out.append(gpa, 'x');
        } else try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '/');
    return out.toOwnedSlice(gpa);
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
    // buffers — so what is left is nilo's work, with no kernel in it.
    var t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(wire[0..frame_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        const got = (try socket.receive()) orelse unreachable;
        sink += got.data.len;
    }
    const ws_full = (clock() - t) / ws_rounds;

    // The same, with no payload. The difference is what the bytes cost.
    t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(empty_wire[0..empty_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        const got = (try socket.receive()) orelse unreachable;
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

    // The shape a chat actually has, which is not the one above: a short
    // line, where the frame's own bytes cost about as much as its payload.
    // The 16 KiB row says what the unmasking is worth; this one says what a
    // real message costs, and it is the one a broadcast multiplies.
    const chat = 48;
    const chat_wire = try gpa.alloc(u8, chat + 14);
    defer gpa.free(chat_wire);
    const chat_len = buildClientFrame(chat_wire, chat);

    t = clock();
    for (0..ws_rounds) |_| {
        var in = std.Io.Reader.fixed(chat_wire[0..chat_len]);
        var out = std.Io.Writer.fixed(away);
        var socket = websocket.Socket{ ._in = &in, ._out = &out, ._stopping = null };
        const got = (try socket.receive()) orelse unreachable;
        sink += got.data.len;
    }
    const ws_chat = (clock() - t) / ws_rounds;

    ops("websocket: frame overhead", ws_empty, null);
    ops("websocket: receive 48 B", ws_chat, null);
    ops("websocket: receive 16 KiB", ws_full, throughput(ws_full - ws_empty, message));
    ops("websocket: send 16 KiB", ws_send, throughput(ws_send, message));

    try roomBroadcast(gpa, away);

    // A streamed response of 200 short pieces, which is the shape a report
    // has: many small writes behind one chunk header per buffer-full.
    var stream_buf: [4 * 1024]u8 = undefined;
    t = clock();
    for (0..piece_rounds) |_| {
        var out = std.Io.Writer.fixed(away);
        var nothing_in = std.Io.Reader.fixed("");
        var framing: framing_mod.Framing = .{ .http1 = .{ .in = &nothing_in, .out = &out, .minor_version = 1 } };
        var open: ?stream_mod.Open = .{ .chunked = true, .drop = false };
        var body = stream_mod.Stream.init(&stream_buf, &framing, null, &open);
        for (0..200) |i| try body.print("{d},wati,{d}\n", .{ i, i * 3 });
        try body.finish();
        sink += out.buffered().len;
    }
    const streamed = (clock() - t) / piece_rounds;

    t = clock();
    for (0..piece_rounds) |_| {
        var out = std.Io.Writer.fixed(away);
        var nothing_in = std.Io.Reader.fixed("");
        var framing: framing_mod.Framing = .{ .http1 = .{ .in = &nothing_in, .out = &out, .minor_version = 1 } };
        var open: ?stream_mod.Open = .{ .chunked = true, .drop = false };
        var events = stream_mod.Events{ .stream = .init(&stream_buf, &framing, null, &open) };
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
    for (0..rounds) |_| sink += @intFromBool(range_mod.parse("bytes=100-200", 1000, true) != .whole);
    const range_ns = (clock() - t) / rounds;

    ops("range: parse one", range_ns, null);
}

/// What a chat line costs a room, which is the number the seats were walked
/// for. A room is sized for the crowd it might hold and holds a handful, so
/// the interesting shape is exactly that: far more seats than occupants.
fn roomBroadcast(gpa: std.mem.Allocator, away: []u8) !void {
    const seats = 1000;
    const here = 8;
    const say_rounds = 20_000;

    var crowd = try room_mod.Room.initWith(gpa, .{ .seats = seats, .backlog = 4 });
    defer crowd.deinit();

    var readers: [here]std.Io.Reader = undefined;
    var writers: [here]std.Io.Writer = undefined;
    var sockets: [here]websocket.Socket = undefined;
    for (0..here) |i| {
        readers[i] = .fixed("");
        writers[i] = .fixed(away);
        sockets[i] = .{ ._in = &readers[i], ._out = &writers[i], ._stopping = null };
        try crowd.join(&sockets[i]);
    }

    const said = "wati: has anybody seen the cat?";

    // Composing one post, framing it once, and handing it to everybody here.
    const t = clock();
    for (0..say_rounds) |_| {
        try crowd.sayText(said);
        sink += crowd.count();
    }
    const say_ns = (clock() - t) / say_rounds;

    // Deliberately no row for delivery. What changed on that side is the
    // number of writes and flushes a burst costs, not the nanoseconds — and a
    // measurement here would be reporting `DebugAllocator` and a fixed
    // writer, neither of which a connection has.
    ops("room: say to 8 of 1,000 seats", say_ns, null);
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

// ---- a unary gRPC call ----
//
// What one call costs on the connection's own fiber, with no Engine: the
// calls run inline, one after another, so this is the protocol's work and the
// App's and nothing of the scheduler's. The header block is one h2load sent
// in steady state against a table of 0 (ADR 220), 89 bytes of Huffman-coded
// literals; the message is HttpArena's `SumRequest{a=1, b=2}`.

const grpc_calls = 1000;
const grpc_reps = 30;

const h2load_block = [_]u8{
    0x04, 0x99, 0x62, 0x32, 0xd4, 0x49, 0xe9, 0x1d, 0x9d, 0x57, 0xba, 0x5a, 0x89, 0x3d, 0x23, 0xb3,
    0xae, 0xe2, 0xd9, 0xdc, 0xc4, 0x2b, 0x18, 0x8a, 0x9d, 0xd6, 0xd3, 0x86, 0x01, 0x8b, 0x08, 0x9d,
    0x5c, 0x0b, 0x81, 0x70, 0xdc, 0x6c, 0x00, 0x70, 0x3f, 0x83, 0x0f, 0x2b, 0x8f, 0x9c, 0x54, 0x1c,
    0x72, 0x29, 0x54, 0xd3, 0xa5, 0x35, 0x89, 0x80, 0xae, 0xdb, 0xeb, 0x83, 0x0f, 0x10, 0x8b, 0x1d,
    0x75, 0xd0, 0x62, 0x0d, 0x26, 0x3d, 0x4c, 0x4d, 0x65, 0x64, 0x00, 0x02, 0x74, 0x65, 0x86, 0x4d,
    0x83, 0x35, 0x05, 0xb1, 0x1f, 0x0f, 0x0d, 0x01, 0x39,
};
const sum_message = [_]u8{ 0, 0, 0, 0, 4, 0x08, 0x01, 0x10, 0x02 };

/// The call the App is handed for that block, as `h2conn.zig` writes it.
const grpc_call: framing_mod.Call = .{
    .method = "POST",
    .target = "/benchmark.BenchmarkService/GetSum",
    .head = "\nhost: 127.0.0.1:50061\r\nuser-agent: h2load nghttp2/1.59.0\r\n" ++
        "content-type: application/grpc\r\ncontent-length: 4\r\n\r\n",
    .body = "\x08\x01\x10\x02",
};

fn getSum(c: *ctx_mod.Ctx) anyerror!void {
    const body = (try c.body()).view();
    // Two one-byte varints are all this benchmark ever sends.
    const reply = [_]u8{ 0x08, body[1] + body[3] };
    try c.send(200, "application/grpc", &reply);
}

fn grpcCalls() !void {
    const gpa = std.heap.smp_allocator;
    var grpc_app = App.init(gpa);
    defer grpc_app.deinit();
    try grpc_app.post("/benchmark.BenchmarkService/GetSum", getSum);
    try grpc_app.resolveChains();

    // The client's side of one connection: the preface, its SETTINGS, the
    // ACK of the server's, then the calls. The first block carries the size
    // update to 0 that the ACK obliges it to send, which h2load sends once.
    var wire: std.Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    const w = &wire.writer;
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{});
    try h2.writeSettingsAck(w);
    var id: u31 = 1;
    for (0..grpc_calls) |i| {
        const update: []const u8 = if (i == 0) &.{0x20} else &.{};
        try h2.writeHeader(w, update.len + h2load_block.len, .headers, h2.Flags.end_headers, id);
        try w.writeAll(update);
        try w.writeAll(&h2load_block);
        try h2.writeHeader(w, sum_message.len, .data, h2.Flags.end_stream, id);
        try w.writeAll(&sum_message);
        id += 2;
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 256 * grpc_calls);
    defer out.deinit();
    var whole: u64 = std.math.maxInt(u64);
    for (0..grpc_reps + 3) |rep| {
        out.clearRetainingCapacity();
        var in: std.Io.Reader = .fixed(wire.written());
        const started = clock();
        h2conn.serveConnection(grpc_app.grpcHost(), &in, &out.writer, .off, .off, .{});
        const took = clock() - started;
        if (rep >= 3 and took < whole) whole = took;
    }
    sink += out.written().len;
    const per_call = whole / grpc_calls;

    // HPACK: the one block, decoded with the table at 0.
    var decoder = hpack.Decoder.init(gpa);
    defer decoder.deinit();
    var fields: std.ArrayList(hpack.Field) = .empty;
    defer fields.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var decode_best: u64 = std.math.maxInt(u64);
    for (0..grpc_reps) |_| {
        const started = clock();
        for (0..grpc_calls) |_| {
            fields.clearRetainingCapacity();
            _ = decoder.decode(&h2load_block, scratch.allocator(), &fields, 1 << 16) catch unreachable;
            _ = scratch.reset(.retain_capacity);
        }
        decode_best = @min(decode_best, clock() - started);
    }
    sink += fields.items.len;

    // The App's share: the call handed over as `h2conn.zig` hands it, and its
    // answer collected, the way a call reaches it.
    var app_arena = std.heap.ArenaAllocator.init(gpa);
    defer app_arena.deinit();
    var app_best: u64 = std.math.maxInt(u64);
    const host = grpc_app.grpcHost();
    for (0..grpc_reps) |_| {
        const started = clock();
        for (0..grpc_calls) |_| {
            var request_lifetime = str_mod.Lifetime{};
            var request_in_flight = fail.InFlight{};
            var collected: framing_mod.Collected = .{ .arena = app_arena.allocator(), .front = 5 };
            host.handle(host.ptr, app_arena.allocator(), &request_lifetime, &request_in_flight, grpc_call, &collected, .{}, 0);
            sink += collected.status;
            request_lifetime.end();
            _ = app_arena.reset(.{ .retain_with_limit = arena_keep });
        }
        app_best = @min(app_best, clock() - started);
    }

    std.debug.print(
        \\
        \\A unary gRPC call over h2c, {d}ns each end to end on the connection's
        \\fiber: h2load's header block, HttpArena's GetSum, answered inline.
        \\
        \\  HPACK decode of the header block{d:>8}ns {d:>6.1}%
        \\  the App, handed the call       {d:>7}ns {d:>6.1}%
        \\  the rest: frames, the call, answer{d:>6}ns {d:>6.1}%
        \\
    , .{
        per_call,
        decode_best / grpc_calls,
        pct(decode_best / grpc_calls, per_call),
        app_best / grpc_calls,
        pct(app_best / grpc_calls, per_call),
        per_call -| (decode_best + app_best) / grpc_calls,
        pct(per_call -| (decode_best + app_best) / grpc_calls, per_call),
    });
}

// ---- a GET over HTTP/2 beside the same GET over HTTP/1.1 (ADR 259) ----

const get_requests = 1000;

/// The head of `GET /users/7` as `h2conn.zig` hands it to the App: what wrk
/// sends on HTTP/1.1, without the `Connection` line, and the length of no body.
const get_call: framing_mod.Call = .{
    .method = "GET",
    .target = "/users/7",
    .head = "\nhost: example.dev\r\nuser-agent: wrk\r\naccept: */*\r\naccept-encoding: gzip\r\ncontent-length: 0\r\n\r\n",
    .body = "",
};

/// The routed GET of the main figure, carried as HTTP/2 on one connection and
/// answered through the connection's own fiber (no Engine runs here, so no
/// fiber is spawned: `spawnLocal` has nowhere to put one and the request runs
/// inline). Next to it, what the HTTP/1.1 figure above is.
fn http2Gets(h1_ns: u64) !void {
    const gpa = std.heap.smp_allocator;
    var block: std.Io.Writer.Allocating = .init(gpa);
    defer block.deinit();
    const b = &block.writer;
    try b.writeAll("\x82\x86"); // GET, http
    try hpack.writeLiteral(b, ":path", "/users/7");
    try hpack.writeLiteral(b, ":authority", "example.dev");
    try hpack.writeLiteral(b, "user-agent", "wrk");
    try hpack.writeLiteral(b, "accept", "*/*");
    try hpack.writeLiteral(b, "accept-encoding", "gzip");

    var wire: std.Io.Writer.Allocating = .init(gpa);
    defer wire.deinit();
    const w = &wire.writer;
    // Windows as wide as a client that reads at once leaves them, so what is
    // timed is the framing and not a wait for a WINDOW_UPDATE.
    try w.writeAll(h2.preface);
    try h2.writeSettings(w, &.{.{ .initial_window_size, 1 << 30 }});
    try h2.writeSettingsAck(w);
    try h2.writeWindowUpdate(w, 0, (1 << 31) - 1 - h2.default_window);
    var id: u31 = 1;
    for (0..get_requests) |i| {
        // The first block opens with the size update to 0 that the ACK obliges
        // a client to send.
        const update: []const u8 = if (i == 0) &.{0x20} else &.{};
        try h2.writeHeader(w, update.len + block.written().len, .headers, h2.Flags.end_headers | h2.Flags.end_stream, id);
        try w.writeAll(update);
        try w.writeAll(block.written());
        id += 2;
    }

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 2048 * get_requests);
    defer out.deinit();
    var whole: u64 = std.math.maxInt(u64);
    for (0..grpc_reps + 3) |rep| {
        out.clearRetainingCapacity();
        var in: std.Io.Reader = .fixed(wire.written());
        const started = clock();
        h2conn.serveConnection(app.grpcHost(), &in, &out.writer, .off, .off, .{});
        const took = clock() - started;
        if (rep >= 3 and took < whole) whole = took;
    }
    sink += out.written().len;
    const per_get = whole / get_requests;

    // The block, decoded with the table at 0.
    var decoder = hpack.Decoder.init(gpa);
    defer decoder.deinit();
    var fields: std.ArrayList(hpack.Field) = .empty;
    defer fields.deinit(gpa);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var decode_best: u64 = std.math.maxInt(u64);
    for (0..grpc_reps) |_| {
        const started = clock();
        for (0..get_requests) |_| {
            fields.clearRetainingCapacity();
            _ = decoder.decode(block.written(), scratch.allocator(), &fields, 1 << 16) catch unreachable;
            _ = scratch.reset(.retain_capacity);
        }
        decode_best = @min(decode_best, clock() - started);
    }
    sink += fields.items.len;

    // The App's share: the request handed over as `h2conn.zig` hands it.
    var app_arena = std.heap.ArenaAllocator.init(gpa);
    defer app_arena.deinit();
    var app_best: u64 = std.math.maxInt(u64);
    const host = app.grpcHost();
    for (0..grpc_reps) |_| {
        const started = clock();
        for (0..get_requests) |_| {
            var request_lifetime = str_mod.Lifetime{};
            var request_in_flight = fail.InFlight{};
            var collected: framing_mod.Collected = .{ .arena = app_arena.allocator(), .lines = true };
            host.handle(host.ptr, app_arena.allocator(), &request_lifetime, &request_in_flight, get_call, &collected, .{}, 0);
            sink += collected.status;
            request_lifetime.end();
            _ = app_arena.reset(.{ .retain_with_limit = arena_keep });
        }
        app_best = @min(app_best, clock() - started);
    }

    std.debug.print(
        \\
        \\The same routed GET over HTTP/2, {d}ns each on one connection's fiber
        \\(HTTP/1.1's is {d}ns above, with no frames and no connection around it),
        \\answered inline: no Engine runs here, so what a fiber spawn costs is
        \\not in it.
        \\
        \\  HPACK decode of the header block{d:>8}ns {d:>6.1}%
        \\  the App, handed the request    {d:>7}ns {d:>6.1}%
        \\  the rest: frames, head, answer{d:>9}ns {d:>6.1}%
        \\
    , .{
        per_get,
        h1_ns,
        decode_best / get_requests,
        pct(decode_best / get_requests, per_get),
        app_best / get_requests,
        pct(app_best / get_requests, per_get),
        per_get -| (decode_best + app_best) / get_requests,
        pct(per_get -| (decode_best + app_best) / get_requests, per_get),
    });
}

fn pct(part: u64, whole: u64) f64 {
    return @as(f64, @floatFromInt(part)) * 100.0 / @as(f64, @floatFromInt(whole));
}
