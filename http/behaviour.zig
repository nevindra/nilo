//! Driving one App end to end: send a request, read the answer back.
//!
//! Its own file rather than the bottom of one of the three it exercises.
//! A test here sends bytes in and asserts on the bytes that come out, so it
//! crosses `app.zig` (the route was registered), `wiring.zig` (the chain was
//! resolved) and `serve.zig` (the request was answered) in every case —
//! putting it under any one of them would be picking a file by coin toss.
//! What each of those three keeps at its own bottom is the tests that never
//! leave it.
//!
//! `http.zig`'s test block imports this file. Without that line none of it
//! runs, and nothing else would say so.

const std = @import("std");
const app_mod = @import("app.zig");
const serve = @import("serve.zig");
const wiring = @import("wiring.zig");
const bulkhead = @import("bulkhead.zig");
const http1 = @import("http1.zig");
const date_mod = @import("date.zig");
const router = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("nilo_core");
const typed = @import("typed.zig");
const fail = @import("fail.zig");
const mw = @import("middleware.zig");
const static_mod = @import("static.zig");
const proxies_mod = @import("proxies.zig");
const openapi = @import("openapi.zig");
const budget = @import("budget.zig");
const watchdog = @import("watchdog.zig");
const websocket = @import("websocket.zig");
const room_mod = @import("room.zig");
const rooms_mod = @import("rooms.zig");
const metrics_mod = @import("metrics.zig");
const nilo_testing = @import("testing.zig");
const form_mod = @import("form.zig");
const bound_mod = @import("bound.zig");
const redirect_mod = @import("redirect.zig");
const cors = @import("cors.zig");
const csrf = @import("csrf.zig");
const secure = @import("secure.zig");
const trace_mod = @import("trace.zig");
const allowance = @import("allowance.zig");
const patch_mod = @import("patch.zig");
const h2test = @import("h2test.zig");
const hpack = @import("hpack.zig");
const h2 = @import("h2.zig");
const framing_mod = @import("framing.zig");

const App = app_mod.App;
const Group = app_mod.Group;
const Ctx = ctx_mod.Ctx;
const Str = str_mod.Str;
const testing = std.testing;

// Reached for only by the tests below, which is why they are here rather
// than at the top: `testing.zig` imports this file, and the tests are the
// one place that wants to go back the other way.

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    /// Room for the largest answer a test reads back whole: the file the
    /// two-framing table serves is 72,000 bytes.
    buf: [80_000]u8 = undefined,
    restore_log_level: std.log.Level,
    /// Who these requests come from. No socket by default, which is what
    /// every test that does not care about the address wants.
    peer: bulkhead.Peer = .{},
    /// The last request, copied so it is writable the way a connection's
    /// read buffer is: a WebSocket message is unmasked in place (ADR 216),
    /// and a string literal is read-only under LLVM. Kept until the next
    /// send, because `in_flight` still points into it.
    input: []u8 = &.{},

    fn init() Harness {
        // Several tests below drive a handler into failure on purpose, and
        // App logs each one — correctly, but to the test runner's stderr,
        // where it makes a passing suite print `failed command`. The lines
        // are the behaviour under test, not news, so they are turned off
        // for as long as the harness is up.
        const previous = testing.log_level;
        testing.log_level = .err;
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .restore_log_level = previous,
        };
    }

    fn deinit(self: *Harness) void {
        testing.log_level = self.restore_log_level;
        testing.allocator.free(self.input);
        self.arena.deinit();
    }

    /// Resolve middleware chains the way `listen()` would, then send.
    fn ready(self: *Harness, app: *App) !void {
        _ = self;
        try app.resolveChains();
    }

    /// Whether a failure response says `wanted`, read out of the JSON body
    /// rather than off the wire (ADR 024). A test then spells the message
    /// the way a person reads it, instead of the way JSON escapes it — and
    /// gets "the body really was JSON" asserted for free.
    fn saysFailure(response: []const u8, wanted: []const u8) !bool {
        const blank = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return false;
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            testing.allocator,
            response[blank + 4 ..],
            .{},
        );
        defer parsed.deinit();
        const message = (parsed.value.object.get("error") orelse return false).string;
        return std.mem.indexOf(u8, message, wanted) != null;
    }

    fn send(self: *Harness, app: *App, request: []const u8) struct { response: []const u8, keep_alive: bool } {
        testing.allocator.free(self.input);
        self.input = testing.allocator.dupe(u8, request) catch @panic("OOM");
        var in = std.Io.Reader.fixed(self.input);
        var out = std.Io.Writer.fixed(&self.buf);
        const keep_alive = app.handleRequest(self.arena.allocator(), &self.lifetime, &self.in_flight, &in, &out, .off, .off, self.peer);
        self.lifetime.end();
        _ = self.arena.reset(.retain_capacity);
        return .{ .response = out.buffered(), .keep_alive = keep_alive };
    }
};

/// Four kilobytes of text a client would rather have gzipped.
fn sendLongText(c: *Ctx) anyerror!void {
    try c.send(200, "text/plain", repeat("the quick brown fox jumps over the lazy dog; ", 96));
}

fn testGetUser(c: *Ctx) anyerror!void {
    const id = try c.param("id").?.int(u32);
    try c.sendJson(200, .{ .id = id, .name = "tester" });
}

fn testEchoJson(c: *Ctx) anyerror!void {
    const Incoming = struct { message: []const u8 };
    const incoming = try c.json(Incoming);
    try c.sendJson(201, .{ .echo = incoming.message });
}

fn testExplode(_: *Ctx) anyerror!void {
    return error.DeliberateExplosion;
}

fn testQuiet(_: *Ctx) anyerror!void {}

test "a GET with a path param answers JSON and the connection continues" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testGetUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":42,\"name\":\"tester\"}") != null);
}

test "POST JSON in, JSON out" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", testEchoJson);

    var h = Harness.init();
    defer h.deinit();
    const body = "{\"message\":\"hello\"}";
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const result = h.send(&app, request);

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"echo\":\"hello\"}") != null);
}

test "an unknown route answers 404 and the body is still discarded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/here", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /nowhere HTTP/1.1\r\nHost: t\r\nContent-Length: 4\r\n\r\nxxxxGET /here HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
}

test "a request nobody else would answer is refused before it reaches a route" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/here", testQuiet);
    try app.post("/here", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    // No `Host`, and two of them. RFC 9112 §3.2 makes both a 400, the front
    // end in front of nilo refuses both, and the route plainly exists — so
    // answering one is nilo agreeing to read a request nobody else agreed to.
    for ([_][]const u8{
        "GET /here HTTP/1.1\r\n\r\n",
        "GET /here HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n",
    }) |request| {
        const result = h.send(&app, request);
        try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400"));
        try testing.expect(!result.keep_alive);
    }

    // A final coding nilo cannot decode. What used to happen is the worse
    // half: the head was answered as a request with no body at all, and the
    // bytes behind it — a whole request here — were still in the read buffer
    // for the next turn of the connection loop to parse. That is request
    // smuggling, and the connection closing is what makes it impossible.
    const smuggled = h.send(
        &app,
        "POST /here HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: gzip\r\n\r\n" ++
            "GET /here HTTP/1.1\r\nHost: t\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, smuggled.response, "HTTP/1.1 400"));
    try testing.expect(!smuggled.keep_alive);
    // One answer, not two.
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOfPos(u8, smuggled.response, 1, "HTTP/1.1 "),
    );
}

test "a handler can walk every header, including one that was sent twice" {
    const Walk = struct {
        fn run(c: *Ctx) anyerror!void {
            var out = std.ArrayList(u8).empty;
            defer out.deinit(testing.allocator);

            var it = c.headers();
            while (it.next()) |h| {
                try out.appendSlice(testing.allocator, h.name.view());
                try out.append(testing.allocator, '=');
                try out.appendSlice(testing.allocator, h.value.view());
                try out.append(testing.allocator, ';');
            }
            try c.sendText(200, out.items);
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/walk", Walk.run);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "GET /walk HTTP/1.1\r\nHost: t\r\nAccept:  text/plain \r\n" ++
            "X-Trace: one\r\nX-Trace: two\r\n\r\n",
    );

    // Arrival order, the value trimmed of the optional whitespace either side
    // of it, and the request line skipped.
    try testing.expect(std.mem.endsWith(
        u8,
        result.response,
        "Host=t;Accept=text/plain;X-Trace=one;X-Trace=two;",
    ));
    // `header` answers with the first and cannot say there was a second, which
    // is half of why the iterator exists.
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Trace=two;") != null);
}

test "an unrecognised error becomes a 500, but the connection stays alive" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/explode", testExplode);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /explode HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 Internal Server Error\r\n"));
    // Not a single byte of a response had gone out when the handler
    // failed, so the connection is still clean and may be reused.
    try testing.expect(result.keep_alive);
    // The internal error name does not leak to the client.
    try testing.expect(std.mem.indexOf(u8, result.response, "DeliberateExplosion") == null);
}

test "a handler that fails after answering closes the connection" {
    const Partial = struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "half");
            return error.DeliberateExplosion;
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/half", Partial.run);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /half HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(!result.keep_alive);
}

test "a quiet handler answers an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/quiet", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    defer date_mod.pinned = null;
    date_mod.pinned = 0;
    const result = h.send(&app, "GET /quiet HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(result.keep_alive);
    // No Content-Type: there is no content to give one to.
    try testing.expect(std.mem.startsWith(
        u8,
        result.response,
        "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Length: 0\r\n",
    ));
}

fn testHeaderAndQuery(c: *Ctx) anyerror!void {
    try testing.expectEqualStrings("zig", c.query("word").?.view());
    try testing.expectEqualStrings("", c.query("empty").?.view());
    try testing.expect(c.query("absent") == null);
    try testing.expectEqualStrings("secret", c.header("X-Token").?.view());
    try testing.expectEqualStrings("secret", c.header("x-token").?.view());
    try c.sendText(200, "ok");
}

test "query params and headers are readable from Ctx" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", testHeaderAndQuery);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /search?word=zig&empty= HTTP/1.1\r\nHost: t\r\nX-Token: secret\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200"));
}

const Kind = enum { comment, event };

const Filter = struct {
    tag: []const str_mod.Str = &.{},
    kind: []const Kind = &.{},
};

fn filtered(arena: std.mem.Allocator, q: typed.Query(Filter)) ![]const u8 {
    // Written out rather than counted, so a test can tell "read one value"
    // from "read the first of two". The request arena, so the answer lives
    // exactly as long as the request that asked for it.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (q.value.tag) |t| w.print("{s};", .{t.view()}) catch {};
    for (q.value.kind) |k| w.print("{s};", .{@tagName(k)}) catch {};
    return arena.dupe(u8, w.buffered());
}

test "a query parameter that is a list is read both ways it can arrive" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", filtered);

    var h = Harness.init();
    defer h.deinit();

    // Comma-joined, which is what nilo writes into the document and what a
    // client generated from it sends (ADR 132).
    const commas = h.send(&app, "GET /feed?tag=a,b HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, commas.response, "a;b;") != null);

    // Repeated, which is what half the clients in the world send anyway. A
    // server that took the first and dropped the rest would answer with
    // fewer rows, which reads exactly like a filter that worked.
    const repeated = h.send(&app, "GET /feed?tag=a&tag=b HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, repeated.response, "a;b;") != null);

    // And both at once, because nothing stops a client doing that either.
    const both = h.send(&app, "GET /feed?tag=a,b&tag=c HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, both.response, "a;b;c;") != null);
}

test "a list nobody sent is the empty list, and a bad value in one is a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", filtered);

    var h = Harness.init();
    defer h.deinit();

    // Absent is empty rather than a refusal: every filter written against a
    // list already means "no filter" by not sending one.
    const none = h.send(&app, "GET /feed HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, none.response, "HTTP/1.1 200"));

    // And so is a key with nothing after it, which is what an empty text box
    // submits.
    const empty = h.send(&app, "GET /feed?tag= HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, empty.response, "HTTP/1.1 200"));

    // An element that will not convert is the same 400 a scalar gets, which
    // is what makes a list of enums worth having: the set is in the document
    // and the refusal happens before the handler runs.
    const wrong = h.send(&app, "GET /feed?kind=comment,nonsense HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400"));
}

test "a list query parameter says on the document which spelling it takes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/feed", filtered);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const params = parsed.value.object.get("paths").?.object
        .get("/feed").?.object.get("get").?.object.get("parameters").?.array.items;
    const tag = params[0].object;
    try testing.expectEqualStrings("tag", tag.get("name").?.string);
    // The half a convention held in a private helper could not state.
    try testing.expectEqualStrings("form", tag.get("style").?.string);
    try testing.expect(!tag.get("explode").?.bool);
    try testing.expectEqualStrings("array", tag.get("schema").?.object.get("type").?.string);
    // A list is never required: nothing sent is the empty list.
    try testing.expect(!tag.get("required").?.bool);

    // And the values of an enum list are in the document, which is the thing
    // a `commaList` helper in the caller could never put there.
    const kind = params[1].object;
    try testing.expect(kind.get("schema").?.object.get("items").?.object.get("enum") != null);
}

fn whoIsAsking(actor: typed.FromHeader("X-Staff-Id", u32)) !u32 {
    return actor.value;
}

fn maybeAsking(actor: typed.FromHeader("X-Staff-Id", ?u32)) !u32 {
    return actor.value orelse 0;
}

test "a header a handler asks for is read into the type it asked for" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/asking", whoIsAsking);

    var h = Harness.init();
    defer h.deinit();

    const found = h.send(&app, "GET /asking HTTP/1.1\r\nHost: t\r\nX-Staff-Id: 42\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, found.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, found.response, "42"));

    // The name is matched the way `c.header` matches it, which is the way the
    // wire works: a client that sends it lower case is not sending a
    // different header.
    const lower = h.send(&app, "GET /asking HTTP/1.1\r\nHost: t\r\nx-staff-id: 42\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, lower.response, "HTTP/1.1 200"));
}

test "a header that is required and absent is a 400 naming it, not a surprise zero" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/asking", whoIsAsking);
    try app.get("/maybe", maybeAsking);

    var h = Harness.init();
    defer h.deinit();

    const missing = h.send(&app, "GET /asking HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "X-Staff-Id") != null);

    // Text that will not convert is the same 400 a query param gets.
    const nonsense = h.send(&app, "GET /asking HTTP/1.1\r\nHost: t\r\nX-Staff-Id: wati\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nonsense.response, "HTTP/1.1 400"));

    // And an optional one absent is null rather than a refusal, which is the
    // rule a query field with a `?` already follows.
    const optional = h.send(&app, "GET /maybe HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, optional.response, "HTTP/1.1 200"));
}

test "a header a handler asks for is a header the document promises" {
    // The whole point of the wrapper: `c.header` reads one and the document
    // says nothing, so a generated client cannot know to send it (ADR 131).
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/asking", whoIsAsking);
    try app.get("/maybe", maybeAsking);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    const required = paths.get("/asking").?.object.get("get").?.object
        .get("parameters").?.array.items[0].object;
    try testing.expectEqualStrings("X-Staff-Id", required.get("name").?.string);
    try testing.expectEqualStrings("header", required.get("in").?.string);
    try testing.expect(required.get("required").?.bool);
    try testing.expectEqualStrings("integer", required.get("schema").?.object.get("type").?.string);

    // `required` follows the optional, the way a query field's does.
    const optional = paths.get("/maybe").?.object.get("get").?.object
        .get("parameters").?.array.items[0].object;
    try testing.expect(!optional.get("required").?.bool);
}

const authorization_mod = @import("authorization.zig");
const Authorization = authorization_mod.Authorization;

fn whoseToken(auth: Authorization(.bearer)) !Str {
    return auth.value;
}

fn whoSignedIn(auth: Authorization(.{ .basic = "admin" })) ![]const u8 {
    if (!std.mem.eql(u8, auth.password.view(), "hunter2")) {
        return Authorization(.{ .basic = "admin" }).refuse("wrong password for {s}", .{auth.user.view()});
    }
    return auth.user.view();
}

test "a bearer token a handler asks for is the bytes after the scheme, whatever case the scheme came in" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/whose", whoseToken);

    var h = Harness.init();
    defer h.deinit();

    const plain = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer abc.def.ghi\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, plain.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, plain.response, "abc.def.ghi"));

    // RFC 9110 §11.1: the scheme is case-insensitive. This is the first of
    // the two mistakes the hand-written version made (ADR 153).
    const lower = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\nAuthorization: bearer abc.def.ghi\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, lower.response, "HTTP/1.1 200"));

    // And blanks are not part of the token.
    const loose = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\nAuthorization:   Bearer   abc.def.ghi  \r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, loose.response, "abc.def.ghi"));
}

test "a missing or mismatched Authorization header is a 401 that says what would have done" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/whose", whoseToken);

    var h = Harness.init();
    defer h.deinit();

    // The second mistake: a 401 without `WWW-Authenticate` (RFC 9110 §15.5.2).
    const missing = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "\r\nWWW-Authenticate: Bearer\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, missing.response, "Bearer") != null);

    const basic = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\nAuthorization: Basic YTpi\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, basic.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, basic.response, "WWW-Authenticate: Bearer") != null);
    try testing.expect(std.mem.indexOf(u8, basic.response, "something else") != null);

    const empty = h.send(&app, "GET /whose HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, empty.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, empty.response, "nothing after it") != null);
}

test "basic credentials are decoded and split at the first colon, and a refusal after reading carries the realm" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/admin", whoSignedIn);

    var h = Harness.init();
    defer h.deinit();

    // "wati:hunter2"
    const ok = h.send(&app, "GET /admin HTTP/1.1\r\nHost: t\r\nAuthorization: Basic d2F0aTpodW50ZXIy\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, ok.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, ok.response, "wati"));

    // "wati:nope" — the handler's own refusal, through `T.refuse`, and the
    // challenge is on it without the handler holding a Ctx.
    const wrong = h.send(&app, "GET /admin HTTP/1.1\r\nHost: t\r\nAuthorization: Basic d2F0aTpub3Bl\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, wrong.response, "WWW-Authenticate: Basic realm=\"admin\"") != null);
    try testing.expect(std.mem.indexOf(u8, wrong.response, "wrong password for wati") != null);

    // "wati" — no colon, which RFC 7617 does not allow.
    const nocolon = h.send(&app, "GET /admin HTTP/1.1\r\nHost: t\r\nAuthorization: Basic d2F0aQ==\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nocolon.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, nocolon.response, "no colon") != null);

    const junk = h.send(&app, "GET /admin HTTP/1.1\r\nHost: t\r\nAuthorization: Basic !!!\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, junk.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, junk.response, "not base64") != null);

    // And absent carries the realm too, which is what makes a browser prompt.
    const missing = h.send(&app, "GET /admin HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, missing.response, "WWW-Authenticate: Basic realm=\"admin\"") != null);
}

const TokenHolder = struct {
    pub const nilo_resolve = fromHeader;

    token: Str,

    fn fromHeader(c: *ctx_mod.Ctx) !TokenHolder {
        const auth = try c.authorization(.bearer);
        return .{ .token = auth.value };
    }
};

fn resolvedToken(holder: TokenHolder) !Str {
    return holder.token;
}

test "a resolver reads the same header through the Ctx, and its 401 carries the same challenge" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/resolved", resolvedToken);

    var h = Harness.init();
    defer h.deinit();

    const ok = h.send(&app, "GET /resolved HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer t0k\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, ok.response, "t0k"));

    const missing = h.send(&app, "GET /resolved HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 401"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "WWW-Authenticate: Bearer") != null);
}

test "an Authorization a handler asks for is a security scheme the document promises, and a 401" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/whose", whoseToken);
    try app.get("/admin", whoSignedIn);
    try app.get("/asking", whoIsAsking);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    const whose = paths.get("/whose").?.object.get("get").?.object;
    const requirement = whose.get("security").?.array.items[0].object;
    try testing.expect(requirement.get("bearerAuth") != null);
    try testing.expect(whose.get("responses").?.object.get("401") != null);
    // Not a parameter: a generated client signs in, it does not fill a field.
    try testing.expect(whose.get("parameters") == null);

    const admin = paths.get("/admin").?.object.get("get").?.object;
    try testing.expect(admin.get("security").?.array.items[0].object.get("basicAuth") != null);

    // A route with no Authorization in its signature promises none.
    const asking = paths.get("/asking").?.object.get("get").?.object;
    try testing.expect(asking.get("security") == null);
    try testing.expect(asking.get("responses").?.object.get("401") == null);

    const schemes = parsed.value.object.get("components").?.object.get("securitySchemes").?.object;
    try testing.expectEqualStrings("bearer", schemes.get("bearerAuth").?.object.get("scheme").?.string);
    try testing.expectEqualStrings("basic", schemes.get("basicAuth").?.object.get("scheme").?.string);
}

fn requireCookie(c: *Ctx, next: mw.Next) anyerror!void {
    if (c.cookie("session") == null) return fail.unauthorized("sign in first", .{});
    try next.run(c);
}

test "a guard declared on a cookie is a security scheme on every route it is in front of, and none it is not" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    // The shape ADR 153 exists for: a prefix behind a session, two routes
    // inside it that cannot be, one outside that wants it anyway — and one
    // that asks for a header on top of the cookie.
    const api = app.group("/api");
    try api.use(requireCookie);
    try api.get("/me", whoIsAsking);
    try api.get("/whose", whoseToken);
    const open = api.without(requireCookie);
    try open.post("/sign-in", testQuiet);
    try app.get("/asking", whoIsAsking);
    try app.with(requireCookie).get("/mine", whoIsAsking);
    try app.guard(requireCookie, "session");
    // Declared once: the program has one cookie.
    try testing.expectError(error.GuardAlreadyDeclared, app.guard(requireCookie, "other"));

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;

    // Under the prefix: the cookie, and the 401 the guard sends.
    const me = paths.get("/api/me").?.object.get("get").?.object;
    try testing.expect(me.get("security").?.array.items[0].object.get("cookieAuth") != null);
    try testing.expect(me.get("responses").?.object.get("401") != null);

    // The cookie and the header, in one requirement: both, not either.
    const whose = paths.get("/api/whose").?.object.get("get").?.object;
    const both = whose.get("security").?.array.items[0].object;
    try testing.expect(both.get("cookieAuth") != null);
    try testing.expect(both.get("bearerAuth") != null);
    try testing.expectEqual(@as(usize, 2), both.count());

    // The exception `without` wrote, and the route outside the prefix.
    const sign_in = paths.get("/api/sign-in").?.object.get("post").?.object;
    try testing.expect(sign_in.get("security") == null);
    try testing.expect(sign_in.get("responses").?.object.get("401") == null);
    const asking = paths.get("/asking").?.object.get("get").?.object;
    try testing.expect(asking.get("security") == null);

    // A `with` on one route counts the same as a `use` on a group.
    const mine = paths.get("/mine").?.object.get("get").?.object;
    try testing.expect(mine.get("security").?.array.items[0].object.get("cookieAuth") != null);

    const scheme = parsed.value.object.get("components").?.object
        .get("securitySchemes").?.object.get("cookieAuth").?.object;
    try testing.expectEqualStrings("apiKey", scheme.get("type").?.string);
    try testing.expectEqualStrings("cookie", scheme.get("in").?.string);
    try testing.expectEqualStrings("session", scheme.get("name").?.string);
}

test "a guard declared on a middleware in front of nothing writes no cookie scheme" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/asking", whoIsAsking);
    try app.guard(requireCookie, "session");

    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(u8, json, "cookieAuth") == null);
    try testing.expect(std.mem.indexOf(u8, json, "securitySchemes") == null);
}

test "a document with no Authorization anywhere lists no security scheme" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/asking", whoIsAsking);

    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(u8, json, "securitySchemes") == null);
}

// ---- the health route (ADR 154) ----

const ProbePool = struct {
    up: bool,

    pub fn nilo_ready(self: *ProbePool, _: *str_mod.AnyScope) ?[]const u8 {
        return if (self.up) null else "the database is not answering";
    }
};

test "the health route is ok while every service is ready, and names the one that is not" {
    var pool = ProbePool{ .up = true };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&pool);
    try app.health("/healthz");

    var h = Harness.init();
    defer h.deinit();

    const ok = h.send(&app, "GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, ok.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, ok.response, "{\"status\":\"ok\"}"));
    // A health answer a proxy remembers is about the past.
    try testing.expect(std.mem.indexOf(u8, ok.response, "Cache-Control: no-store") != null);

    pool.up = false;
    const down = h.send(&app, "GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, down.response, "HTTP/1.1 503"));
    try testing.expect(std.mem.indexOf(u8, down.response, "\"service\":\"behaviour.ProbePool\"") != null);
    try testing.expect(std.mem.indexOf(u8, down.response, "\"why\":\"the database is not answering\"") != null);

    // HEAD is what some balancers send, and it gets the status with no body.
    const head = h.send(&app, "HEAD /healthz HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, head.response, "HTTP/1.1 503"));
}

test "the health and metrics pages are described, and not counted as routes that write their own answer" {
    // Both are `*Ctx` handlers returning nothing, which ADR 120 cannot
    // describe from a signature, and both are nilo's own, so it knows what
    // they answer and says so (ADR 120). Before this, `app.health` alone
    // made `listen()` print "1 of N routes hold the Ctx and return nothing",
    // and the reader went looking for a handler of theirs that was not there.
    var pool = ProbePool{ .up = true };
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.provide(&pool);
    try app.health("/healthz");
    try app.metrics(.{});

    for (app.operations.items) |op| try testing.expect(!op.answer.written);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const paths = parsed.value.object.get("paths").?.object;

    // A `200` with a body, where a written answer is a `default` with none.
    const health_responses = paths.get("/healthz").?.object.get("get").?.object.get("responses").?.object;
    try testing.expect(health_responses.get("default") == null);
    const health_ok = health_responses.get("200").?.object;
    try testing.expect(health_ok.get("content").?.object.get("application/json") != null);

    const metrics_responses = paths.get("/metrics").?.object.get("get").?.object.get("responses").?.object;
    try testing.expect(metrics_responses.get("default") == null);
    const metrics_ok = metrics_responses.get("200").?.object;
    try testing.expect(metrics_ok.get("content").?.object.get("text/plain; version=0.0.4; charset=utf-8") != null);
}

test "the health route says stopping from the moment the server is told to stop" {
    var pool = ProbePool{ .up = true };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&pool);
    try app.health("/healthz");

    var h = Harness.init();
    defer h.deinit();

    app.stop.requested.store(true, .release);
    const stopping = h.send(&app, "GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, stopping.response, "HTTP/1.1 503"));
    try testing.expect(std.mem.endsWith(u8, stopping.response, "{\"status\":\"stopping\"}"));
}

// ---- answering once per Idempotency-Key (ADR 155) ----

/// The shape `Idempotent` asks of a Space, over a map: what `nilo_cache`'s
/// bytes Space has, written here because `http/` names no cache.
const FakeReplays = struct {
    pub const Held = [max_bytes]u8;
    pub const max_bytes: usize = 4096;
    /// What a real Space holds a key to; a longer one is `TooLarge`.
    const max_key: usize = 512;

    map: std.StringHashMap([]const u8),
    gpa: std.mem.Allocator,
    /// What the in-flight marker was given as its own lifetime, in seconds:
    /// zero until a claim says one.
    claim_ttl_s: u32 = 0,

    fn init(gpa: std.mem.Allocator) FakeReplays {
        return .{ .map = .init(gpa), .gpa = gpa };
    }

    fn deinit(self: *FakeReplays) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn getInto(self: *FakeReplays, key: []const u8, out: []u8) ?[]const u8 {
        const v = self.map.get(key) orelse return null;
        if (v.len > out.len) return null;
        @memcpy(out[0..v.len], v);
        return out[0..v.len];
    }

    pub fn putIfAbsent(self: *FakeReplays, key: []const u8, value: []const u8) error{TooLarge}!bool {
        if (self.map.contains(key)) return false;
        try self.put(key, value);
        return true;
    }

    pub fn putIfAbsentFor(self: *FakeReplays, key: []const u8, value: []const u8, ttl_s: u32) error{TooLarge}!bool {
        const claimed = try self.putIfAbsent(key, value);
        if (claimed) self.claim_ttl_s = ttl_s;
        return claimed;
    }

    pub fn put(self: *FakeReplays, key: []const u8, value: []const u8) error{TooLarge}!void {
        if (value.len > max_bytes or key.len > max_key) return error.TooLarge;
        const k = self.gpa.dupe(u8, key) catch return error.TooLarge;
        const v = self.gpa.dupe(u8, value) catch return error.TooLarge;
        if (self.map.fetchRemove(k)) |old| {
            self.gpa.free(old.key);
            self.gpa.free(old.value);
        }
        self.map.put(k, v) catch return error.TooLarge;
    }

    pub fn del(self: *FakeReplays, key: []const u8) bool {
        const old = self.map.fetchRemove(key) orelse return false;
        self.gpa.free(old.key);
        self.gpa.free(old.value);
        return true;
    }
};

const OrderCounter = struct { placed: u32 = 0 };
const KeptOrder = struct { sku: []const u8, qty: u32 };
const PlacedOnce = struct { id: u32, sku: []const u8 };

fn placeKeptOrder(key: typed.Idempotent(FakeReplays, .{}), body: KeptOrder, counter: *OrderCounter) !typed.Response(PlacedOnce) {
    if (body.qty == 0) return fail.unprocessable("qty has to be at least 1", .{});
    counter.placed += 1;
    _ = key;
    return .{
        .status = 201,
        .value = .{ .id = counter.placed, .sku = body.sku },
        .headers = .of(&.{.{ .name = "Location", .value = "/orders/1" }}),
    };
}

fn whoseOrder(c: *ctx_mod.Ctx) ?Str {
    return c.header("X-Account");
}

test "the Space an Idempotent route keeps answers in is a service it needs, so listen() refuses a missing one by name" {
    // `checkServices` logs an error naming it, which the test runner counts
    // as a failure, so what is asserted is the requirement it reads: the
    // same one a `Cached` route's Space gets (ADR 005, ADR 155).
    const needs = comptime typed.requirements("/orders", placeKeptOrder);
    var named = false;
    for (needs) |r| {
        if (std.mem.eql(u8, r.type_name, @typeName(FakeReplays))) {
            try testing.expect(r.needs_mutable);
            try testing.expectEqualStrings("/orders", r.route);
            named = true;
        }
    }
    try testing.expect(named);
}

fn placeForAccount(key: typed.Idempotent(FakeReplays, .{ .by = whoseOrder }), counter: *OrderCounter) !u32 {
    _ = key;
    counter.placed += 1;
    return counter.placed;
}

fn post(h: *Harness, app: *App, key: []const u8, body: []const u8) []const u8 {
    var buf: [512]u8 = undefined;
    const raw = std.fmt.bufPrint(&buf, "POST /orders HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nIdempotency-Key: {s}\r\n\r\n{s}", .{ body.len, key, body }) catch unreachable;
    return h.send(app, raw).response;
}

test "the first request with a key runs the handler and every retry gets its answer back" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeKeptOrder);

    var h = Harness.init();
    defer h.deinit();

    const first = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":2}");
    try testing.expect(std.mem.startsWith(u8, first, "HTTP/1.1 201"));
    try testing.expect(std.mem.endsWith(u8, first, "{\"id\":1,\"sku\":\"A1\"}"));
    try testing.expect(std.mem.indexOf(u8, first, "Idempotent-Replayed") == null);
    try testing.expectEqual(@as(u32, 1), counter.placed);

    // Same key, same body: the kept answer, the handler untouched, and the
    // handler's own Location on it again.
    const again = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":2}");
    try testing.expect(std.mem.startsWith(u8, again, "HTTP/1.1 201"));
    try testing.expect(std.mem.endsWith(u8, again, "{\"id\":1,\"sku\":\"A1\"}"));
    try testing.expect(std.mem.indexOf(u8, again, "Idempotent-Replayed: true") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Location: /orders/1") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Content-Type: application/json") != null);
    try testing.expectEqual(@as(u32, 1), counter.placed);

    // A new key is a new order.
    const second = post(&h, &app, "k-2", "{\"sku\":\"B2\",\"qty\":1}");
    try testing.expect(std.mem.endsWith(u8, second, "{\"id\":2,\"sku\":\"B2\"}"));
    try testing.expectEqual(@as(u32, 2), counter.placed);
}

test "a key without a request, reused on another request, or still in flight is refused by name" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeKeptOrder);

    var h = Harness.init();
    defer h.deinit();

    const missing = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nContent-Length: 21\r\n\r\n{\"sku\":\"A1\",\"qty\":2}").response;
    try testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, missing, "Idempotency-Key") != null);
    try testing.expectEqual(@as(u32, 0), counter.placed);

    _ = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":2}");
    // Same key, different body: a client bug, and not the old answer.
    const reused = post(&h, &app, "k-1", "{\"sku\":\"Z9\",\"qty\":2}");
    try testing.expect(std.mem.startsWith(u8, reused, "HTTP/1.1 422"));
    try testing.expect(std.mem.indexOf(u8, reused, "different request") != null);
    try testing.expectEqual(@as(u32, 1), counter.placed);

    // A marker somebody else's request left is a 409, not a second run.
    const marker = @import("idempotent.zig").marker(@import("idempotent.zig").fingerprintOf("POST", "/orders", "", "{\"sku\":\"C3\",\"qty\":1}"));
    try replays.put("k-3", &marker);
    const racing = post(&h, &app, "k-3", "{\"sku\":\"C3\",\"qty\":1}");
    try testing.expect(std.mem.startsWith(u8, racing, "HTTP/1.1 409"));
    try testing.expect(std.mem.indexOf(u8, racing, "still being answered") != null);
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

// ---- a type that writes its own answer (ADR 157) ----

const XmlInvoice = struct {
    number: u32,
    total: i64,

    pub const nilo_content_type = "application/xml";
    pub const nilo_openapi = .{ .type = "string" };

    pub fn nilo_write(self: XmlInvoice, w: *std.Io.Writer) !void {
        try w.print("<invoice><number>{d}</number><total>{d}</total></invoice>", .{ self.number, self.total });
    }
};

/// The same, saying nothing about its shape: the document has to be
/// visibly silent rather than confidently wrong.
const CsvRow = struct {
    a: u32,
    b: u32,

    pub const nilo_content_type = "text/csv";

    pub fn nilo_write(self: CsvRow, w: *std.Io.Writer) !void {
        try w.print("a,b\n{d},{d}\n", .{ self.a, self.b });
    }
};

fn showXmlInvoice(id: u32) ?XmlInvoice {
    if (id == 0) return null;
    return .{ .number = id, .total = 1500 };
}

fn makeXmlInvoice(body: struct { total: i64 }) typed.Status(201, XmlInvoice) {
    return .{ .value = .{ .number = 9, .total = body.total } };
}

fn showCsv() CsvRow {
    return .{ .a = 1, .b = 2 };
}

fn keepXmlInvoice(key: typed.Idempotent(FakeReplays, .{}), counter: *OrderCounter) !XmlInvoice {
    _ = key;
    counter.placed += 1;
    return .{ .number = counter.placed, .total = 10 };
}

test "a type carrying nilo_content_type and nilo_write goes out under its own label" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/invoices/:id", showXmlInvoice);
    try app.post("/invoices", makeXmlInvoice);
    try app.get("/rows.csv", showCsv);

    var h = Harness.init();
    defer h.deinit();

    const one = h.send(&app, "GET /invoices/7 HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, one, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, one, "Content-Type: application/xml") != null);
    try testing.expect(std.mem.endsWith(u8, one, "<invoice><number>7</number><total>1500</total></invoice>"));

    // `?T` is still a 404 — the wrapper is taken apart before the type is
    // asked to write, the same as for JSON.
    const none = h.send(&app, "GET /invoices/0 HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, none, "HTTP/1.1 404"));

    // And so is a `Status(201, T)`.
    const made = h.send(&app, "POST /invoices HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"total\":42}").response;
    try testing.expect(std.mem.startsWith(u8, made, "HTTP/1.1 201"));
    try testing.expect(std.mem.indexOf(u8, made, "Content-Type: application/xml") != null);
    try testing.expect(std.mem.endsWith(u8, made, "<total>42</total></invoice>"));

    const csv = h.send(&app, "GET /rows.csv HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.indexOf(u8, csv, "Content-Type: text/csv") != null);
    try testing.expect(std.mem.endsWith(u8, csv, "a,b\n1,2\n"));
}

test "the document names the type's own content type, and its schema only when the type said one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/invoices/:id", showXmlInvoice);
    try app.get("/rows.csv", showCsv);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);
    const doc = out.written();

    try testing.expect(std.mem.indexOf(u8, doc, "\"application/xml\":{\"schema\":{\"type\":\"string\"}}") != null);
    // The CSV said nothing, so the document says nothing — `{}` and the
    // note — rather than reflecting two integer fields nobody sends.
    try testing.expect(std.mem.indexOf(u8, doc, "\"text/csv\":{\"schema\":{\"description\":\"This type reads or writes its own bytes") != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"text/csv\":{\"schema\":{\"type\":\"object\"") == null);
}

test "an idempotent route keeps an answer a type wrote itself, label and all" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", keepXmlInvoice);

    var h = Harness.init();
    defer h.deinit();

    const first = post(&h, &app, "x-1", "{}");
    try testing.expect(std.mem.startsWith(u8, first, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, first, "Content-Type: application/xml") != null);
    try testing.expect(std.mem.endsWith(u8, first, "<invoice><number>1</number><total>10</total></invoice>"));

    const again = post(&h, &app, "x-1", "{}");
    try testing.expect(std.mem.indexOf(u8, again, "Idempotent-Replayed: true") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Content-Type: application/xml") != null);
    try testing.expect(std.mem.endsWith(u8, again, "<invoice><number>1</number><total>10</total></invoice>"));
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

// ---- a body read as what its type says (ADR 256) ----

const SumRequest = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const SumReply = struct {
    pub const wire = .{ .total = 1 };
    total: i32 = 0,
};

fn sumOf(in: SumRequest) SumReply {
    return .{ .total = in.a + in.b };
}

fn keepSum(key: typed.Idempotent(FakeReplays, .{}), counter: *OrderCounter, in: SumRequest) !SumReply {
    _ = key;
    counter.placed += 1;
    return .{ .total = in.a + in.b };
}

/// Six bytes: a sensor and a reading, big-endian, under a label of its own.
const Reading = struct {
    sensor: u16,
    tenths: u32,

    pub const nilo_content_type = "application/x-reading";

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Reading {
        _ = arena;
        if (body.len != 6) return error.NotSixBytes;
        if (body[0] == 0xff) return fail.unprocessable("sensor {d} is not one this site has", .{body[1]});
        return .{ .sensor = std.mem.readInt(u16, body[0..2], .big), .tenths = std.mem.readInt(u32, body[2..6], .big) };
    }
};

fn recordReading(r: Reading) typed.Status(201, struct { sensor: u16, tenths: u32 }) {
    return .{ .value = .{ .sensor = r.sensor, .tenths = r.tenths } };
}

fn sumRequest(h: *Harness, app: *App, content_type: ?[]const u8, body: []const u8) []const u8 {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("POST /sum HTTP/1.1\r\nHost: t\r\n") catch unreachable;
    if (content_type) |ct| w.print("Content-Type: {s}\r\n", .{ct}) catch unreachable;
    w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    return h.send(app, w.buffered()).response;
}

test "a message is read and answered in the spelling the request came in" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sum", sumOf);
    var h = Harness.init();
    defer h.deinit();

    const json = sumRequest(&h, &app, "application/json", "{\"a\":1,\"b\":2}");
    try testing.expect(std.mem.startsWith(u8, json, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, json, "Content-Type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, json, "{\"total\":3}"));

    // Field 1 is 1 and field 2 is 2; the answer is field 1, 3.
    const proto = sumRequest(&h, &app, "application/proto", "\x08\x01\x10\x02");
    try testing.expect(std.mem.startsWith(u8, proto, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, proto, "Content-Type: application/proto") != null);
    try testing.expect(std.mem.endsWith(u8, proto, "\r\n\r\n\x08\x03"));

    // The name older clients send is the same spelling, answered under
    // Connect's name for it.
    const older = sumRequest(&h, &app, "Application/X-Protobuf; charset=binary", "\x08\x05");
    try testing.expect(std.mem.indexOf(u8, older, "Content-Type: application/proto") != null);
    try testing.expect(std.mem.endsWith(u8, older, "\r\n\r\n\x08\x05"));

    // No content type at all is JSON, as every other body is.
    const bare = sumRequest(&h, &app, null, "{\"a\":4}");
    try testing.expect(std.mem.endsWith(u8, bare, "{\"total\":4}"));
}

test "a message sent under any label but protobuf's is read as JSON, and bytes that are not one a 400 naming the type" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sum", sumOf);
    var h = Harness.init();
    defer h.deinit();

    // What `curl -d` and a `fetch` of a string send: read as JSON, as a
    // plain struct would be, and answered in it.
    for ([_][]const u8{ "application/x-www-form-urlencoded", "text/plain;charset=UTF-8" }) |label| {
        const sent = sumRequest(&h, &app, label, "{\"a\":1,\"b\":2}");
        try testing.expect(std.mem.startsWith(u8, sent, "HTTP/1.1 200"));
        try testing.expect(std.mem.indexOf(u8, sent, "Content-Type: application/json") != null);
        try testing.expect(std.mem.endsWith(u8, sent, "{\"total\":3}"));
    }

    // A key with no value after it.
    const cut = sumRequest(&h, &app, "application/proto", "\x08");
    try testing.expect(std.mem.startsWith(u8, cut, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, cut, "is not a protobuf behaviour.SumRequest: it ends in the middle of a field") != null);
}

fn findSum(in: SumRequest) !SumReply {
    if (in.a < 0) return fail.notFound("no sum starts at {d}", .{in.a});
    if (in.a == 1000) return error.AlreadyExists;
    return .{ .total = in.a + in.b };
}

fn connectCall(h: *Harness, app: *App, path: []const u8, connect: bool, body: []const u8) []const u8 {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("POST {s} HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\n", .{path}) catch unreachable;
    if (connect) w.writeAll("Connect-Protocol-Version: 1\r\n") catch unreachable;
    w.print("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    return h.send(app, w.buffered()).response;
}

test "a Connect call that fails is told its code and nilo's sentence, and every other request keeps nilo's shape" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/math.Sums/Find", findSum);
    var h = Harness.init();
    defer h.deinit();

    const missing = connectCall(&h, &app, "/math.Sums/Find", true, "{\"a\":-2,\"b\":0}");
    try testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404"));
    try testing.expect(std.mem.indexOf(u8, missing, "Content-Type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, missing, "{\"code\":\"not_found\",\"message\":\"no sum starts at -2\"}"));

    // The error says more than its 409 does, as it does to a gRPC client.
    const taken = connectCall(&h, &app, "/math.Sums/Find", true, "{\"a\":1000,\"b\":0}");
    try testing.expect(std.mem.startsWith(u8, taken, "HTTP/1.1 409"));
    try testing.expect(std.mem.endsWith(u8, taken, "{\"code\":\"already_exists\",\"message\":\"Conflict\"}"));

    // A body that is not the message, and a path no route answers.
    const bad = connectCall(&h, &app, "/math.Sums/Find", true, "{\"a\":\"x\"}");
    try testing.expect(std.mem.startsWith(u8, bad, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, bad, "{\"code\":\"invalid_argument\",\"message\":") != null);
    const nowhere = connectCall(&h, &app, "/math.Sums/Lose", true, "{}");
    try testing.expect(std.mem.startsWith(u8, nowhere, "HTTP/1.1 404"));
    try testing.expect(std.mem.indexOf(u8, nowhere, "{\"code\":\"not_found\",\"message\":") != null);

    // The same failure asked without the header.
    const plain = connectCall(&h, &app, "/math.Sums/Find", false, "{\"a\":-2,\"b\":0}");
    try testing.expect(std.mem.endsWith(u8, plain, "{\"error\":\"no sum starts at -2\",\"status\":404}"));
}

test "a Connect call is answered in Connect's shape over an application's own, and only by a program with a message route" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(ApiError);
    try app.get("/orders", failsWithASentence);
    var h = Harness.init();
    defer h.deinit();

    // No route speaks a message yet: the header means nothing here.
    const before = h.send(&app, "GET /orders HTTP/1.1\r\nHost: t\r\nConnect-Protocol-Version: 1\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, before, "{\"code\":404,\"detail\":\"no order \\\"7\\\"\"}"));

    try app.post("/math.Sums/Find", findSum);
    const connect = h.send(&app, "GET /orders HTTP/1.1\r\nHost: t\r\nConnect-Protocol-Version: 1\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, connect, "{\"code\":\"not_found\",\"message\":\"no order \\\"7\\\"\"}"));
    const own = h.send(&app, "GET /orders HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, own, "{\"code\":404,\"detail\":\"no order \\\"7\\\"\"}"));
}

const Sums = struct {
    pub const nilo_service = "math.v1.Sums";

    pub fn add(in: SumRequest) SumReply {
        return .{ .total = in.a + in.b };
    }

    pub fn find(in: SumRequest) !SumReply {
        return findSum(in);
    }

    /// Not `pub`, so not a method.
    fn helper() void {}
};

test "a struct of typed functions is served as a service, each pub fn a method with its first letter upper-cased" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.rpc(Sums);
    var h = Harness.init();
    defer h.deinit();
    Sums.helper();

    const json = h.send(&app, "POST /math.v1.Sums/Add HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":1,\"b\":2}").response;
    try testing.expect(std.mem.startsWith(u8, json, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, json, "{\"total\":3}"));

    const proto_answer = h.send(&app, "POST /math.v1.Sums/Add HTTP/1.1\r\nHost: t\r\nContent-Type: application/proto\r\nContent-Length: 4\r\n\r\n\x08\x01\x10\x02").response;
    try testing.expect(std.mem.indexOf(u8, proto_answer, "Content-Type: application/proto") != null);
    try testing.expect(std.mem.endsWith(u8, proto_answer, "\x08\x03"));

    // The function's own name is not a path, and a method is a POST.
    const lower = h.send(&app, "POST /math.v1.Sums/add HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, lower, "HTTP/1.1 404"));
    const get = h.send(&app, "GET /math.v1.Sums/Add HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, get, "HTTP/1.1 405"));

    const missing = connectCall(&h, &app, "/math.v1.Sums/Find", true, "{\"a\":-1,\"b\":0}");
    try testing.expect(std.mem.endsWith(u8, missing, "{\"code\":\"not_found\",\"message\":\"no sum starts at -1\"}"));
}

test "a service registered on a group carries the group's prefix and middleware" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.group("/rpc").rpc(Sums);
    var h = Harness.init();
    defer h.deinit();

    const sent = h.send(&app, "POST /rpc/math.v1.Sums/Add HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":2,\"b\":2}").response;
    try testing.expect(std.mem.endsWith(u8, sent, "{\"total\":4}"));
}

test "a type with nilo_decode is read only when it arrives under its own label" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/readings", recordReading);
    var h = Harness.init();
    defer h.deinit();

    const ok = h.send(&app, "POST /readings HTTP/1.1\r\nHost: t\r\nContent-Type: application/x-reading\r\nContent-Length: 6\r\n\r\n\x00\x07\x00\x00\x01\x02").response;
    try testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 201"));
    try testing.expect(std.mem.endsWith(u8, ok, "{\"sensor\":7,\"tenths\":258}"));

    const wrong = h.send(&app, "POST /readings HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}").response;
    try testing.expect(std.mem.startsWith(u8, wrong, "HTTP/1.1 415"));
    try testing.expect(std.mem.indexOf(u8, wrong, "reads application/x-reading") != null);

    const unlabelled = h.send(&app, "POST /readings HTTP/1.1\r\nHost: t\r\nContent-Length: 6\r\n\r\n\x00\x07\x00\x00\x01\x02").response;
    try testing.expect(std.mem.startsWith(u8, unlabelled, "HTTP/1.1 415"));
    try testing.expect(std.mem.indexOf(u8, unlabelled, "said nothing about what its body is") != null);

    const short = h.send(&app, "POST /readings HTTP/1.1\r\nHost: t\r\nContent-Type: application/x-reading\r\nContent-Length: 2\r\n\r\n\x00\x07").response;
    try testing.expect(std.mem.startsWith(u8, short, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, short, "NotSixBytes") != null);

    // A decoder that fails with a fail function says its own sentence.
    const unknown = h.send(&app, "POST /readings HTTP/1.1\r\nHost: t\r\nContent-Type: application/x-reading\r\nContent-Length: 6\r\n\r\n\xff\x09\x00\x00\x01\x02").response;
    try testing.expect(std.mem.startsWith(u8, unknown, "HTTP/1.1 422"));
    try testing.expect(std.mem.indexOf(u8, unknown, "sensor 9 is not one this site has") != null);
}

test "the document files a message under both its spellings, and a type's own body under its label" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sum", sumOf);
    try app.post("/readings", recordReading);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);
    const doc = out.written();

    const both = "\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/SumRequest\"}},\"application/proto\":{\"schema\":{\"$ref\":\"#/components/schemas/SumRequest\"}}";
    try testing.expect(std.mem.indexOf(u8, doc, both) != null);
    const answered = "\"application/json\":{\"schema\":{\"$ref\":\"#/components/schemas/SumReply\"}},\"application/proto\":{\"schema\":{\"$ref\":\"#/components/schemas/SumReply\"}}";
    try testing.expect(std.mem.indexOf(u8, doc, answered) != null);
    try testing.expect(std.mem.indexOf(u8, doc, "\"application/x-reading\":{\"schema\":{\"description\":\"This type reads or writes its own bytes") != null);
}

test "an idempotent route keeps a protobuf answer as protobuf" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/sum", keepSum);
    var h = Harness.init();
    defer h.deinit();

    const raw = "POST /sum HTTP/1.1\r\nHost: t\r\nContent-Type: application/proto\r\nIdempotency-Key: s-1\r\nContent-Length: 4\r\n\r\n\x08\x01\x10\x02";
    const first = h.send(&app, raw).response;
    try testing.expect(std.mem.indexOf(u8, first, "Content-Type: application/proto") != null);
    try testing.expect(std.mem.endsWith(u8, first, "\r\n\r\n\x08\x03"));

    const again = h.send(&app, raw).response;
    try testing.expect(std.mem.indexOf(u8, again, "Idempotent-Replayed: true") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Content-Type: application/proto") != null);
    try testing.expect(std.mem.endsWith(u8, again, "\r\n\r\n\x08\x03"));
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

test "what the handler failed with is not kept, so the retry runs it again" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeKeptOrder);

    var h = Harness.init();
    defer h.deinit();

    const refused = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":0}");
    try testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 422"));
    try testing.expect(std.mem.indexOf(u8, refused, "Idempotent-Replayed") == null);
    // The marker is gone, so the same key with a corrected body is a fresh
    // request rather than a 422 about reuse.
    const fixed = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":1}");
    try testing.expect(std.mem.startsWith(u8, fixed, "HTTP/1.1 201"));
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

fn signUpWithSession(key: typed.Idempotent(FakeReplays, .{}), counter: *OrderCounter, c: *ctx_mod.Ctx) !typed.Response(PlacedOnce) {
    _ = key;
    counter.placed += 1;
    // Set through the Ctx rather than on the answer: a session is, which is
    // the header a retry most needs to get back.
    try c.setCookie(.{ .name = "session", .value = "s-1" });
    try c.setHeader("X-Trace", "t-1");
    return .{
        .status = 201,
        .value = .{ .id = counter.placed, .sku = "x" },
        .headers = .of(&.{.{ .name = "Location", .value = "/users/1" }}),
    };
}

test "a replay carries the headers the handler set through the Ctx, not only those on its answer" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", signUpWithSession);

    var h = Harness.init();
    defer h.deinit();

    const first = post(&h, &app, "k-1", "{}");
    try testing.expect(std.mem.indexOf(u8, first, "Set-Cookie: session=s-1") != null);
    try testing.expect(std.mem.indexOf(u8, first, "X-Trace: t-1") != null);

    const again = post(&h, &app, "k-1", "{}");
    try testing.expect(std.mem.indexOf(u8, again, "Idempotent-Replayed: true") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Set-Cookie: session=s-1") != null);
    try testing.expect(std.mem.indexOf(u8, again, "X-Trace: t-1") != null);
    try testing.expect(std.mem.indexOf(u8, again, "Location: /users/1") != null);
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

test "a request that never reached the handler leaves no marker, so the same key with a good body runs" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeKeptOrder);

    var h = Harness.init();
    defer h.deinit();

    // A body that does not parse is refused while the arguments are read,
    // after the key was claimed: ADR 155 says a failure runs again.
    const broken = post(&h, &app, "k-1", "{\"sku\":");
    try testing.expect(std.mem.startsWith(u8, broken, "HTTP/1.1 400"));
    try testing.expectEqual(@as(u32, 0), replays.map.count());

    const fixed = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":1}");
    try testing.expect(std.mem.startsWith(u8, fixed, "HTTP/1.1 201"));
    try testing.expectEqual(@as(u32, 1), counter.placed);
}

test "the in-flight marker is claimed for a lifetime of its own, not the Space's" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeKeptOrder);

    var h = Harness.init();
    defer h.deinit();

    _ = post(&h, &app, "k-1", "{\"sku\":\"A1\",\"qty\":1}");
    // A Space that outlives the process would otherwise answer 409 for its
    // whole TTL after a crash mid-handler.
    try testing.expect(replays.claim_ttl_s > 0);
    try testing.expect(replays.claim_ttl_s <= 300);
}

fn placeWithBadHeader(key: typed.Idempotent(FakeReplays, .{}), counter: *OrderCounter) typed.Response(PlacedOnce) {
    _ = key;
    counter.placed += 1;
    return .{
        .status = 201,
        .value = .{ .id = counter.placed, .sku = "x" },
        .headers = .of(&.{.{ .name = "Location", .value = "/orders/1\r\nX-Injected: yes" }}),
    };
}

test "an answer whose header is refused is not kept, so a retry runs the handler again" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeWithBadHeader);

    var h = Harness.init();
    defer h.deinit();

    for (0..2) |_| {
        const answer = post(&h, &app, "k-1", "{}");
        try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 500"));
        try testing.expect(std.mem.indexOf(u8, answer, "Idempotent-Replayed") == null);
    }
    try testing.expectEqual(@as(u32, 2), counter.placed);
    try testing.expectEqual(@as(u32, 0), replays.map.count());
}

test "a key is the caller's when `by` says whose, and a request with no caller is a 403" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeForAccount);

    var h = Harness.init();
    defer h.deinit();

    const alice = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nX-Account: alice\r\nIdempotency-Key: k\r\nContent-Length: 0\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, alice, "1"));
    const bob = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nX-Account: bob\r\nIdempotency-Key: k\r\nContent-Length: 0\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, bob, "2"));
    const alice_again = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nX-Account: alice\r\nIdempotency-Key: k\r\nContent-Length: 0\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, alice_again, "1"));
    try testing.expect(std.mem.indexOf(u8, alice_again, "Idempotent-Replayed: true") != null);
    try testing.expectEqual(@as(u32, 2), counter.placed);

    const nobody = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nIdempotency-Key: k\r\nContent-Length: 0\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, nobody, "HTTP/1.1 403"));
}

test "a key too long for the Space is refused before the handler runs, not a crash" {
    var replays = FakeReplays.init(testing.allocator);
    defer replays.deinit();
    var counter = OrderCounter{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&replays);
    try app.provide(&counter);
    try app.post("/orders", placeForAccount);

    var h = Harness.init();
    defer h.deinit();

    // `by` says whose; a caller string longer than the Space holds a key to
    // is not something it can claim, and a write that cannot be claimed is
    // a write a retry would make twice, so it is not made at all.
    const who = &@as([600]u8, @splat('a'));
    const raw = "POST /orders HTTP/1.1\r\nHost: t\r\nX-Account: " ++ who ++ "\r\nIdempotency-Key: k\r\nContent-Length: 0\r\n\r\n";
    for (0..2) |_| {
        const answer = h.send(&app, raw).response;
        try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 400"));
        try testing.expect(try Harness.saysFailure(answer, "the Idempotency-Key header is too long for this endpoint to keep; send a shorter one"));
    }
    try testing.expectEqual(@as(u32, 0), counter.placed);
    try testing.expectEqual(@as(u32, 0), replays.map.count());
}

test "an idempotent route promises the header, a 409 and a 422 in the document" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.post("/orders", placeKeptOrder);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const op = parsed.value.object.get("paths").?.object.get("/orders").?.object.get("post").?.object;
    const key = op.get("parameters").?.array.items[0].object;
    try testing.expectEqualStrings("Idempotency-Key", key.get("name").?.string);
    try testing.expectEqualStrings("header", key.get("in").?.string);
    try testing.expect(key.get("required").?.bool);
    const responses = op.get("responses").?.object;
    try testing.expect(responses.get("409") != null);
    try testing.expect(responses.get("422") != null);
}

// ---- stage 3: typed handlers, services, fail functions ----

const Db = struct {
    rows: []const Row,

    const Row = struct { id: u32, name: []const u8 };

    fn find(self: *const Db, id: u32) ?Row {
        for (self.rows) |row| {
            if (row.id == id) return row;
        }
        return null;
    }
};

const UserOut = struct { id: u32, name: []const u8 };

/// The shape the README has been promising: an ordinary function, no
/// `Ctx`, no fake HTTP, with the service asked for by its type.
fn getUser(db: *Db, id: u32) !UserOut {
    const row = db.find(id) orelse return fail.notFound("no user {d}", .{id});
    return .{ .id = row.id, .name = row.name };
}

test "typed handler: service and path param matched by type" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

// The main selling point (ADR 002): a handler is tested as an ordinary
// function, without starting a server and without fake HTTP.
test "a typed handler can be tested as an ordinary function" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    try testing.expectEqual(@as(u32, 7), (try getUser(&db, 7)).id);
    try testing.expectError(error.Failed, getUser(&db, 99));
}

test "a fail function becomes its status and message, connection stays alive" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/99 HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "no user 99") != null);
    try testing.expect(result.keep_alive);
}

test "a path param that is not a number becomes a 400 with a clear message" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /users/abc HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, ":id has to be a whole number") != null);
    try testing.expect(result.keep_alive);
}

test "the Failure does not leak into the next request on the same connection" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const failed_first = h.send(&app, "GET /users/99 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed_first.response, "HTTP/1.1 404"));

    const then_succeeded = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, then_succeeded.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, then_succeeded.response, "no user") == null);
}

const NewUser = struct { name: Str };

fn createUser(incoming: NewUser) !typed.Response(UserOut) {
    if (incoming.name.len() == 0) return fail.unprocessable("name must not be empty", .{});
    return .{ .status = 201, .value = .{ .id = 1, .name = incoming.name.view() } };
}

test "a JSON body comes in as a struct, Response(T) sets the status" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nHost: t\r\nContent-Length: 16\r\n\r\n{\"name\":\"wati\"}\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":1,\"name\":\"wati\"}") != null);
}

test "a JSON body that breaks a rule becomes a 422 via a fail function" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nHost: t\r\nContent-Length: 12\r\n\r\n{\"name\":\"\"}\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 422 Unprocessable Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "name must not be empty") != null);
}

test "broken JSON is a 400 that says where it stopped making sense" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\n{name");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "not valid JSON") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "line 1, column 2") != null);
    try testing.expect(result.keep_alive);
}

// The point of what follows: a query param that does not fit has always
// been answered with the name of the param and what was wrong with it. A
// body field used to get `Bad Request` and nothing else. These are the same
// standard, applied to the other half of the request.

const Signup = struct {
    name: Str,
    age: u32,
    plan: enum { free, paid } = .free,
    nickname: ?Str = null,
};

fn signup(incoming: Signup) !struct { name: []const u8 } {
    return .{ .name = incoming.name.view() };
}

fn signupResponse(h: *Harness, app: *App, body: []const u8) []const u8 {
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buf,
        "POST /signup HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n",
        .{body.len},
    ) catch unreachable;
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;
    return h.send(app, request).response;
}

test "a body field that does not fit is a 400 naming the field, like a query param" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/signup", signup);

    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // Something the endpoint needs that is not there. A field with a
        // default is exempt: that is what "absent" is allowed to mean.
        .{ .body = "{\"name\":\"wati\"}", .says = "missing \"age\"" },
        // A typo, which is what an unknown field almost always is — so the
        // names it could have been go out with the complaint.
        .{ .body = "{\"nme\":\"wati\",\"age\":7}", .says = "field \"nme\" this endpoint does not know" },
        // Present, but the wrong shape for where it landed.
        .{ .body = "{\"name\":123,\"age\":7}", .says = "\"name\" has to be text, not a number" },
        .{ .body = "{\"name\":\"wati\",\"age\":\"soon\"}", .says = "\"age\" has to be a whole number, not text" },
        // An enum says which names it knows, the way a query param does —
        // and quotes back the word it was given, because "has to be one of
        // free, paid, not text" is a sentence arguing with itself.
        .{
            .body = "{\"name\":\"w\",\"age\":7,\"plan\":\"gold\"}",
            .says = "\"plan\" is not one of the known choices (free, paid): \"gold\"",
        },
        // Not a word at all, which is the other way to get an enum wrong,
        // and there the kind is the thing worth saying.
        .{
            .body = "{\"name\":\"w\",\"age\":7,\"plan\":9}",
            .says = "\"plan\" has to be one of free, paid, not a number",
        },
        // An optional field takes null, but not anything at all.
        .{ .body = "{\"name\":\"w\",\"age\":7,\"nickname\":9}", .says = "\"nickname\" has to be text or null" },
        // Valid JSON of the wrong kind entirely.
        .{ .body = "[1,2,3]", .says = "has to be a JSON object" },
        // No body at all — the commonest way a first curl goes wrong.
        .{ .body = "", .says = "the request body is empty" },
    };

    for (cases) |case| {
        const response = signupResponse(&h, &app, case.body);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
}

test "a body that fits still parses, so the diagnosis costs the happy path nothing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/signup", signup);

    var h = Harness.init();
    defer h.deinit();
    const response = signupResponse(&h, &app, "{\"name\":\"wati\",\"age\":7,\"plan\":\"paid\"}");

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, response, "{\"name\":\"wati\"}") != null);
}

const EditTodo = struct {
    title: patch_mod.Patch(Str) = .absent,
    due: patch_mod.Patch(Str) = .absent,
};

fn editTodo(incoming: EditTodo) !struct { title: []const u8, due: []const u8 } {
    return .{
        .title = switch (incoming.title) {
            .absent => "absent",
            .cleared => "cleared",
            // Read through `view()`, which is what proves the Str inside a
            // Patch got its lifetime marker like any other.
            .value => |v| v.view(),
        },
        .due = switch (incoming.due) {
            .absent => "absent",
            .cleared => "cleared",
            .value => |v| v.view(),
        },
    };
}

test "a PATCH body tells a field left out from one sent as null" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.patch("/todos", editTodo);

    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // The distinction `?T` cannot make, and the reason Patch exists
        // (ADR 025).
        .{ .body = "{}", .says = "{\"title\":\"absent\",\"due\":\"absent\"}" },
        .{ .body = "{\"title\":null}", .says = "{\"title\":\"cleared\",\"due\":\"absent\"}" },
        .{ .body = "{\"title\":\"buy milk\"}", .says = "{\"title\":\"buy milk\",\"due\":\"absent\"}" },
        .{
            .body = "{\"title\":\"x\",\"due\":null}",
            .says = "{\"title\":\"x\",\"due\":\"cleared\"}",
        },
    };

    for (cases) |case| {
        var buf: [256]u8 = undefined;
        const request = std.fmt.bufPrint(
            &buf,
            "PATCH /todos HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ case.body.len, case.body },
        ) catch unreachable;
        const response = h.send(&app, request).response;
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
        testing.expect(std.mem.indexOf(u8, response, case.says) != null) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }

    // And a value of the wrong shape still says so, naming the field: a
    // Patch takes its value or null, and nothing else.
    const wrong = h.send(
        &app,
        "PATCH /todos HTTP/1.1\r\nHost: t\r\nContent-Length: 14\r\n\r\n{\"title\":123}\n",
    );
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(wrong.response, "\"title\" has to be text or null"));
}

const Address = struct { street: Str, city: Str };
const Line = struct { sku: Str, qty: u32 };
const Order = struct {
    customer: Str,
    address: Address,
    lines: []const Line,
    note: ?Str = null,
};

fn placeOrder(incoming: Order) !struct { customer: []const u8 } {
    return .{ .customer = incoming.customer.view() };
}

test "a field below the top level is named by where it is, not left to a bare 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeOrder);

    var h = Harness.init();
    defer h.deinit();

    const good_address = "\"address\":{\"street\":\"jl mawar\",\"city\":\"bandung\"}";
    const good_lines = "\"lines\":[{\"sku\":\"a\",\"qty\":1}]";

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // Inside a nested object: missing, unknown, and the wrong shape.
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":\"jl mawar\"}," ++ good_lines ++ "}",
            .says = "missing \"address.city\"",
        },
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":\"a\",\"city\":\"b\",\"zip\":\"c\"}," ++ good_lines ++ "}",
            .says = "field \"address.zip\" this endpoint does not know",
        },
        .{
            .body = "{\"customer\":\"wati\",\"address\":{\"street\":1,\"city\":\"b\"}," ++ good_lines ++ "}",
            .says = "\"address.street\" has to be text, not a number",
        },
        // Inside a list, which is named by the position that went wrong
        // rather than by the list.
        .{
            .body = "{\"customer\":\"wati\"," ++ good_address ++ ",\"lines\":[{\"sku\":\"a\",\"qty\":1},{\"sku\":\"b\",\"qty\":\"two\"}]}",
            .says = "\"lines[1].qty\" has to be a whole number, not text",
        },
        .{
            .body = "{\"customer\":\"wati\"," ++ good_address ++ ",\"lines\":[{\"sku\":\"a\"}]}",
            .says = "missing \"lines[0].qty\"",
        },
        // The top level still reads exactly as it did before any of this
        // went deeper: no prefix, because there is nothing to be inside of.
        .{
            .body = "{" ++ good_address ++ "," ++ good_lines ++ "}",
            .says = "the request body is missing \"customer\"",
        },
    };

    for (cases) |case| {
        var head_buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buf,
            "POST /orders HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n",
            .{case.body.len},
        ) catch unreachable;
        var request_buf: [1024]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, case.body }) catch unreachable;
        const response = h.send(&app, request).response;

        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
}

const Metrics = struct { metric_name: Str, agg: ?Str = null };
const Rule = struct {
    name: Str,
    condition: union(enum) {
        pub const nilo_json = .{ .tag = "signal" };
        pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

        metrics: Metrics,
        logs: struct { query: Str },
        off,
    },
};

fn takeRule(incoming: Rule) !struct { name: []const u8 } {
    return .{ .name = incoming.name.view() };
}

test "a 400 inside a tagged union names the variant or the key, as a struct's does" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/rules", takeRule);

    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // An unknown variant: what arrived, and what would have been taken.
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":\"traces\"}}",
            .says = "\"condition.signal\" is not one of the known variants (metrics, logs, off): \"traces\"",
        },
        // An unknown key: which one, which variant it was in, what that takes.
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":\"metrics\",\"metric_nme\":\"x\"}}",
            .says = "a field \"condition.metric_nme\" the \"metrics\" variant does not know. It takes: signal, metric_name, agg (optional)",
        },
        // A variant with no fields takes the discriminator and nothing else.
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":\"off\",\"extra\":1}}",
            .says = "a field \"condition.extra\" the \"off\" variant does not know. It takes: signal",
        },
        // The discriminator itself: absent, and not text.
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"query\":\"x\"}}",
            .says = "missing \"condition.signal\", which names the variant: one of metrics, logs, off",
        },
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":7}}",
            .says = "\"condition.signal\" has to be text naming the variant, one of metrics, logs, off, not a number",
        },
        // What is wrong inside the variant is named by where it is.
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":\"logs\"}}",
            .says = "missing \"condition.query\"",
        },
        .{
            .body = "{\"name\":\"r\",\"condition\":{\"signal\":\"logs\",\"query\":5}}",
            .says = "\"condition.query\" has to be text, not a number",
        },
        // Not an object at all.
        .{
            .body = "{\"name\":\"r\",\"condition\":\"metrics\"}",
            .says = "\"condition\" has to be an object whose \"signal\" is one of metrics, logs, off, not text",
        },
    };

    for (cases) |case| {
        var request_buf: [512]u8 = undefined;
        const request = std.fmt.bufPrint(
            &request_buf,
            "POST /rules HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ case.body.len, case.body },
        ) catch unreachable;
        const response = h.send(&app, request).response;

        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }

    // And a body that is right still reads.
    const ok = "{\"name\":\"r\",\"condition\":{\"signal\":\"metrics\",\"metric_name\":\"cpu\"}}";
    var buf: [256]u8 = undefined;
    const good = std.fmt.bufPrint(&buf, "POST /rules HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ ok.len, ok }) catch unreachable;
    try testing.expect(std.mem.startsWith(u8, h.send(&app, good).response, "HTTP/1.1 200"));
}

const NatoForm = struct {
    alpha_first: u8,
    bravo_second: u8,
    charlie_third: u8,
    delta_fourth: u8,
    echo_fifth: u8,
    foxtrot_sixth: u8,
    golf_seventh: u8,
    hotel_eighth: u8,
    india_ninth: u8,
    juliet_tenth: u8,
    kilo_eleventh: u8,
    lima_twelfth: u8 = 0,
};

fn takeNato(incoming: NatoForm) !struct { n: u8 } {
    return .{ .n = incoming.alpha_first };
}

test "the field list in a 400 stops at a bound and says how many it left out, so the sentence is never cut" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/nato", takeNato);

    var h = Harness.init();
    defer h.deinit();

    const body = "{\"alpha_frist\":1}";
    var buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&buf, "POST /nato HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
    const response = h.send(&app, request).response;

    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(try Harness.saysFailure(
        response,
        "a field \"alpha_frist\" this endpoint does not know. It takes: alpha_first, bravo_second, charlie_third, " ++
            "delta_fourth, echo_fifth, foxtrot_sixth, golf_seventh, and 5 more",
    ));
}

// Nine levels, which is one more than the walk follows. The bottom is where
// the mistake goes, so nothing above it can account for the refusal.
const Deep9 = struct { value: u32 };
const Deep8 = struct { down: Deep9 };
const Deep7 = struct { down: Deep8 };
const Deep6 = struct { down: Deep7 };
const Deep5 = struct { down: Deep6 };
const Deep4 = struct { down: Deep5 };
const Deep3 = struct { down: Deep4 };
const Deep2 = struct { down: Deep3 };
const Deep1 = struct { down: Deep2 };
const Deep0 = struct { down: Deep1 };

fn takeDeep(incoming: Deep0) !struct { value: u32 } {
    return .{ .value = incoming.down.down.down.down.down.down.down.down.down.value };
}

/// A comment tree: the shape of body `std.json` reads by recursing once per
/// level, with nothing but the stack to stop it.
const TreeNode = struct { name: []const u8 = "", c: []const TreeNode = &.{} };

fn takeTree(tree: TreeNode) !struct { children: usize } {
    return .{ .children = tree.c.len };
}

test "a body whose type holds itself is refused past the nesting it may have, before it is parsed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/tree", takeTree);

    var h = Harness.init();
    defer h.deinit();

    const levels = ctx_mod.max_json_nesting / 2;
    const cases = [_]struct { body: []const u8, status: []const u8 }{
        // Two levels a node, one past the limit: refused, where twenty
        // thousand of these used to take the process down.
        .{ .body = repeat("{\"c\":[", levels + 1) ++ "{}" ++ repeat("]}", levels + 1), .status = "400" },
        // At the limit, and read.
        .{ .body = repeat("{\"c\":[", levels - 1) ++ "{}" ++ repeat("]}", levels - 1), .status = "200" },
        // Brackets inside a string are text, not nesting.
        .{ .body = "{\"name\":\"" ++ repeat("[{", 100) ++ "\\\"\",\"c\":[]}", .status = "200" },
    };

    for (cases) |case| {
        var request_buf: [2048]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &request_buf,
            "POST /tree HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
            .{ case.body.len, case.body },
        );
        const response = h.send(&app, request).response;
        testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 ") and
            std.mem.startsWith(u8, response["HTTP/1.1 ".len..], case.status)) catch |err| {
            std.debug.print("body {s}\n  got: {s}\n", .{ case.body, response });
            return err;
        };
        if (case.status[0] == '4') try testing.expect(try Harness.saysFailure(
            response,
            "the body nests deeper than 64 levels, which is as deep as this endpoint reads",
        ));
    }
}

test "a body nested past the depth the walk follows says so, rather than nothing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/deep", takeDeep);

    var h = Harness.init();
    defer h.deinit();

    const opens = repeat("{\"down\":", 9);
    const closes = &@as([9]u8, @splat('}'));

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        // Below the ceiling there is nothing left to name, and the old
        // answer was a bare 400 with no sentence in it at all (ADR 034).
        .{
            .body = opens ++ "{\"value\":\"no\"}" ++ closes,
            .says = "nested deeper than 8 levels",
        },
        // The last level the walk *can* name still names it, so the new
        // sentence appears only where the old one said nothing.
        .{
            .body = opens ++ "\"oops\"" ++ closes,
            .says = "\"down.down.down.down.down.down.down.down.down\" has to be an object, not text",
        },
    };

    for (cases) |case| {
        var head_buf: [128]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buf,
            "POST /deep HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n",
            .{case.body.len},
        ) catch unreachable;
        var request_buf: [1024]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, case.body }) catch unreachable;
        const response = h.send(&app, request).response;

        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
}

// ---- 405 ----

fn testEchoOptions(c: *Ctx) anyerror!void {
    try c.sendText(200, "mine");
}

test "a path registered under another method is a 405 with Allow, not a 404" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.post("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "DELETE /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    // HEAD is in there without anybody registering one, because the GET
    // route already answers it.
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow: GET, HEAD, POST\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "DELETE is not allowed here") != null);
    // A wrong verb is a normal thing to answer, not a reason to hang up.
    try testing.expect(result.keep_alive);
}

test "a path nothing is registered under is still a 404" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "DELETE /nowhere HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow:") == null);
}

// ---- the failure body an application names (ADR 024) ----

const ApiError = struct {
    code: u16,
    detail: []const u8,

    pub fn nilo_failure(status: u16, message: []const u8) ApiError {
        return .{ .code = status, .detail = message };
    }
};

fn failsWithASentence(c: *Ctx) anyerror!void {
    _ = c;
    return fail.notFound("no order \"{d}\"", .{7});
}

test "app.failures gives every failure the application's shape, message and headers intact" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(ApiError);
    try app.get("/orders", failsWithASentence);
    try app.post("/orders", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    // A fail function's sentence, JSON-escaped by the same writer a handler's
    // answer goes through — nothing here escapes by hand.
    const failed = h.send(&app, "GET /orders HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "Content-Type: application/json\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, failed.response, "\r\n\r\n{\"code\":404,\"detail\":\"no order \\\"7\\\"\"}"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "\"error\":") == null);
    try testing.expect(failed.keep_alive);

    // The built-in 405 goes through the same place, so it takes the shape
    // too — and still carries the `Allow` it has to (ADR 024).
    const wrong_verb = h.send(&app, "DELETE /orders HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong_verb.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, wrong_verb.response, "Allow: GET, HEAD, POST\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, wrong_verb.response, "{\"code\":405,\"detail\":\"DELETE is not allowed here") != null);

    // And a route nobody registered.
    const nowhere = h.send(&app, "GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, nowhere.response, "{\"code\":404,\"detail\":\"there is no /nowhere\"}") != null);
}

test "app.failures is said once" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(ApiError);
    try testing.expectError(error.FailureShapeAlreadySet, app.failures(ApiError));
}

const Oversized = struct {
    padding: []const u8,
    detail: []const u8,

    pub fn nilo_failure(_: u16, message: []const u8) Oversized {
        return .{ .padding = &@as([2048]u8, @splat('x')), .detail = message };
    }
};

test "a shape that outgrows the failure buffer falls back to nilo's own, sentence intact" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(Oversized);
    try app.get("/orders", failsWithASentence);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /orders HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "\"padding\"") == null);
    try testing.expect(std.mem.endsWith(u8, result.response, "{\"error\":\"no order \\\"7\\\"\",\"status\":404}"));
}

test "a malformed head keeps nilo's own shape whatever app.failures said" {
    // Answered before there is a request to route, as a constant (ADR 159),
    // and `failurebody.zig` says why that is kept.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(ApiError);
    try app.get("/orders", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /orders HTTP/1.1\r\nHost: x\r\nBad Header\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"error\":\"malformed request\",\"status\":400}") != null);
}

test "a 405 knows about params and catch-alls, not just literal paths" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testQuiet);
    try app.patch("/files/*", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    const on_param = h.send(&app, "PUT /users/42 HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, on_param.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, on_param.response, "Allow: GET, HEAD\r\n") != null);

    const on_catch_all = h.send(&app, "POST /files/a/b/c.txt HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, on_catch_all.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, on_catch_all.response, "Allow: PATCH\r\n") != null);
}

test "an OPTIONS asking what a path supports is answered, not refused" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.post("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "OPTIONS /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 204 No Content\r\n"));
    // OPTIONS is in it: the path answers the request that asked (RFC 9110 §9.3.7).
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow: GET, HEAD, POST, OPTIONS\r\n") != null);
}

test "a route registered for the method still wins over the 405" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.options("/users", testEchoOptions);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "OPTIONS /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "mine") != null);
    // The framework's own Allow is not bolted onto an answer somebody else
    // wrote.
    try testing.expect(std.mem.indexOf(u8, result.response, "Allow:") == null);
}

test "middleware wraps a 405 the way it wraps everything else" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);
    try app.use(tagOuter);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "DELETE /users HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 405 Method Not Allowed\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer\r\n") != null);
}

// ---- stopping ----

test "once a stop is asked for, a connection answers what it has and closes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users", testQuiet);

    var h = Harness.init();
    defer h.deinit();

    const before = h.send(&app, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(before.keep_alive);
    // HTTP/1.1 staying open says nothing about it (ADR 197).
    try testing.expect(std.mem.indexOf(u8, before.response, "Connection:") == null);

    app.shutdown();

    // Still answered — a request already on the wire is not the client's
    // fault. What changes is that the connection is not offered again.
    const after = h.send(&app, "GET /users HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, after.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, after.response, "Connection: close\r\n") != null);
    try testing.expect(!after.keep_alive);
}

/// A handler that stops the server is an ordinary handler — which is what
/// an `/admin/quit` route is.
fn quitHandler(c: *Ctx) anyerror!void {
    c.service(*App).?.shutdown();
    try c.sendText(200, "going down\n");
}

test "a stop that lands mid-request still answers it, and says the socket is going" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&app);
    try app.get("/quit", quitHandler);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /quit HTTP/1.1\r\nHost: x\r\n\r\n");

    // The request arrived before the stop and is answered in full. Whether
    // the connection lives on is decided when the response is written, not
    // when the head was read, which is the only way this can be right.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "going down") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Connection: close\r\n") != null);
    try testing.expect(!result.keep_alive);
}

const Sort = enum { newest, oldest };

const SearchParams = struct {
    q: Str,
    page: u32 = 1,
    sort: Sort = .newest,
    tag: ?Str = null,
};

fn search(params: typed.Query(SearchParams)) !struct {
    q: []const u8,
    page: u32,
    sort: Sort,
    tag: ?[]const u8,
} {
    const p = params.value;
    return .{
        .q = p.q.view(),
        .page = p.page,
        .sort = p.sort,
        .tag = if (p.tag) |t| t.view() else null,
    };
}

test "Query(T) fills from the query string: defaults, optionals, decoding" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var h = Harness.init();
    defer h.deinit();

    // Only the required field given: the rest fall back to their defaults.
    const bare = h.send(&app, "GET /search?q=zig HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, bare.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(
        u8,
        bare.response,
        "{\"q\":\"zig\",\"page\":1,\"sort\":\"newest\",\"tag\":null}",
    ) != null);

    // Everything given, and percent-decoded on the way in like a path param.
    const full = h.send(&app, "GET /search?q=hello%20world&page=3&sort=oldest&tag=a+b HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(
        u8,
        full.response,
        "{\"q\":\"hello world\",\"page\":3,\"sort\":\"oldest\",\"tag\":\"a b\"}",
    ) != null);
}

test "a query param that is missing or malformed is a 400 that says which one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/search", search);

    var h = Harness.init();
    defer h.deinit();

    // No default and not optional, so absent is the client's mistake.
    const missing = h.send(&app, "GET /search HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "?q is required") != null);

    const not_a_number = h.send(&app, "GET /search?q=zig&page=soon HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, not_a_number.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(
        not_a_number.response,
        "?page has to be a whole number, not \"soon\"",
    ));

    // An enum says what it would have accepted, rather than only refusing.
    const bad_enum = h.send(&app, "GET /search?q=zig&sort=sideways HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, bad_enum.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, bad_enum.response, "newest, oldest") != null);

    // The connection survives all of it: a 400 is an answer, not a hang-up.
    try testing.expect(missing.keep_alive and not_a_number.keep_alive and bad_enum.keep_alive);
}

fn createWithLocation() typed.Response(UserOut) {
    return .{
        .status = 201,
        .headers = .of(&.{
            .{ .name = "Location", .value = "/users/7" },
            .{ .name = "X-Made-By", .value = "nilo" },
        }),
        .value = .{ .id = 7, .name = "wati" },
    };
}

test "Response(T) carries headers of its own, without reaching for a Ctx" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createWithLocation);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/7\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Made-By: nilo\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

fn deleteWithResponse() typed.Response(void) {
    return .{ .status = 204 };
}

fn deleteWithStatus() typed.Status(204, void) {
    return .{};
}

fn createWithStatus() typed.Status(201, UserOut) {
    return .{
        .headers = .of(&.{.{ .name = "Location", .value = "/users/7" }}),
        .value = .{ .id = 7, .name = "wati" },
    };
}

test "an empty response is a 204 with nothing after the head" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.delete("/one", deleteWithResponse);
    try app.delete("/two", deleteWithStatus);

    var h = Harness.init();
    defer h.deinit();

    // Both spellings answer the same thing. A 204 carries neither
    // Content-Type nor Content-Length — see `http1.bodyless` — and the
    // connection is fine to carry another request.
    defer date_mod.pinned = null;
    date_mod.pinned = 0;
    for ([_][]const u8{ "/one", "/two" }) |path| {
        var buf: [64]u8 = undefined;
        const request = std.fmt.bufPrint(&buf, "DELETE {s} HTTP/1.1\r\nHost: t\r\n\r\n", .{path}) catch unreachable;
        const result = h.send(&app, request);
        try testing.expectEqualStrings(
            "HTTP/1.1 204 No Content\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\n\r\n",
            result.response,
        );
        try testing.expect(result.keep_alive);
    }
}

test "a Status(code, T) answers that code and carries headers like a Response does" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createWithStatus);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/7\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

fn findUser(id: u32) !?UserOut {
    if (id != 7) return null;
    return .{ .id = 7, .name = "wati" };
}

test "a handler returning ?T answers 404 when there is none, and never sends null" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", findUser);

    var h = Harness.init();
    defer h.deinit();

    const found = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, found.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, found.response, "{\"id\":7,\"name\":\"wati\"}") != null);

    // Not `200 null`, which is what this used to be and what nobody meant
    // (ADR 023). The path is in the message, so the log says which one.
    const missing = h.send(&app, "GET /users/99 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(try Harness.saysFailure(missing.response, "there is no /users/99"));
    try testing.expect(missing.keep_alive);
}

const Gathered = struct { parts: []const []const u8 };

/// Four threads allocate from the request arena at once, each making two
/// thousand small allocations and building its part out of the last fifty,
/// and the handler returns a value that borrows all of it. The arena is
/// reset after the response is written, so the parts are still there when
/// it is serialised.
fn gatheredOnThreads(arena: std.mem.Allocator) !Gathered {
    const Part = struct {
        fn build(a: std.mem.Allocator, n: usize, out: *[]const u8) void {
            for (0..2000) |_| {
                const scrap = a.alloc(u8, 24) catch return;
                @memset(scrap, @intCast(n));
            }
            var text: []const u8 = "";
            for (0..50) |i| text = std.fmt.allocPrint(a, "{s}t{d}-{d},", .{ text, n, i }) catch return;
            out.* = text;
        }
    };
    const parts = try arena.alloc([]const u8, 4);
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, n| {
        parts[n] = "";
        t.* = try std.Thread.spawn(.{}, Part.build, .{ arena, n, &parts[n] });
    }
    for (threads) |t| t.join();
    return .{ .parts = parts };
}

test "threads a handler starts may allocate from the request arena at once, and its return may borrow it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/gathered", gatheredOnThreads);

    var h = Harness.init();
    defer h.deinit();
    const answer = h.send(&app, "GET /gathered HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200 OK\r\n"));
    for (0..4) |n| {
        var last: [16]u8 = undefined;
        const tail = try std.fmt.bufPrint(&last, "t{d}-49,", .{n});
        try testing.expect(std.mem.indexOf(u8, answer.response, tail) != null);
    }
}

/// The failure's `error` string, parsed out of a response body that has to
/// be JSON whatever the request held.
fn failureText(response: []const u8, into: []u8) ![]const u8 {
    const blank = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoBody;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response[blank + 4 ..], .{});
    defer parsed.deinit();
    const message = parsed.value.object.get("error").?.string;
    @memcpy(into[0..message.len], message);
    return into[0..message.len];
}

fn pageOf(params: typed.Query(struct { page: u32 = 1 })) u32 {
    return params.value.page;
}

fn itemById(id: u32) u32 {
    return id;
}

test "a failure whose message holds a byte that is not UTF-8 is still JSON, with U+FFFD in its place" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/items", pageOf);
    try app.get("/items/:id", itemById);

    var h = Harness.init();
    defer h.deinit();
    var said: [512]u8 = undefined;

    // A percent escape is decoded without a UTF-8 check, so the message that
    // names the value carries the stranger's byte (ADR 024).
    const query = h.send(&app, "GET /items?page=%ff HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, query.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, try failureText(query.response, &said), "\u{FFFD}") != null);

    const path = h.send(&app, "GET /items/%ff HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, path.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, try failureText(path.response, &said), "\u{FFFD}") != null);
}

test "a shape the application named gets text too, where the message held a byte that is not UTF-8" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.failures(ApiError);
    try app.get("/items", pageOf);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /items?page=%ff HTTP/1.1\r\nHost: t\r\n\r\n");
    const blank = std.mem.indexOf(u8, result.response, "\r\n\r\n").?;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, result.response[blank + 4 ..], .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("detail").?.string, "\u{FFFD}") != null);
}

fn caughtThenBroke() !void {
    // A lookup that said no, and a handler that took the no as an answer.
    const first: error{Failed}!void = fail.notFound("no such row", .{});
    first catch |e| switch (e) {
        error.Failed => {},
    };
    return error.OutOfMemory;
}

test "a failure a handler caught does not colour the error it returned later" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/caught", caughtThenBroke);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /caught HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 Internal Server Error\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "no such row") == null);
    try testing.expect(try Harness.saysFailure(result.response, "internal server error"));
}

fn headersBuiltInAFrameThatDies(arena: std.mem.Allocator, id: u32) !typed.Headers {
    return .of(&.{
        .{ .name = "Location", .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}) },
        .{ .name = "X-Made-By", .value = "nilo" },
    });
}

/// Walks over the stack the frame above left behind, so that a `Headers`
/// pointing back into it reads this rather than what it was given.
fn scribbleOverTheStack() u64 {
    var noise: [512]u8 = undefined;
    for (&noise, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    var total: u64 = 0;
    for (noise) |byte| total += byte;
    return total;
}

test "a Response's headers are copied out of the frame that wrote them" {
    // This is the test the old `headers: []const Header` could not pass in a
    // release build, and passed in Debug for a whole stage (ADR 018).
    var buffer: [64]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const headers = try headersBuiltInAFrameThatDies(fixed.allocator(), 42);

    std.mem.doNotOptimizeAway(scribbleOverTheStack());

    try testing.expectEqual(@as(usize, 2), headers.view().len);
    try testing.expectEqualStrings("Location", headers.view()[0].name);
    try testing.expectEqualStrings("/users/42", headers.view()[0].value);
    try testing.expectEqualStrings("nilo", headers.view()[1].value);

    // And a Response that says nothing about headers carries none.
    const quiet: typed.Response(u8) = .{ .value = 1 };
    try testing.expectEqual(@as(usize, 0), quiet.headers.view().len);
}

fn createInArena(arena: std.mem.Allocator, id: u32) !typed.Response(UserOut) {
    return .{
        .status = 201,
        .headers = .of(&.{.{
            .name = "Location",
            .value = try std.fmt.allocPrint(arena, "/users/{d}", .{id}),
        }}),
        .value = .{ .id = id, .name = "made" },
    };
}

test "a handler can ask for the request arena to build a header in" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users/:id", createInArena);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users/42 HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /users/42\r\n") != null);

    // The arena is reset between requests, so a second one is not looking
    // at what the first left behind.
    const again = h.send(&app, "POST /users/7 HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, again.response, "Location: /users/7\r\n") != null);
}

fn serveAnything(rest: Str) Str {
    return rest;
}

test "a catch-all route hands the rest of the path to the handler" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/files/*", serveAnything);
    try app.get("/files/readme", plainOk);

    var h = Harness.init();
    defer h.deinit();

    const deep = h.send(&app, "GET /files/css/site.css HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, deep.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, deep.response, "css/site.css"));

    // A literal route still wins over the catch-all it sits inside.
    const literal = h.send(&app, "GET /files/readme HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, literal.response, "handler"));

    const nothing = h.send(&app, "GET /elsewhere HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nothing.response, "HTTP/1.1 404"));
}

test "the same route registered twice is refused, naming the one already there" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", getUser);

    // Neither form can be called here: `app.get` stops the process the way
    // `listen()` does, and `tryRoute` reaches the same `std.log.err`, which
    // Zig's test runner counts as a failed test whatever `logFn` says. So
    // what is checked is the detection the refusal is built on. The wording
    // lives in `App.tryRoute`, and the shape rule in router.zig.
    try testing.expect(app.router.conflicting(.GET, "/users/:name") != null);
    try testing.expect(app.router.conflicting(.GET, "/users/me") == null);
    try testing.expectEqual(@as(usize, 1), app.router.routes.items.len);

    // A route that does not collide still goes in, so the check above is
    // not simply refusing everything.
    try app.tryRoute(.GET, "/users/me", testQuiet);
    try testing.expectEqual(@as(usize, 2), app.router.routes.items.len);
}

fn greet(name: Str) Str {
    return name;
}

fn multiply(a: i32, b: i32) i64 {
    return @as(i64, a) * b;
}

const Colour = enum { red, green, blue };

fn pickColour(c: Colour, bright: bool) []const u8 {
    return if (bright) @tagName(c) else "dark";
}

test "path params typed as Str, a number, an enum, and a bool" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/greet/:name", greet);
    try app.get("/times/:a/:b", multiply);
    try app.get("/colour/:c/:bright", pickColour);

    var h = Harness.init();
    defer h.deinit();

    const greeting = h.send(&app, "GET /greet/wati HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, greeting.response, "Content-Type: text/plain") != null);
    try testing.expect(std.mem.endsWith(u8, greeting.response, "wati"));

    const product = h.send(&app, "GET /times/6/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, product.response, "42"));

    const colour = h.send(&app, "GET /colour/green/true HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, colour.response, "green"));

    const wrong = h.send(&app, "GET /colour/purple/true HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, wrong.response, ":c is not one of the known choices") != null);
}

/// What `@tagName` returns, and what any field crossing a C boundary is
/// spelled as. A handler is as likely to have one of these in hand as a plain
/// `[]const u8`, and nothing about it is exotic.
fn sentinelName(c: Colour) [:0]const u8 {
    return @tagName(c);
}

const Sentinel = struct { name: [:0]const u8, id: u32 };

fn sentinelInside() Sentinel {
    return .{ .name = "wati", .id = 7 };
}

test "a sentinel-terminated string is text, and inside a struct it is a JSON string" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/tag/:c", sentinelName);
    try app.get("/held", sentinelInside);
    app.docs(.{ .title = "t", .version = "1" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Three files read this type and one of them got it right, which is the
    // worse half: the response went out as a JSON array of byte values under
    // `application/json` while the generated document said `type: string`.
    const tag = h.send(&app, "GET /tag/green HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, tag.response, "Content-Type: text/plain") != null);
    try testing.expect(std.mem.endsWith(u8, tag.response, "green"));

    const held = h.send(&app, "GET /held HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, held.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.endsWith(u8, held.response, "{\"name\":\"wati\",\"id\":7}"));

    // And the document says the same thing the body does, which is the check
    // that was missing when the two disagreed.
    const doc = h.send(&app, "GET /openapi.json HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, doc.response, "\"type\":\"string\"") != null);
    try testing.expect(std.mem.indexOf(u8, doc.response, "text/plain") != null);
}

test "the document can be written with no server, and is the same bytes the server serves" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/held", sentinelInside);
    app.docs(.{ .title = "t", .version = "1" });

    // Before anything listens, before any chain is resolved: the operations
    // are collected at registration, which is the whole claim (ADR 135).
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);
    const written = out.written();

    try testing.expect(std.mem.startsWith(u8, written, "{\"openapi\":\"3.1.0\","));
    try testing.expect(std.mem.indexOf(u8, written, "\"title\":\"t\"") != null);
    try testing.expect(std.mem.indexOf(u8, written, "/held") != null);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // The served copy and the written one come from one call now, and this
    // is what says so — a checked-in file that disagreed with the running
    // server is the failure the build step exists to prevent.
    const doc = h.send(&app, "GET /openapi.json HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, doc.response, written) != null);
}

test "a document written without app.docs still names itself" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/held", sentinelInside);

    // No `app.docs`, so nothing is served and there is no title to borrow.
    // A build step that only ever writes the file should still get one.
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try app.writeOpenApi(&out.writer);

    try testing.expect(std.mem.indexOf(u8, out.written(), "\"title\":\"API\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "/held") != null);
}

test "a service that was never registered is caught before serving" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", getUser); // needs *Db, which is not provided

    // `listen()` calls `checkServices()`, which logs each gap and then
    // fails. Here it is checked through the predicate instead, so the test
    // does not count those error logs as a failure.
    const missing = app.missingService().?;
    try testing.expectEqualStrings("/users/:id", missing.route);
    try testing.expectEqualStrings(@typeName(Db), missing.type_name);
    try testing.expect(missing.needs_mutable);
}

const Config = struct { debug: bool };

fn showMode(cfg: *const Config, c: *Ctx) !void {
    try c.sendText(200, if (cfg.debug) "debug" else "release");
}

test "a const service and a *Ctx can be asked for together" {
    const cfg = Config{ .debug = true };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&cfg);
    try app.get("/mode", showMode);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /mode HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "debug"));
}

test "HEAD gives the same head as GET, with no body" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.head("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const got = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    const got_head = got.response[0 .. std.mem.indexOf(u8, got.response, "\r\n\r\n").? + 4];

    const headed = h.send(&app, "HEAD /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");

    // The head is identical — including the Content-Length naming the
    // length of the body it would have sent — but not one byte of body.
    try testing.expectEqualStrings(got_head, headed.response);
    try testing.expect(std.mem.indexOf(u8, headed.response, "Content-Length: 22\r\n") != null);
    try testing.expect(headed.keep_alive);
}

test "HEAD on an unknown route and on the failure path is also body-less" {
    var db = Db{ .rows = &.{} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.head("/users/:id", getUser);

    var h = Harness.init();
    defer h.deinit();

    const failed = h.send(&app, "HEAD /users/99 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, failed.response, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "no user 99") == null);

    const unrouted = h.send(&app, "HEAD /nowhere HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, unrouted.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, unrouted.response, "\r\n\r\n"));
}

fn ctxOnly(c: *Ctx) !void {
    // A `*Ctx` handler may ignore the path params in the pattern; it
    // fetches whichever ones it needs itself.
    try c.sendText(200, c.param("id").?.view());
}

test "a *Ctx handler need not declare the path params" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/raw/:id/:other", ctxOnly);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /raw/42/x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "42"));
}

// ---- stage 4: response headers and middleware ----

fn setsHeaders(c: *Ctx) anyerror!void {
    try c.setHeader("X-One", "1");
    try c.setHeader("X-Two", "2");
    try c.sendText(200, "ok");
}

test "extra response headers are written after the framework's own" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/h", setsHeaders);

    var h = Harness.init();
    defer h.deinit();
    defer date_mod.pinned = null;
    date_mod.pinned = 0;
    const result = h.send(&app, "GET /h HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nDate: Thu, 01 Jan 1970 00:00:00 GMT\r\nContent-Type: text/plain\r\n" ++
            "Content-Length: 2\r\nX-One: 1\r\nX-Two: 2\r\n\r\nok",
        result.response,
    );
}

fn injectedHeader(c: *Ctx) anyerror!void {
    // The shape `redirect.zig`'s own headline example takes: a `Location`
    // built from data somebody else supplied. Unrefused, the `\r\n` ends the
    // header block and everything after it is a header the application never
    // wrote.
    const from_the_database = "/welcome\r\nSet-Cookie: admin=1";
    // `error.Failed` rather than a bare error of its own: each of these is a
    // 500 carrying a sentence that says which header and why (ADR 029).
    try testing.expectError(error.Failed, c.redirect(302, from_the_database));
    try testing.expectError(error.Failed, c.setHeader("X-Note", from_the_database));
    try testing.expectError(error.Failed, c.setHeader("X-Note", "a\x00b"));
    try testing.expectError(error.Failed, c.setHeader("X-Note: forged", "b"));
    try testing.expectError(error.Failed, c.setHeader("", "b"));

    // Nothing was kept from any of them, so the response is the one the
    // handler goes on to send and no half-written header is left behind.
    try testing.expectEqual(@as(usize, 0), c.extraHeaders().len);
    try c.redirect(302, "/welcome");
}

test "a header value carrying a line break cannot write the rest of the response" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/go", injectedHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /go HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "Set-Cookie") == null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Location: /welcome\r\n") != null);
}

fn reservedHeader(c: *Ctx) anyerror!void {
    // A refusal from `putHeader` is a fail function, so it arrives as
    // `error.Failed` with a sentence attached rather than as a bare error
    // name the client would see as "internal server error" (ADR 029).
    try testing.expectError(error.Failed, c.setHeader("Content-Length", "999"));
    try testing.expectError(error.Failed, c.setHeader("connection", "close"));
    // Setting the same header twice replaces it rather than sending both.
    try c.setHeader("X-Once", "first");
    try c.setHeader("x-once", "second");
    try c.sendText(200, "ok");
}

test "framework-owned headers are refused, repeats replace" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/h", reservedHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /h HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "x-once: second") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "first") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.response, "Content-Length:"));
}

/// The shape the guide's own `Redirect` example has: a destination that came
/// out of a database, handed straight to a header.
fn splittingRedirect(c: *Ctx) anyerror!void {
    try c.redirect(302, "/welcome\r\nX-Injected: yes\r\n\r\nHTTP/1.1 200 OK");
}

test "a header value carrying a newline is refused, not written" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/go", splittingRedirect);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /go HTTP/1.1\r\nHost: t\r\n\r\n");

    // The forged header never reaches the wire, and neither does the second
    // status line behind it.
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Injected") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result.response, "HTTP/1.1"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Location:") == null);

    // And it is a 500 that says why, rather than a 302 that quietly dropped
    // the header the handler asked for.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 "));
    try testing.expect(try Harness.saysFailure(result.response, "carriage return or a newline"));
}

fn splittingCookieHeader(c: *Ctx) anyerror!void {
    // `Set-Cookie` through `setHeader` rather than `setCookie` — the route a
    // `Response`'s or a `Redirect`'s `.headers` takes, which never reaches
    // `cookie.check` and so was the one way past it (ADR 029).
    try c.setHeader("Set-Cookie", "session=abc\r\nX-Injected: yes");
    try c.sendText(200, "ok");
}

test "a Set-Cookie set as a plain header is checked like every other one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/c", splittingCookieHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /c HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Injected") == null);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 "));
}

/// A MIME type handed on from somewhere the handler does not control: an
/// upload's declared type, an upstream's answer.
fn splittingContentType(c: *Ctx) anyerror!void {
    try c.send(200, "text/plain\r\nX-Injected: yes", "ok");
}

fn splittingStreamType(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain\r\nX-Injected: yes");
    try body.finish();
}

test "a content type carrying a newline is refused like any other header value" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/sent", splittingContentType);
    try app.get("/streamed", splittingStreamType);

    for ([_][]const u8{ "/sent", "/streamed" }) |path| {
        var h = Harness.init();
        defer h.deinit();
        var req: [64]u8 = undefined;
        const result = h.send(&app, try std.fmt.bufPrint(&req, "GET {s} HTTP/1.1\r\nHost: t\r\n\r\n", .{path}));
        try testing.expect(std.mem.indexOf(u8, result.response, "X-Injected") == null);
        try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 "));
        try testing.expect(try Harness.saysFailure(result.response, "carriage return or a newline"));
    }
}

fn brokenHeaderName(c: *Ctx) anyerror!void {
    try testing.expectError(error.Failed, c.setHeader("X-Bad: injected", "1"));
    try testing.expectError(error.Failed, c.setHeader("X-Bad\r\nX-Other", "1"));
    // A value may hold a space and a tab; it is the control bytes that go.
    try c.setHeader("X-Fine", "one, two\ttext");
    try c.sendText(200, "ok");
}

test "a header name that is not a token is refused, and an ordinary value still passes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/n", brokenHeaderName);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /n HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Fine: one, two\ttext\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Bad") == null);
}

fn tagOuter(c: *Ctx, next: mw.Next) anyerror!void {
    try c.setHeader("X-Order", "outer");
    try next.run(c);
}

fn tagInner(c: *Ctx, next: mw.Next) anyerror!void {
    try c.setHeader("X-Inner", "yes");
    try next.run(c);
}

/// Runs the rest of the onion and does nothing else — a middleware that set
/// a header would have the budget test measuring the header instead.
///
/// It counts, because "allocated nothing" is also what an empty chain looks
/// like: without this the test would pass just as happily if the middleware
/// never ran at all, which is the way this could break.
var pass_through_runs: usize = 0;

fn passThrough(c: *Ctx, next: mw.Next) anyerror!void {
    pass_through_runs += 1;
    return next.run(c);
}

fn rejectingMiddleware(_: *Ctx, _: mw.Next) anyerror!void {
    return fail.unauthorized("no token", .{});
}

fn answeringMiddleware(c: *Ctx, _: mw.Next) anyerror!void {
    try c.sendText(200, "from middleware");
}

fn plainOk(c: *Ctx) anyerror!void {
    try c.sendText(200, "handler");
}

test "middleware wraps the handler and can set response headers" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "handler"));
}

test "use and get can be registered in either order" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    // Route first, middleware second — Fiber's classic gotcha, where the
    // middleware would silently never run.
    try app.get("/x", plainOk);
    try app.use(tagOuter);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
}

var forgetful_reached = false;

/// A guard that meant `if (!ok(c)) return c.fail(401, …)` and wrote `return`.
fn forgetfulGuard(_: *Ctx, _: mw.Next) anyerror!void {}

fn noteReached(_: *Ctx) anyerror!void {
    forgetful_reached = true;
}

fn answersNothing(_: *Ctx) anyerror!void {}

test "a middleware that returns without answering or calling next is a 500, not an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.use(forgetfulGuard);
    try app.get("/x", noteReached);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    forgetful_reached = false;
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 "));
    try testing.expect(!forgetful_reached);
}

test "a handler under middleware that returns without answering is still an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.get("/x", answersNothing);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
}

test "a prefix scopes middleware to the routes under it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/api", tagInner);
    try app.get("/api/thing", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const on = h.send(&app, "GET /api/thing HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, on.response, "X-Inner: yes") != null);

    const off = h.send(&app, "GET /health HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, off.response, "X-Inner") == null);
}

test "a prefix carrying a param scopes middleware the same way" {
    // The multi-tenant shape, which used to be a compile error. Three things
    // have to hold: the route under it, the 404 under it — that one was
    // genuinely broken, because the cold path matches against the real path
    // rather than the pattern — and a neighbouring tree staying untouched.
    var app = App.init(testing.allocator);
    defer app.deinit();

    var orgs = app.group("/orgs/:org");
    try orgs.use(tagInner);
    try orgs.get("/members", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const on = h.send(&app, "GET /orgs/acme/members HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, on.response, "X-Inner: yes") != null);

    const missing = h.send(&app, "GET /orgs/acme/nothing-here HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 404"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "X-Inner: yes") != null);

    const off = h.send(&app, "GET /health HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, off.response, "X-Inner") == null);
}

test "middleware that answers short-circuits the handler" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(answeringMiddleware);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "from middleware"));
}

test "middleware failing goes through the same path as a handler failing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/api", rejectingMiddleware);
    try app.get("/api/secret", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /api/secret HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "no token") != null);
    try testing.expect(result.keep_alive);
}

test "a middleware scoped to a path covers it when a * route is what matched" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/files/private", rejectingMiddleware);
    try app.get("/files/*", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const private = h.send(&app, "GET /files/private/x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, private.response, "HTTP/1.1 401 Unauthorized\r\n"));
    // Spelled with a percent escape, the segment is still `private`.
    const escaped = h.send(&app, "GET /files/%70rivate/x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, escaped.response, "HTTP/1.1 401 Unauthorized\r\n"));
    // And the rest of what the `*` serves is not behind it.
    const public = h.send(&app, "GET /files/public/x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, public.response, "HTTP/1.1 200 OK\r\n"));
}

test "a middleware scoped to a path covers it when a :param route is what matched" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/admin", rejectingMiddleware);
    try app.get("/:page/settings", plainOk);
    try app.get("/*", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const admin = h.send(&app, "GET /admin/settings HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, admin.response, "HTTP/1.1 401 Unauthorized\r\n"));
    const fallback = h.send(&app, "GET /admin/anything/else HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, fallback.response, "HTTP/1.1 401 Unauthorized\r\n"));
    const home = h.send(&app, "GET /home/settings HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, home.response, "HTTP/1.1 200 OK\r\n"));
}

test "middleware runs even when no route matched" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tagOuter);
    try app.get("/known", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /nowhere HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
    // A logger has to be able to see 404s, and CORS has to answer
    // preflights for paths with no route (ADR 008).
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order: outer") != null);
}

test "CORS adds its headers and answers a preflight" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const normal = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, normal.response, "Access-Control-Allow-Origin: *") != null);
    try testing.expect(std.mem.endsWith(u8, normal.response, "handler"));

    // A preflight on a path with no OPTIONS route is still answered.
    const preflight = h.send(
        &app,
        "OPTIONS /x HTTP/1.1\r\nHost: t\r\nAccess-Control-Request-Method: POST\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, preflight.response, "HTTP/1.1 204 No Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, preflight.response, "Access-Control-Allow-Methods:") != null);
    try testing.expect(std.mem.indexOf(u8, preflight.response, "Access-Control-Allow-Headers:") != null);
}

fn alwaysFails(_: *Ctx) anyerror!void {
    return fail.notFound("nope", .{});
}

test "headers middleware set survive onto a failure response" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.get("/gone", alwaysFails);
    try app.get("/quiet2", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // An error response that quietly dropped its CORS headers is one the
    // browser refuses to show — the worst moment to lose them.
    const failed = h.send(&app, "GET /gone HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "Access-Control-Allow-Origin: *") != null);

    // Same for the empty 200 App fills in when a handler sends nothing.
    const quiet = h.send(&app, "GET /quiet2 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, quiet.response, "Access-Control-Allow-Origin: *") != null);
}

test "CORS with a named origin also sends Vary" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://example.com"}, .credentials = true }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(
        &app,
        "GET /x HTTP/1.1\r\nHost: t\r\nOrigin: https://example.com\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, result.response, "Access-Control-Allow-Origin: https://example.com") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Vary: Origin") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Access-Control-Allow-Credentials: true") != null);
}

test "two named origins each get told about themselves and nobody else" {
    // The whole point of the list: `Access-Control-Allow-Origin` carries one
    // value, so a server answering two front ends has to send back the one
    // that asked.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{
        .origins = &.{ "https://app.example.com", "https://staging.example.com" },
        .credentials = true,
    }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    for ([_][]const u8{ "https://app.example.com", "https://staging.example.com" }) |origin| {
        var buf: [128]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &buf,
            "GET /x HTTP/1.1\r\nHost: t\r\nOrigin: {s}\r\n\r\n",
            .{origin},
        );
        const answer = h.send(&app, request);

        var expected: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &expected,
            "Access-Control-Allow-Origin: {s}\r\n",
            .{origin},
        );
        try testing.expect(std.mem.indexOf(u8, answer.response, line) != null);
        try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Origin") != null);
    }
}

test "an origin nobody named is answered, and the browser is what refuses it" {
    // Not a 403: the response goes out as usual and simply does not carry the
    // header that would let the page read it. Deciding here would mean a
    // server that answers differently to a `curl` and a browser, which is not
    // what CORS is.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://app.example.com"} }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(
        &app,
        "GET /x HTTP/1.1\r\nHost: t\r\nOrigin: https://evil.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Allow-Origin") == null);
    // Still said, so a shared cache cannot store this refusal and hand it to
    // the origin that would have been allowed.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Origin") != null);
}

test "a request with no Origin is not cross-origin and gets no allow header" {
    // Where the named list stopped behaving like the single string it
    // replaced: that sent the header to everybody, including a same-origin
    // request that never asked. A browser ignores it either way, and sending
    // one origin's name to a request from somewhere else was never right.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://app.example.com"} }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Allow-Origin") == null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Origin") != null);
}

test "a preflight from a named origin is answered 204 with the methods" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{
        .origins = &.{ "https://a.example.com", "https://b.example.com" },
        .max_age = 600,
    }));
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(
        &app,
        "OPTIONS /x HTTP/1.1\r\nHost: t\r\nOrigin: https://b.example.com\r\n" ++
            "Access-Control-Request-Method: GET\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 204"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Allow-Origin: https://b.example.com") != null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Allow-Methods:") != null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Max-Age: 600") != null);
}

test "\"*\" still answers anyone, and says nothing about Vary" {
    // The default, and the one shape that does not read the request at all.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(
        &app,
        "GET /x HTTP/1.1\r\nHost: t\r\nOrigin: https://anywhere.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, answer.response, "Access-Control-Allow-Origin: *") != null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Origin") == null);
}

test "csrf refuses a POST from another site before the handler runs, naming the origin" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(csrf.sameOrigin);
    try app.post("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(
        &app,
        "POST /x HTTP/1.1\r\nHost: example.dev\r\nSec-Fetch-Site: cross-site\r\n" ++
            "Origin: https://evil.example\r\nContent-Length: 0\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 403"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "handler") == null);
    try testing.expect(try Harness.saysFailure(answer.response, "\"https://evil.example\""));
    try testing.expect(try Harness.saysFailure(answer.response, "csrf .origins"));
}

test "csrf lets through this server's own page, a link from anywhere, and curl" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(csrf.sameOrigin);
    try app.post("/x", plainOk);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const cases = [_][]const u8{
        // A browser saying so.
        "POST /x HTTP/1.1\r\nHost: example.dev\r\nSec-Fetch-Site: same-origin\r\n" ++
            "Origin: https://example.dev\r\nContent-Length: 0\r\n\r\n",
        // A browser too old for Sec-Fetch-Site, whose Origin names the Host.
        "POST /x HTTP/1.1\r\nHost: example.dev\r\nOrigin: https://example.dev\r\n" ++
            "Content-Length: 0\r\n\r\n",
        // A link from another site: a GET changes nothing and is not asked.
        "GET /x HTTP/1.1\r\nHost: example.dev\r\nSec-Fetch-Site: cross-site\r\n\r\n",
        // Not a browser, so there is no cookie of somebody else's on it.
        "POST /x HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 0\r\n\r\n",
    };
    for (cases) |request| {
        const answer = h.send(&app, request);
        try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
        try testing.expect(std.mem.endsWith(u8, answer.response, "handler"));
    }
}

fn ownPolicy(c: *Ctx) anyerror!void {
    try c.setHeader("Content-Security-Policy", "default-src 'self'");
    try c.sendText(200, "page");
}

test "nilo.secure writes its policy on an answer and on a failure, once each" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(secure.api(.{}));
    try app.get("/x", plainOk);
    try app.get("/gone", alwaysFails);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const ok = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, ok.response, "\r\nX-Content-Type-Options: nosniff\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, ok.response, "\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, ok.response, "\r\nReferrer-Policy: no-referrer\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, ok.response, "\r\n\r\nhandler"));

    // A refusal is an answer a browser renders too, and a JSON error page
    // that could be sniffed as HTML is the case nosniff exists for.
    const failed = h.send(&app, "GET /gone HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, failed.response, "X-Content-Type-Options: nosniff\r\n"));
}

test "a handler's own Content-Security-Policy replaces the one nilo.secure wrote" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(secure.pages(.{}));
    try app.get("/page", ownPolicy);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Two CSP lines would be enforced together, and the page would get the
    // intersection of the two, which is the policy nobody wrote.
    const page = h.send(&app, "GET /page HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, page.response, "Content-Security-Policy:"));
    try testing.expect(std.mem.indexOf(u8, page.response, "Content-Security-Policy: default-src 'self'\r\n") != null);
    // The rest of the block is still there.
    try testing.expect(std.mem.indexOf(u8, page.response, "X-Frame-Options: SAMEORIGIN\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, page.response, "Cross-Origin-Resource-Policy: same-origin\r\n") != null);
}

test "a group's nilo.secure replaces the App's rather than adding to it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(secure.api(.{}));
    const site = app.group("/app");
    try site.use(secure.pages(.{}));
    try site.get("/home", plainOk);
    try app.get("/api/thing", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const inside = h.send(&app, "GET /app/home HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, inside.response, "Content-Security-Policy:"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, inside.response, "X-Content-Type-Options:"));
    try testing.expect(std.mem.indexOf(u8, inside.response, "X-Frame-Options: SAMEORIGIN\r\n") != null);

    const outside = h.send(&app, "GET /api/thing HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, outside.response, "X-Frame-Options: DENY\r\n") != null);
}

test "nilo.secure beside a named-origin CORS adds nothing to the request path's allocations" {
    // Seven policy headers would have taken every slot the Ctx holds and
    // pushed CORS and gzip into the arena; as one block they take one
    // (ADR 246). The same request as the allocation budget's, with the
    // larger preset and a CORS that writes two headers of its own.
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.with(.{ .origins = &.{"https://example.dev"} }));
    try app.use(secure.pages(.{ .embedder_policy = .credentialless, .permissions_policy = "camera=()" }));
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nOrigin: https://example.dev\r\n" ++
        "Accept: */*\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // The JSON body, as in the budget test, and nothing for the policy.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
    try testing.expect(std.mem.indexOf(u8, &buf, "Permissions-Policy: camera=()\r\n") != null);
}

test "csrf takes a named front end, from a list or from the Origins CORS reads" {
    const Held = struct {
        var origins: cors.Origins = .empty;
    };
    try Held.origins.set(&.{"https://app.example.com"});

    const from_front_end =
        "POST /x HTTP/1.1\r\nHost: api.example.com\r\nSec-Fetch-Site: same-site\r\n" ++
        "Origin: https://app.example.com\r\nContent-Length: 0\r\n\r\n";
    const from_elsewhere =
        "POST /x HTTP/1.1\r\nHost: api.example.com\r\nSec-Fetch-Site: same-site\r\n" ++
        "Origin: https://uploads.example.com\r\nContent-Length: 0\r\n\r\n";

    inline for (.{
        csrf.with(.{ .origins = &.{"https://app.example.com"} }),
        csrf.reading(&Held.origins),
    }) |middleware| {
        var app = App.init(testing.allocator);
        defer app.deinit();
        try app.use(middleware);
        try app.post("/x", plainOk);

        var h = Harness.init();
        defer h.deinit();
        try h.ready(&app);

        try testing.expect(std.mem.startsWith(u8, h.send(&app, from_front_end).response, "HTTP/1.1 200"));
        // Another subdomain of the same site: what SameSite=Lax would have
        // sent the cookie with.
        try testing.expect(std.mem.startsWith(u8, h.send(&app, from_elsewhere).response, "HTTP/1.1 403"));
    }
}

test "a route that takes posts from anywhere says so with without" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(csrf.sameOrigin);
    try app.post("/x", plainOk);
    try app.without(csrf.sameOrigin).post("/hook", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const cross = "HTTP/1.1\r\nHost: example.dev\r\nSec-Fetch-Site: cross-site\r\n" ++
        "Origin: https://partner.example\r\nContent-Length: 0\r\n\r\n";
    try testing.expect(std.mem.startsWith(u8, h.send(&app, "POST /hook " ++ cross).response, "HTTP/1.1 200"));
    try testing.expect(std.mem.startsWith(u8, h.send(&app, "POST /x " ++ cross).response, "HTTP/1.1 403"));
}

/// How many times the arena is asked for memory by one warm POST, with the
/// CSRF middleware installed or not. The request is a modern browser's from
/// the server's own page, which is what almost every guarded request is.
fn postAllocations(comptime guarded: bool) !usize {
    var app = App.init(testing.allocator);
    defer app.deinit();
    if (guarded) try app.use(csrf.sameOrigin);
    try app.post("/x", plainOk);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;
    const request = "POST /x HTTP/1.1\r\nHost: example.dev\r\nSec-Fetch-Site: same-origin\r\n" ++
        "Origin: https://example.dev\r\nContent-Length: 0\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
    return counting.allocs;
}

test "csrf adds no allocation to the request it lets through" {
    // Three header reads into the request head, and a compare. ADR 224's
    // number for the allocations axis is this test.
    try testing.expectEqual(try postAllocations(false), try postAllocations(true));
}

// ---- stage 5: percent-decoding, chunked bodies, static files ----

fn echoParamAndQuery(c: *Ctx) anyerror!void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{s}|{s}", .{
        c.param("name").?.view(),
        if (c.query("q")) |q| q.view() else "-",
    });
    try c.sendText(200, text);
}

test "path params and query values arrive decoded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/hello/:name", echoParamAndQuery);

    var h = Harness.init();
    defer h.deinit();

    const spaced = h.send(&app, "GET /hello/wati%20sari?q=caf%C3%A9+latte HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, spaced.response, "wati sari|café latte"));

    // An encoded slash is one character of data. Had the target been
    // decoded before matching, this would have been three segments and
    // would not have matched /hello/:name at all.
    const slashed = h.send(&app, "GET /hello/a%2Fb HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, slashed.response, "a/b|-"));
}

fn echoBody(c: *Ctx) anyerror!void {
    try c.sendText(200, (try c.body()).view());
}

test "a chunked body reaches the handler and keep-alive survives it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.get("/after", plainOk);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, result.response, "hello world"));
    try testing.expect(result.keep_alive);
}

test "Expect: 100-continue is answered the moment the body is about to be read" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
    );
    // The interim first, whole and on its own, then the answer. A client that
    // gets neither waits on its own timer — curl's is a second, on every
    // upload past its threshold, which is what this costs when it is missing.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 "));
    try testing.expect(std.mem.endsWith(u8, result.response, "hello"));
    try testing.expect(result.keep_alive);
}

test "a chunked body expecting a continue gets one too" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 100 Continue\r\n\r\n"));
    try testing.expect(std.mem.endsWith(u8, result.response, "hello"));
}

test "a request that is refused before the body gets its status and no continue" {
    // The other half of RFC 9110 §10.1.1, and the half that is worth more: a
    // client holding back 20 MB is told no without sending a byte of it.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();

    // Nothing routes here, so nothing ever asks for the body.
    const missing = h.send(
        &app,
        "POST /nowhere HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.indexOf(u8, missing.response, "100 Continue") == null);
    // And the connection cannot carry another request, because this one still
    // has a body on the client's side that nobody is going to read.
    try testing.expect(!missing.keep_alive);

    // A body over the ceiling is refused by `Ctx.body` before it reads, so
    // the 413 goes out with the upload still unsent.
    const too_big = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 99999999\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, too_big.response, "HTTP/1.1 413 "));
    try testing.expect(std.mem.indexOf(u8, too_big.response, "100 Continue") == null);
    try testing.expect(!too_big.keep_alive);
}

test "a continue is not sent to a client that could not use one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();

    // HTTP/1.0 has no interim responses at all (RFC 9110 §15.2).
    const old = h.send(
        &app,
        "POST /echo HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
    );
    try testing.expect(std.mem.indexOf(u8, old.response, "100 Continue") == null);
    try testing.expect(std.mem.endsWith(u8, old.response, "hello"));

    // A body framed as empty is a client holding nothing back, whatever it
    // said it expected.
    const empty = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nExpect: 100-continue\r\nContent-Length: 0\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, empty.response, "100 Continue") == null);
    try testing.expect(empty.keep_alive);

    // And the ordinary request, which is every request: no header, no interim,
    // nothing changed.
    const plain = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 5\r\n\r\nhello",
    );
    try testing.expect(std.mem.startsWith(u8, plain.response, "HTTP/1.1 200 "));
    try testing.expect(plain.keep_alive);
}

test "a chunked body nobody read is still stepped over" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/ignore", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    // Two requests down one connection: the second only parses if the
    // first body was consumed to exactly the right byte.
    var in = std.Io.Reader.fixed(
        "POST /ignore HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n" ++
            "GET /ignore HTTP/1.1\r\nHost: t\r\n\r\n",
    );
    var out = std.Io.Writer.fixed(&h.buf);
    try testing.expect(app.handleRequest(h.arena.allocator(), &h.lifetime, &h.in_flight, &in, &out, .off, .off, .{}));

    const next = try http1.readRequest(&in);
    try testing.expectEqualStrings("/ignore", next.target);
}

test "a chunked body whose sizes do not add up gets a 400, not silence" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();
    // Says 5 bytes, then does not put a CRLF where one has to be.
    const result = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhelloXX\r\n0\r\n\r\n",
    );

    // The stream is at an unknown byte now, so the connection goes — but
    // the client is still told why rather than having the door shut on it.
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(!result.keep_alive);
}

test "HEAD with no HEAD route falls back to the GET one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/page", plainOk);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "HEAD /page HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Length: 7\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\n")); // no body
}

/// A directory of real files on disk, written for one test and removed
/// after it. Returned as a path relative to the working directory, which
/// is what `app.static` takes.
const TmpFiles = struct {
    tmp: nilo_testing.TmpDir,
    path: [:0]u8,

    fn init(gpa: std.mem.Allocator, files: []const [2][]const u8) !TmpFiles {
        var tmp = nilo_testing.tmpDir();
        errdefer tmp.cleanup();
        for (files) |entry| {
            if (std.fs.path.dirname(entry[0])) |sub| try tmp.dir.createDirPath(std.testing.io, sub);
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = entry[0], .data = entry[1] });
        }
        return .{
            .tmp = tmp,
            .path = try tmp.pathAlloc(gpa, ""),
        };
    }

    fn deinit(self: *TmpFiles, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }
};

test "static files: content type, ETag, 304, index and the dotfile that is not served" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>home</h1>" },
        .{ "app.css", "body{}" },
        .{ "docs/index.html", "<h1>docs</h1>" },
        .{ ".env", "SECRET=1" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const css = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, css.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, css.response, "Content-Type: text/css; charset=utf-8") != null);
    try testing.expect(std.mem.indexOf(u8, css.response, "Cache-Control: public, max-age=3600") != null);
    try testing.expect(std.mem.endsWith(u8, css.response, "body{}"));

    // A directory path picks up its index.html.
    const home = h.send(&app, "GET / HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, home.response, "<h1>home</h1>"));
    const docs = h.send(&app, "GET /docs/ HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, docs.response, "<h1>docs</h1>"));

    // A dotfile that found its way into the directory is not published.
    const dotfile = h.send(&app, "GET /.env HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, dotfile.response, "HTTP/1.1 404"));

    // The ETag the last response carried, handed back, costs no body.
    const etag = serve.findStaticFile(&app, .GET, "/app.css").?.file.etag;
    var request_buf: [256]u8 = undefined;
    const conditional = std.fmt.bufPrint(
        &request_buf,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nIf-None-Match: {s}\r\n\r\n",
        .{etag},
    ) catch unreachable;
    const not_modified = h.send(&app, conditional);
    try testing.expect(std.mem.startsWith(u8, not_modified.response, "HTTP/1.1 304 Not Modified\r\n"));
    try testing.expect(std.mem.indexOf(u8, not_modified.response, "body{}") == null);
}

test "static files: routes win, a prefix scopes, and middleware still wraps" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "app.js", "console.log(1)" },
        .{ "index.html", "spa" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.permissive);
    try app.staticWith("/assets", files.path, .{ .spa_fallback = "index.html" });
    try app.get("/assets/app.js", plainOk); // deliberately shadows the file

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A route beats a file of the same name.
    const shadowed = h.send(&app, "GET /assets/app.js HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, shadowed.response, "handler"));

    // The SPA fallback catches a deep link under the prefix — and CORS,
    // registered as ordinary middleware, wraps the static response too.
    const deep = h.send(&app, "GET /assets/users/42 HTTP/1.1\r\nHost: t\r\nSec-Fetch-Mode: navigate\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, deep.response, "spa"));
    try testing.expect(std.mem.indexOf(u8, deep.response, "Access-Control-Allow-Origin: *") != null);

    // Outside the prefix nothing is claimed.
    const outside = h.send(&app, "GET /users/42 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, outside.response, "HTTP/1.1 404"));
}

test "an asset that is not there is a 404, and a deep link is still the page" {
    // What this is about is the stale build hash (ADR 087): `index.html`
    // referring to a bundle the directory no longer holds used to answer 200
    // with the page, and the browser reported a syntax error on line 1 of
    // something that was never JavaScript.
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "app.js", "console.log(1)" },
        .{ "index.html", "<h1>spa</h1>" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.staticWith("/", files.path, .{ .spa_fallback = "index.html" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const gone = h.send(&app, "GET /app.abc123.js HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, gone.response, "HTTP/1.1 404"));
    // And it says which file, which the page never could.
    try testing.expect(std.mem.indexOf(u8, gone.response, "/app.abc123.js") != null);

    // A call that named a type it wants is not a navigation either.
    const call = h.send(
        &app,
        "GET /api/orders HTTP/1.1\r\nHost: t\r\nAccept: application/json\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, call.response, "HTTP/1.1 404"));

    // The reload the fallback exists for still works, from a browser that
    // sends fetch metadata…
    const browser = "GET /users/42 HTTP/1.1\r\nHost: t\r\n" ++
        "Sec-Fetch-Mode: navigate\r\nAccept: text/html,application/xhtml+xml,*/*;q=0.8\r\n\r\n";
    try testing.expect(std.mem.endsWith(u8, h.send(&app, browser).response, "<h1>spa</h1>"));
    // …and from one that does not but asks for HTML by name.
    const older = "GET /users/42 HTTP/1.1\r\nHost: t\r\nAccept: text/html,*/*;q=0.8\r\n\r\n";
    try testing.expect(std.mem.endsWith(u8, h.send(&app, older).response, "<h1>spa</h1>"));

    // The file that is there is unaffected, whatever it asked for.
    const real = h.send(&app, "GET /app.js HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, real.response, "console.log(1)"));
}

test "a single-page app can ask for what shipped before, and gets it" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>spa</h1>" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.staticWith("/", files.path, .{
        .spa_fallback = "index.html",
        .spa_fallback_for = .any_path,
    });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const asset = h.send(&app, "GET /app.abc123.js HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, asset.response, "<h1>spa</h1>"));
}

test "a file one directory holds beats a page another answers misses with" {
    // Two directories, the first of them a single-page app mounted at `/`.
    // Asking set by set would let its fallback answer for `/assets/app.css`
    // before the directory that actually holds that file was reached.
    var pages = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>spa</h1>" },
    });
    defer pages.deinit(testing.allocator);
    var assets = try TmpFiles.init(testing.allocator, &.{
        .{ "app.css", "body{}" },
    });
    defer assets.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.staticWith("/", pages.path, .{ .spa_fallback = "index.html" });
    try app.static("/assets", assets.path);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const css = h.send(&app, "GET /assets/app.css HTTP/1.1\r\nHost: t\r\nAccept: */*\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, css.response, "body{}"));
}

/// Where a program using `cors.reading` keeps its list: somewhere that
/// outlives the App, which for a test is the file itself.
var test_origins: cors.Origins = .empty;

test "a CORS origin can arrive at run time instead of being compiled in" {
    // The deployment fact this is for: the same binary in staging and in
    // production, with the front end at a different address in each
    // (ADR 088).
    var buf: [4][]const u8 = undefined;
    try test_origins.setSplit(&buf, "https://app.example.com, https://staging.example.com");

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.reading(&test_origins, .{ .credentials = true }));
    try app.get("/thing", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // The origin that matched is the one that goes back, and only it.
    const staging = h.send(
        &app,
        "GET /thing HTTP/1.1\r\nHost: t\r\nOrigin: https://staging.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(
        u8,
        staging.response,
        "Access-Control-Allow-Origin: https://staging.example.com\r\n",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, staging.response, "Access-Control-Allow-Credentials: true") != null);

    // Somebody else gets an ordinary response with no such header, and the
    // browser is what refuses it — the same answer `cors.with` gives.
    const other = h.send(
        &app,
        "GET /thing HTTP/1.1\r\nHost: t\r\nOrigin: https://evil.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, other.response, "Access-Control-Allow-Origin") == null);
    // …and it still says the response varies by origin, so a shared cache
    // cannot hand this one to somebody who was allowed (ADR 029).
    try testing.expect(std.mem.indexOf(u8, other.response, "Vary: Origin") != null);

    // A preflight is answered here and never reaches the route.
    const preflight = h.send(
        &app,
        "OPTIONS /thing HTTP/1.1\r\nHost: t\r\nOrigin: https://app.example.com\r\n" ++
            "Access-Control-Request-Method: POST\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, preflight.response, "HTTP/1.1 204"));
    try testing.expect(std.mem.indexOf(
        u8,
        preflight.response,
        "Access-Control-Allow-Origin: https://app.example.com\r\n",
    ) != null);
}

test "two layers each naming a Vary axis both survive onto the response" {
    // A gzipped file behind a CORS with a named origin: the middleware says
    // the answer depends on the Origin, the file says it depends on
    // Accept-Encoding, and both are true of the same response (ADR 029).
    // `Vary` used to replace, so whichever ran second was the only one left —
    // and the handler always runs after the middleware, so it was always
    // `Vary: Origin` that went.
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "app.css", repeat("body { color: rebeccapurple; }\n", 64) },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://example.dev"} }));
    try app.static("/assets", files.path);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const asked = h.send(
        &app,
        "GET /assets/app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, asked.response, "Content-Encoding: gzip\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, asked.response, "Vary: Origin\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, asked.response, "Vary: Accept-Encoding\r\n") != null);
}

test "a gzipped file behind a named-origin CORS still allocates nothing" {
    // The path the second `Vary` was added to, put against ADR 017's hard
    // invariant rather than reasoned about. Seven response headers now — CORS
    // two, the file five — and `inline_headers` is six, so this is the test
    // that says whether the extra one spills to the arena.
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "app.css", repeat("body { color: rebeccapurple; }\n", 64) },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://example.dev"} }));
    try app.static("/assets", files.path);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const request = "GET /assets/app.css HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Accept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Zero, not one: a file is served from memory and its headers all belong
    // to something that outlives the request, so there is nothing to copy.
    // The seventh header would have spilled — the exact-duplicate check in
    // `putHeader` is not what saves it, since these seven are all different;
    // `inline_headers` moving from six to seven is (ADR 029).
    try testing.expectEqual(@as(usize, 0), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

/// Assembles a response larger than the default `arena_keep`, which is the
/// only thing the two tests below need of it.
fn sixtyFourKilobytes(c: *Ctx) anyerror!void {
    const bytes = try c.arena().alloc(u8, 64 * 1024);
    @memset(bytes, 'x');
    return c.send(200, "application/octet-stream", bytes);
}

/// What the two tests below share: run `count` requests down one connection,
/// resetting the arena between them the way the connection loop does, and
/// report how many times the arena had to go to the allocator underneath it.
///
/// The counting allocator wraps the **gpa**, not the arena, because the
/// question is what the arena asks the operating system for. Wrapping the
/// arena would count what a request asks the arena for, which is the other
/// budget and is already held elsewhere in this file.
fn arenaAllocationsAcross(keep: usize, count: usize) !usize {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/big", sixtyFourKilobytes);
    try app.resolveChains();

    var counting = budget.Counting{ .child = testing.allocator };
    var arena = std.heap.ArenaAllocator.init(counting.allocator());
    defer arena.deinit();

    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [96 * 1024]u8 = undefined;
    const request = "GET /big HTTP/1.1\r\nHost: e.dev\r\nConnection: keep-alive\r\n\r\n";

    // The first request is what warms the arena; the count that matters is
    // what the ones after it cost.
    var in = std.Io.Reader.fixed(request);
    var out = std.Io.Writer.fixed(&buf);
    _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});
    lifetime.end();
    _ = arena.reset(.{ .retain_with_limit = keep });

    counting.reset();
    for (0..count) |_| {
        var in_n = std.Io.Reader.fixed(request);
        var out_n = std.Io.Writer.fixed(&buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in_n, &out_n, .off, .off, .{});
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = keep });
    }
    return counting.allocs;
}

test "a response bigger than arena_keep makes the connection take fresh pages every request" {
    // The finding behind the option (ADR 075). At the default the 64 KiB
    // body does not fit in what is retained, so the arena gives the block
    // back after every request and asks for it again on the next one. On a
    // megabyte that showed up as 257 minor faults a request.
    const allocs = try arenaAllocationsAcross(app_mod.default_arena_keep, 8);
    try testing.expect(allocs >= 8);
}

test "an arena_keep past the response leaves the connection allocating nothing" {
    // The same eight requests with the option set past the body: the block is
    // retained, so the arena never goes back to the allocator. This is the
    // whole of what `listen(.{ .arena_keep = … })` buys, and it is bought with
    // memory held per connection rather than per thread.
    const allocs = try arenaAllocationsAcross(128 * 1024, 8);
    try testing.expectEqual(@as(usize, 0), allocs);
}

fn twiceTheSameAxis(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Vary", "Origin");
    try c.setStaticHeader("Vary", "Accept-Language");
    // The same axis again, from a second layer that also depends on it. One
    // fact, said twice — not a third `Vary` line.
    try c.setStaticHeader("Vary", "Origin");
    try c.sendText(200, "ok");
}

test "a repeated header naming what is already there is not said twice" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/v", twiceTheSameAxis);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /v HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result.response, "Vary: "));
    try testing.expect(std.mem.indexOf(u8, result.response, "Vary: Origin\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Vary: Accept-Language\r\n") != null);
}

test "static files: HEAD gives the head, POST is not answered with the file" {
    var files = try TmpFiles.init(testing.allocator, &.{.{ "logo.svg", "<svg/>" }});
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const headed = h.send(&app, "HEAD /logo.svg HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, headed.response, "Content-Length: 6\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, headed.response, "\r\n\r\n"));

    const posted = h.send(&app, "POST /logo.svg HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, posted.response, "HTTP/1.1 404"));
}

// A number that is the same on every machine, unlike requests per second
// on a shared VM (docs/todo.md). It will not tell you how fast the
// server is, but it does notice the day somebody puts an allocation back
// onto the path everything goes down.
test "the request path stays inside its allocation budget" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    // The shape of the primary metric: a routed GET with a path param
    // answering JSON, on a keep-alive connection, with CORS installed.
    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    // Warm the arena first: growing it is a cost of the connection's first
    // request, not of the path being measured.
    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One, and it is the JSON body. Raising this number needs a reason;
    // lowering it is welcome.
    //
    // It was three. The two that went:
    //
    //   - **The copy of the request head.** A request with no body does not
    //     need it: nothing is going to read from the connection again, so the
    //     head can stay in the read buffer where the parser found it (see
    //     `handleRequest`, and `Ctx.aboutToRead` for what stops that from
    //     becoming a dangling `Str`). A POST still pays it, which is what the
    //     next test checks — so the saving cannot quietly become a bug.
    //   - **The list of response headers CORS adds.** The first six now sit
    //     in the `Ctx` itself; the arena only hears about a seventh.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "a message read and answered as protobuf allocates no more than the same message as JSON" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sum", sumOf);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const count = struct {
        fn of(a: *App, c: *budget.Counting, ar: *std.heap.ArenaAllocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8, request: []const u8) usize {
            for (0..4) |round| {
                if (round == 3) c.reset();
                var in = std.Io.Reader.fixed(request);
                var out = std.Io.Writer.fixed(b);
                _ = a.handleRequest(c.allocator(), l, f, &in, &out, .off, .off, .{});
                l.end();
                _ = ar.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
            }
            return c.allocs;
        }
    }.of;

    const json = count(&app, &counting, &arena, &lifetime, &in_flight, &buf, "POST /sum HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"a\":1,\"b\":2}");
    const proto = count(&app, &counting, &arena, &lifetime, &in_flight, &buf, "POST /sum HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/proto\r\nContent-Length: 4\r\n\r\n\x08\x01\x10\x02");
    // Protobuf is three: the head copied for a request with a body, the
    // body, and the answer, sized and written once. A message with no
    // repeated field decodes in place, where the JSON reader allocates once
    // more. Raising either needs a reason (ADR 256).
    try testing.expectEqual(@as(usize, 4), json);
    try testing.expectEqual(@as(usize, 3), proto);
}

test "a traced request stays inside the same allocation budget" {
    // The budget test's request with `app.trace` on and a `traceparent`
    // to join: the span is a copy into a ring sized when the chains were
    // resolved, so the count does not move (ADR 247).
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.trace(.{ .service = "orders", .spans_per_thread = 8 });
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n" ++
        "Accept: */*\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);

    // And every one of the four was recorded.
    var out: [8]trace_mod.Record = undefined;
    try testing.expectEqual(@as(usize, 4), app.tracer.?.drain(&out));
}

fn tracedChild(c: *Ctx) anyerror!void {
    var span = c.span("load user");
    defer span.end();
    try c.sendText(200, "ok");
}

test "a traced request is a server span under its caller's, named for its route, with its own spans under it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", tracedChild);
    try app.trace(.{ .service = "orders", .spans_per_thread = 8 });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(
        &app,
        "GET /users/7 HTTP/1.1\r\nHost: x\r\n" ++
            "traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));

    var out: [8]trace_mod.Record = undefined;
    try testing.expectEqual(@as(usize, 2), app.tracer.?.drain(&out));
    // The handler's span ends first, so it is first out of the ring.
    const child = out[0];
    const server = out[1];
    const caller = trace_mod.Context.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01").?;

    try testing.expectEqual(trace_mod.Kind.server, server.kind);
    try testing.expectEqualStrings("/users/:id", server.name);
    try testing.expectEqualStrings("GET", server.method);
    try testing.expectEqualStrings("/users/7", server.textOf());
    try testing.expectEqual(@as(u16, 200), server.status);
    try testing.expectEqualSlices(u8, &caller.trace_id, &server.trace_id);
    try testing.expectEqualSlices(u8, &caller.span_id, &server.parent);

    try testing.expectEqual(trace_mod.Kind.internal, child.kind);
    try testing.expectEqualStrings("load user", child.name);
    try testing.expectEqualSlices(u8, &caller.trace_id, &child.trace_id);
    try testing.expectEqualSlices(u8, &server.span_id, &child.parent);
}

test "a request no route matched is a span named for its method, and a 5xx is a failed one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/boom", testExplode);
    try app.trace(.{ .service = "orders", .spans_per_thread = 8 });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    _ = h.send(&app, "GET /nowhere HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = h.send(&app, "GET /boom HTTP/1.1\r\nHost: x\r\n\r\n");

    var out: [8]trace_mod.Record = undefined;
    try testing.expectEqual(@as(usize, 2), app.tracer.?.drain(&out));
    try testing.expectEqualStrings("", out[0].name);
    try testing.expectEqual(@as(u16, 404), out[0].status);
    try testing.expectEqualStrings("/boom", out[1].name);
    try testing.expectEqual(@as(u16, 500), out[1].status);
    // A second `app.trace` is refused rather than starting a second exporter.
    try testing.expectError(error.TracingAlreadyEnabled, app.trace(.{ .service = "again" }));
}

test "a request is counted against its route, not the path it arrived on" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testGetUser);
    try app.metrics(.{});

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    _ = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = h.send(&app, "GET /users/9 HTTP/1.1\r\nHost: x\r\n\r\n");
    const page = h.send(&app, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n").response;

    // Two paths, one series — which is the whole reason the counter is the
    // route's index rather than something keyed by the path (ADR 079).
    try testing.expect(std.mem.indexOf(
        u8,
        page,
        "nilo_requests_total{method=\"GET\",route=\"/users/:id\",status=\"2xx\"} 2",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, page, "/users/7") == null);
    try testing.expect(std.mem.indexOf(u8, page, "text/plain; version=0.0.4") != null);
    // The scrape before this one had not happened yet, so the page describes
    // itself as having answered nothing.
    try testing.expect(std.mem.indexOf(u8, page, "route=\"/metrics\"") == null);
}

// ---- refusing a request for load (ADR 159) ----

test "a request past max_in_flight is a 503 at once, and one inside it is answered" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.max_in_flight = 2;
    try app.get("/users/:id", testGetUser);
    try app.metrics(.{});

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Two requests already inside their handlers, which a single-threaded
    // harness cannot arrange by sending them, so the counter is set the way
    // two parked fibers would have left it.
    app.stop.in_flight.store(2, .release);
    const shed = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, shed.response, "HTTP/1.1 503"));
    try testing.expect(std.mem.indexOf(u8, shed.response, "Retry-After: 1") != null);
    try testing.expect(std.mem.indexOf(u8, shed.response, "Connection: close") != null);
    try testing.expect(std.mem.indexOf(u8, shed.response, "{\"error\":\"this server is answering as many requests as it was told to") != null);
    try testing.expect(!shed.keep_alive);
    // The counter is left where it was found: the shed request took a place
    // and gave it back.
    try testing.expectEqual(@as(u32, 2), app.stop.in_flight.load(.acquire));

    // One finishes, and the next request is inside the limit.
    app.stop.in_flight.store(1, .release);
    const served = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, served.response, "HTTP/1.1 200"));
    app.stop.in_flight.store(0, .release);

    // Counted under its own name rather than the route it never reached.
    const page = h.send(&app, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n").response;
    try testing.expect(std.mem.indexOf(u8, page, "nilo_requests_total{method=\"\",route=\"<shed>\",status=\"5xx\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, page, "route=\"/users/:id\",status=\"5xx\"") == null);
}

test "with no max_in_flight nothing is shed, whatever the counter says" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testGetUser);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    app.stop.in_flight.store(10_000, .release);
    defer app.stop.in_flight.store(0, .release);
    const served = h.send(&app, "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, served.response, "HTTP/1.1 200"));
}

test "a path that is no route and a method that is not allowed are counted apart" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", testGetUser);
    try app.metrics(.{});

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    _ = h.send(&app, "GET /nothing/here HTTP/1.1\r\nHost: x\r\n\r\n");
    _ = h.send(&app, "DELETE /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
    const page = h.send(&app, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n").response;

    try testing.expect(std.mem.indexOf(
        u8,
        page,
        "nilo_requests_total{method=\"\",route=\"<unmatched>\",status=\"4xx\"} 1",
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        page,
        "nilo_requests_total{method=\"\",route=\"<method not allowed>\",status=\"4xx\"} 1",
    ) != null);
    // And the exact codes are there, which is the question the class cannot
    // answer: a 404 and a 405 are both 4xx.
    try testing.expect(std.mem.indexOf(u8, page, "nilo_responses_total{code=\"404\"} 1") != null);
    try testing.expect(std.mem.indexOf(u8, page, "nilo_responses_total{code=\"405\"} 1") != null);
}

test "counting a request adds nothing to the allocation budget" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.metrics(.{});
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // The same one as with metrics off, and it is still the JSON body. This
    // is the claim ADR 079 is built on: the table is sized once when the
    // routes are resolved, so a counted request touches memory that already
    // exists (ADR 017).
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "an allowance adds nothing to the allocation budget" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.use(allowance.with(.{ .per_window = 1000, .window_s = 60, .name = "budget" }));
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Still the JSON body and nothing else, which is the whole reason the
    // table is sized while compiling rather than kept in a map (ADR 092).
    // The address is not copied, not hashed into anything that allocates, and
    // the slot it lands in existed before `main` ran.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "compression switched on adds nothing to a request under its threshold" {
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.compress(.{});
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    // The primary metric's shape, with a client that would take gzip. The
    // answer is a few dozen bytes, which is under the threshold, so what
    // it costs has to be exactly what it cost before compression existed.
    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Still the one, and it is still the JSON body: the compressors were
    // taken when the chains were resolved, and a request that is not
    // compressed never reaches for them (ADR 211).
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "a compressed answer costs one allocation, and it is the compressed body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/report", sendLongText);
    try app.use(cors.permissive);
    try app.compress(.{});
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const request = "GET /report HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) []const u8 {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
            return out.buffered();
        }
    }.once;

    for (0..3) |_| {
        _ = send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    const response = send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
    try testing.expect(std.mem.indexOf(u8, response, "Content-Encoding: gzip\r\n") != null);

    // The body here is a literal, so the handler itself allocates nothing;
    // the one allocation is the compressed copy, sized to fit on the first
    // try so that it is never grown. A JSON route pays its usual one for
    // the body on top of this, which is the number `app.compress`'s doc
    // states (ADR 211).
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "a number the application owns goes out on the page" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    var orders_placed: metrics_mod.Counter = .init(0);
    // Registered before `metrics()`, to show the order does not matter.
    try app.expose("orders_placed", .counter, &orders_placed);
    try app.metrics(.{});

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    _ = orders_placed.fetchAdd(3, .monotonic);
    const page = h.send(&app, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n").response;

    try testing.expect(std.mem.indexOf(u8, page, "# TYPE orders_placed counter") != null);
    try testing.expect(std.mem.indexOf(u8, page, "orders_placed 3") != null);
    try testing.expectError(error.MetricAlreadyExposed, app.expose("orders_placed", .counter, &orders_placed));
}

test "a number exposed after the routes were resolved is still on the page" {
    // The table holds a slice of the App's list, and appending to a list
    // moves it. Nothing in an ordinary `main` reaches this — `listen()`
    // resolves the routes itself — but `start()` before `listen()` does, and
    // so does any test, and what it would read is freed memory.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.metrics(.{});

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    var first: metrics_mod.Counter = .init(1);
    var second: metrics_mod.Counter = .init(2);
    try app.expose("first", .counter, &first);
    try app.expose("second", .gauge, &second);

    const page = h.send(&app, "GET /metrics HTTP/1.1\r\nHost: x\r\n\r\n").response;
    try testing.expect(std.mem.indexOf(u8, page, "first 1") != null);
    try testing.expect(std.mem.indexOf(u8, page, "# TYPE second gauge") != null);
    try testing.expect(std.mem.indexOf(u8, page, "second 2") != null);
}

test "metrics cannot be switched on twice" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.metrics(.{});
    try testing.expectError(error.MetricsAlreadyEnabled, app.metrics(.{ .path = "/other" }));
}

/// One more header than the Ctx holds inline, so the spill to the arena is
/// actually reached. Counted off `inline_headers` rather than written out:
/// this test was named for a *fifth* header and spelled six of them, from back
/// when four were held inline — so by the time it was read again it had been
/// asserting nothing about spilling for two changes to that constant
/// (ADR 032, and ADR 029 for the change that made it worth noticing).
const spilling_headers = ctx_mod.inline_headers + 1;

test "one header more than the Ctx holds inline spills, and all of them go out in order" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/many", struct {
        fn run(c: *Ctx) anyerror!void {
            inline for (0..spilling_headers) |i| {
                const name = std.fmt.comptimePrint("{d}", .{i});
                try c.setStaticHeader("X-N" ++ name, name);
            }
            // And one that repeats an entry already held, which must replace
            // it rather than join it — the rule every header but the two in
            // `http1.repeats` follows.
            try c.setStaticHeader("x-n1", "again");
            try c.sendText(200, "ok");
        }
    }.run);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    const sent = h.send(&app, "GET /many HTTP/1.1\r\nHost: t\r\n\r\n");

    // Every one of them survived the move into the spill list, in one piece.
    inline for (0..spilling_headers) |i| {
        const name = std.fmt.comptimePrint("{d}", .{i});
        if (i != 1) {
            try testing.expect(std.mem.indexOf(u8, sent.response, "X-N" ++ name ++ ": " ++ name) != null);
        }
    }
    // Replaced, not duplicated.
    try testing.expect(std.mem.indexOf(u8, sent.response, "x-n1: again") != null);
    try testing.expect(std.mem.indexOf(u8, sent.response, "X-N1: 1") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, sent.response, "again"));
}

/// A connection that hands its bytes over a few at a time, into a buffer of
/// its own — which is what a socket does and what `Reader.fixed` never does,
/// because there the input *is* the buffer and no read ever refills it.
///
/// Two things can only be tested through something like this: that a head
/// arriving in pieces is still found (`readHead` resumes its scan rather than
/// starting again), and that a head left in the read buffer is copied out
/// before a body read overwrites it.
const Trickle = struct {
    rest: []const u8,
    per_read: usize,
    reader: std.Io.Reader,

    fn init(source: []const u8, per_read: usize, buffer: []u8) Trickle {
        return .{
            .rest = source,
            .per_read = per_read,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Trickle = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.EndOfStream;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(@min(dest.len, self.per_read), self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        w.advance(n);
        return n;
    }
};

fn echoHeadAfterBody(c: *Ctx) anyerror!void {
    const body_text = (try c.body()).view();
    // Read out of the head *after* the body: on a head still sitting in the
    // read buffer, these are whatever the refill put there.
    const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
    try c.sendText(200, try std.fmt.allocPrint(
        c._arena,
        "{s}|{s}|{f}",
        .{ host.view(), body_text, c.path() },
    ));
}

test "a request with a body copies the head, so its Strs survive reading it" {
    // The other half of the budget above: the saving is only allowed to exist
    // because a request that *will* read still pays for the copy. Driven
    // through a connection that trickles, so the body genuinely cannot arrive
    // without refilling the buffer the head is in.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoHeadAfterBody);
    try app.resolveChains();

    const wire = "POST /echo HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Content-Length: 11\r\n\r\nhello world";

    // Several read sizes, so the head/body split lands in a different place
    // each time — including one byte at a time, which is the worst case for
    // both the scan and the copy.
    for ([_]usize{ 1, 3, 7, 16, 64 }) |per_read| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};
        var in_flight = fail.InFlight{};
        var out_buf: [4096]u8 = undefined;
        var read_buf: [128]u8 = undefined;

        var conn = Trickle.init(wire, per_read, &read_buf);
        var out = std.Io.Writer.fixed(&out_buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &conn.reader, &out, .off, .off, .{});

        try testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP/1.1 200"));
        try testing.expect(std.mem.endsWith(u8, out.buffered(), "example.dev|hello world|/echo"));
    }
}

test "a head arriving a byte at a time is still parsed, and its Strs are sound" {
    // The no-body side, on a trickling connection. Nothing reads again, so the
    // head stays where it was parsed — and every Str off it has to hold up for
    // the whole request anyway.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/users/:id", struct {
        fn run(c: *Ctx) anyerror!void {
            const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
            const agent = c.header("User-Agent") orelse return fail.badRequest("no UA", .{});
            const id = c.param("id") orelse return fail.badRequest("no id", .{});
            try c.sendText(200, try std.fmt.allocPrint(
                c._arena,
                "{s}|{s}|{s}|{f}",
                .{ host.view(), agent.view(), id.view(), c.path() },
            ));
        }
    }.run);
    try app.resolveChains();

    const wire = "GET /users/42 HTTP/1.1\r\nHost: example.dev\r\n" ++
        "User-Agent: curl/8.0\r\nAccept: */*\r\n\r\n";

    for ([_]usize{ 1, 2, 5, 31, 32, 33, 200 }) |per_read| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};
        var in_flight = fail.InFlight{};
        var out_buf: [4096]u8 = undefined;
        var read_buf: [256]u8 = undefined;

        var conn = Trickle.init(wire, per_read, &read_buf);
        var out = std.Io.Writer.fixed(&out_buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &conn.reader, &out, .off, .off, .{});

        try testing.expect(std.mem.endsWith(
            u8,
            out.buffered(),
            "example.dev|curl/8.0|42|/users/42",
        ));
    }
}

test "two requests on one trickling connection do not borrow each other's head" {
    // A keep-alive connection reuses the buffer, so the second request's head
    // lands where the first one's was. Both answers have to be about their own
    // request.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/*", struct {
        fn run(c: *Ctx) anyerror!void {
            const host = c.header("Host") orelse return fail.badRequest("no Host", .{});
            try c.sendText(200, try std.fmt.allocPrint(
                c._arena,
                "{f}@{s}",
                .{ c.path(), host.view() },
            ));
        }
    }.run);
    try app.resolveChains();

    const wire = "GET /first HTTP/1.1\r\nHost: one.example\r\n\r\n" ++
        "GET /second HTTP/1.1\r\nHost: two.example\r\n\r\n";

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var read_buf: [128]u8 = undefined;
    var conn = Trickle.init(wire, 4, &read_buf);

    for ([_][]const u8{ "/first@one.example", "/second@two.example" }) |want| {
        var out_buf: [4096]u8 = undefined;
        var out = std.Io.Writer.fixed(&out_buf);
        try testing.expect(app.handleRequest(
            arena.allocator(),
            &lifetime,
            &in_flight,
            &conn.reader,
            &out,
            .off,
            .off,
            .{},
        ));
        try testing.expect(std.mem.endsWith(u8, out.buffered(), want));
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
}

// ---- deadlines (ADR 022) ----
//
// What is tested here is the policy: which limit the request path asks for,
// when, how many times, and what it sends when one runs out. What zio does
// once it has a limit is zio's, and it is checked by hand against a real
// socket rather than pretended at here — the numbers from that run are in
// the ADR. A fake makes the difference between an absolute header deadline
// and a per-read one visible, which no amount of waiting on a real socket
// would make *quick* to check.

/// A `Deadlines` that writes down what it was asked to do instead of doing
/// it.
const Recorded = struct {
    const Call = struct { side: bulkhead.Side, limit: bulkhead.Limit };

    calls: [16]Call = undefined,
    n: usize = 0,
    /// What `timedOut()` answers — the fake stands in for the socket here
    /// too, since a fake reader cannot really run out of time.
    timed_out: bool = false,

    /// A `Deadlines` carrying real numbers and this recorder's behaviour.
    fn with(self: *Recorded, limits: bulkhead.Deadlines) bulkhead.Deadlines {
        var d = limits;
        d.target = self;
        d.vtable = &vtable;
        return d;
    }

    const vtable: bulkhead.Deadlines.VTable = .{ .limit = record, .timedOut = wasTimeout };

    fn record(target: ?*anyopaque, side: bulkhead.Side, l: bulkhead.Limit) void {
        const self: *Recorded = @ptrCast(@alignCast(target.?));
        if (self.n == self.calls.len) return;
        self.calls[self.n] = .{ .side = side, .limit = l };
        self.n += 1;
    }

    fn wasTimeout(target: ?*anyopaque) bool {
        const self: *const Recorded = @ptrCast(@alignCast(target.?));
        return self.timed_out;
    }

    fn lastRead(self: *const Recorded) ?bulkhead.Limit {
        var i = self.n;
        while (i > 0) {
            i -= 1;
            if (self.calls[i].side == .read) return self.calls[i].limit;
        }
        return null;
    }

    fn countReads(self: *const Recorded, tag: @typeInfo(bulkhead.Limit).@"union".tag_type.?) usize {
        var found: usize = 0;
        for (self.calls[0..self.n]) |call| {
            if (call.side == .read and call.limit == tag) found += 1;
        }
        return found;
    }
};

/// The four numbers a server runs with, small and distinct so a test can
/// tell from the value alone which limit was asked for.
const test_limits: bulkhead.Deadlines = .{
    .header_ms = 700,
    .idle_ms = 900,
    .body_ms = 1100,
    .body_min_rate = 1024,
    .body_grace_ms = 500,
    .write_ms = 1300,
};

/// `Trickle`, except that when it runs out it fails the way a socket that
/// ran out of time does — `error.ReadFailed`, with the reason kept
/// elsewhere — rather than reporting a clean end of stream.
const Stalling = struct {
    rest: []const u8,
    per_read: usize,
    reader: std.Io.Reader,

    fn init(source: []const u8, per_read: usize, buffer: []u8) Stalling {
        return .{
            .rest = source,
            .per_read = per_read,
            .reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = buffer,
                .end = 0,
                .seek = 0,
            },
        };
    }

    fn stream(
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        limit: std.Io.Limit,
    ) std.Io.Reader.StreamError!usize {
        const self: *Stalling = @alignCast(@fieldParentPtr("reader", r));
        if (self.rest.len == 0) return error.ReadFailed;
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = @min(@min(dest.len, self.per_read), self.rest.len);
        @memcpy(dest[0..n], self.rest[0..n]);
        self.rest = self.rest[n..];
        w.advance(n);
        return n;
    }
};

const Deadline = struct {
    app: App,
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    clock: Recorded = .{},
    out_buf: [4096]u8 = undefined,
    read_buf: [512]u8 = undefined,

    fn init() Deadline {
        return .{
            .app = App.init(testing.allocator),
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn deinit(self: *Deadline) void {
        self.app.deinit();
        self.arena.deinit();
    }

    /// One request over a connection that hands `wire` over `per_read` bytes
    /// at a time and then stops dead.
    fn stall(self: *Deadline, wire: []const u8, per_read: usize) struct {
        response: []const u8,
        keep_alive: bool,
    } {
        var conn = Stalling.init(wire, per_read, &self.read_buf);
        var out = std.Io.Writer.fixed(&self.out_buf);
        const keep_alive = self.app.handleRequest(
            self.arena.allocator(),
            &self.lifetime,
            &self.in_flight,
            &conn.reader,
            &out,
            self.clock.with(test_limits),
            .off,
            .{},
        );
        return .{ .response = out.buffered(), .keep_alive = keep_alive };
    }
};

test "a head that starts arriving and then stops is answered with 408" {
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "should never run");
        }
    }.run);
    try d.app.resolveChains();
    d.clock.timed_out = true;

    // A head with no blank line: the client said something and then went
    // quiet, which is the slowloris shape.
    const sent = d.stall("GET / HTTP/1.1\r\nHost: example.dev\r\n", 8);

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 408"));
    try testing.expect(!sent.keep_alive);
}

test "a connection that goes quiet without asking for anything is closed without a word" {
    // The other half of the 408 decision. Nothing was asked, so there is
    // nothing to answer, and a status here would be a proxy's problem
    // rather than a client's answer.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.resolveChains();
    d.clock.timed_out = true;

    const sent = d.stall("", 8);

    try testing.expectEqual(@as(usize, 0), sent.response.len);
    try testing.expect(!sent.keep_alive);
}

test "a connection that breaks mid-head is closed without a 408 as well" {
    // Same failure, different reason: the client is gone, not slow. A 408
    // would be written into a socket nobody is holding.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.resolveChains();
    d.clock.timed_out = false;

    const sent = d.stall("GET / HTTP/1.1\r\nHost: example.dev\r\n", 8);

    try testing.expectEqual(@as(usize, 0), sent.response.len);
}

test "the header deadline is set once, however many reads the head takes" {
    // The whole reason the header limit is an absolute deadline rather than a
    // per-read one. A client sending a byte at a time drives dozens of reads
    // through here; if any of them re-armed the limit, it would move the
    // finish line forward every time and never be reached — which is the
    // attack, not the defence.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/x", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "ok");
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall("GET /x HTTP/1.1\r\nHost: example.dev\r\nAccept: */*\r\n\r\n", 1);
    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 200"));

    // Once for the whole head, and as a deadline rather than a duration.
    try testing.expectEqual(@as(usize, 1), d.clock.countReads(.by_ns));
    try testing.expectEqual(@as(usize, 0), d.clock.countReads(.within_ms));
}

test "a head that arrives whole still starts the header clock" {
    // The ordinary case: one read brings everything. `readHead` finds the
    // terminator on the first look and never has to wait again, so nothing is
    // armed at all — the read that mattered was the idle one, and the
    // connection loop armed that before calling in.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/x", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "ok");
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall("GET /x HTTP/1.1\r\nHost: example.dev\r\n\r\n", 1024);

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 200"));
    try testing.expectEqual(@as(usize, 0), d.clock.countReads(.by_ns));
}

test "reading a body puts the body's limit on it, not the head's" {
    // The head's deadline has passed by the time a handler asks for the body,
    // so a body read that inherited it would fail at once. The body gets one
    // of its own, worked out from the length the client announced.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall(
        "POST /echo HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 5\r\n\r\nhello",
        3,
    );

    try testing.expect(std.mem.endsWith(u8, sent.response, "hello"));

    // A deadline rather than a per-read duration, and in the future: five
    // bytes at the test's rate is 500ms of grace and a rounding error
    // (ADR 022).
    const at = d.clock.lastRead().?.by_ns;
    try testing.expect(at > bulkhead.monotonicNanos());
}

test "a client that stops halfway through a body is answered 408, not 500" {
    // The client never finished sending, so the request is not one the server
    // failed at — it is one that never arrived. A 500 would send whoever
    // reads the log looking for a bug in a handler that did nothing wrong.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try d.app.resolveChains();

    // Announces five bytes, sends two, and the socket is the one that gives
    // up — which is what the fake clock saying `timed_out` stands for.
    d.clock.timed_out = true;
    const sent = d.stall(
        "POST /echo HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 5\r\n\r\nhe",
        64,
    );

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 408"));
}

test "a body read that failed because the connection broke is not a 408" {
    // The other half of that decision: without a timeout underneath it, a
    // read that failed is a read that failed, and calling it a 408 would tell
    // a client that retrying is worth its while when nothing was wrong with
    // the timing.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try d.app.resolveChains();

    const sent = d.stall(
        "POST /echo HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 5\r\n\r\nhe",
        64,
    );

    try testing.expect(!std.mem.startsWith(u8, sent.response, "HTTP/1.1 408"));
}

test "a body the handler never read is thrown away against a rate floor, not read by read" {
    // Per read, a POST to a route that ignores its body, dribbled at a byte
    // every 29 seconds, held its fiber with no end. The rest of the body gets
    // `body()`'s deadline instead: a point in time, sized from the bytes.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.post("/ignore", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, "not reading that");
        }
    }.run);
    try d.app.resolveChains();

    const sized = d.stall("POST /ignore HTTP/1.1\r\nHost: example.dev\r\nContent-Length: 5\r\n\r\nhello", 1024);
    try testing.expect(sized.keep_alive);
    try testing.expect(d.clock.lastRead().? == .by_ns);

    d.clock = .{};
    const chunked = d.stall("POST /ignore HTTP/1.1\r\nHost: example.dev\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n0\r\n\r\n", 1024);
    try testing.expect(chunked.keep_alive);
    try testing.expect(d.clock.lastRead().? == .by_ns);
}

test "a WebSocket is allowed to sit quiet between frames, and not inside one" {
    // A chat tab with nobody typing is working correctly, and the limit that
    // protects the HTTP side would close it. Silence between frames is the
    // Socket's park, which reads nothing, so the read limit only ever lands
    // on a frame already begun: a client that stopped half way through one
    // was never pinged and held its fiber for ever. Each such read gets what
    // a quiet client gets between frames, the ping's stretch and one more.
    // Writes keep theirs.
    var d = Deadline.init();
    defer d.deinit();
    try d.app.get("/ws", struct {
        fn run(c: *Ctx) anyerror!void {
            return c.upgrade(loop, {});
        }
        fn loop(_: *websocket.Socket) anyerror!void {}
    }.run);
    try d.app.resolveChains();

    const sent = d.stall(
        "GET /ws HTTP/1.1\r\nHost: example.dev\r\nUpgrade: websocket\r\n" ++
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
        1024,
    );

    try testing.expect(std.mem.startsWith(u8, sent.response, "HTTP/1.1 101"));
    const idle_ms = (websocket.Options{}).idle_ms;
    try testing.expectEqual(bulkhead.Limit{ .within_ms = 2 * idle_ms }, d.clock.lastRead().?);
}

// ---- the generated API description (ADR 016) ----

const DocUser = struct { id: u32, name: Str, admin: bool = false };
const DocNewUser = struct { name: Str, age: ?u32 = null, plan: enum { free, paid } };
const DocSearch = struct {
    q: Str,
    page: u32 = 1,
    sort: enum { newest, oldest } = .newest,
    tag: ?Str = null,
};

fn docGetUser(_: *Db, id: u32) !DocUser {
    return .{ .id = id, .name = undefined };
}
fn docListUsers(_: *Db, _: typed.Query(DocSearch)) ![]const DocUser {
    return &.{};
}
fn docCreateUser(_: *Db, _: DocNewUser) !typed.Response(DocUser) {
    return undefined;
}
fn docDeleteUser(_: *Db, _: u32) !void {}
fn docServeFile(rest: Str) Str {
    return rest;
}

/// Build an app with one of everything and hand back its document.
fn docsFor(app: *App) ![]const u8 {
    try app.resolveChains();
    const set = app.docs_set.?;
    for (set.files) |f| {
        // Held, necessarily: the document was generated into memory and
        // there is no directory for it to have spilled to.
        if (std.mem.eql(u8, f.url, "/openapi.json")) return f.contents.held.bytes;
    }
    return error.NoDocument;
}

test "the document describes what the signatures say" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{ .title = "Orders", .version = "2.1.0" });

    const api = app.group("/api/v1");
    try api.get("/users/:id", docGetUser);
    try api.delete("/users/:id", docDeleteUser);
    try api.get("/users", docListUsers);
    try api.post("/users", docCreateUser);
    try app.get("/files/*", docServeFile);

    const json = try docsFor(&app);

    try testing.expect(std.mem.startsWith(u8, json, "{\"openapi\":\"3.1.0\","));
    try testing.expect(std.mem.indexOf(u8, json, "\"title\":\"Orders\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":\"2.1.0\"") != null);

    // A `:id` becomes `{id}`, and the two verbs on it share one path entry.
    const users_id = std.mem.indexOf(u8, json, "\"/api/v1/users/{id}\":{").?;
    const next_path = std.mem.indexOf(u8, json[users_id..], "\"/api/v1/users\"").?;
    const entry = json[users_id..][0..next_path];
    try testing.expect(std.mem.indexOf(u8, entry, "\"get\":") != null);
    try testing.expect(std.mem.indexOf(u8, entry, "\"delete\":") != null);

    // The path param's type came from the handler's argument, not a guess.
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"name\":\"id\",\"in\":\"path\",\"required\":true,\"schema\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}",
    ) != null);

    // A catch-all has no OpenAPI spelling, so it is `{path}` in both places.
    try testing.expect(std.mem.indexOf(u8, json, "\"/files/{path}\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"path\",\"in\":\"path\"") != null);

    // The query struct, with a default meaning "not required".
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"q\",\"in\":\"query\",\"required\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"page\",\"in\":\"query\",\"required\":false") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"name\":\"sort\",\"in\":\"query\",\"required\":false,\"schema\":" ++
            "{\"type\":\"string\",\"enum\":[\"newest\",\"oldest\"]}",
    ) != null);

    // The body, from the struct argument.
    try testing.expect(std.mem.indexOf(u8, json, "\"requestBody\":{\"required\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"plan\":{\"type\":\"string\",\"enum\":[\"free\",\"paid\"]}") != null);

    // A handler returning `Response(T)` chooses its status at runtime, so
    // the document says `default` instead of claiming one.
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"default\":") != null);
    // One returning a plain value always answers 200, so it says so.
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"200\":") != null);

    // A route with something to convert can be refused before the handler
    // runs, and the document admits it.
    try testing.expect(std.mem.indexOf(u8, json, "\"400\":") != null);
}

fn docFindUser(_: *Db, id: u32) !?DocUser {
    _ = id;
    return null;
}
fn docMakeUser(_: *Db, _: DocNewUser) !typed.Status(201, DocUser) {
    return undefined;
}
fn docDropUser(_: *Db, _: u32) !typed.Status(204, void) {
    return .{};
}

test "the document names the statuses and failures the signatures settle" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/users/:id", docFindUser);
    try app.post("/users", docMakeUser);
    try app.delete("/users/:id", docDropUser);

    const json = try docsFor(&app);

    // `Status(code, T)` puts the code in the type, so the document names it
    // instead of falling back to `default` (ADR 023).
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"201\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"responses\":{\"204\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"default\":") == null);

    // A handler returning `?T` promises a 404, and the body it describes is
    // the thing itself — not "the thing or null", which was the old answer
    // and the reason nobody could generate a client from this.
    try testing.expect(std.mem.indexOf(u8, json, "\"404\":") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"200\":{\"description\":\"the response\",\"content\":{\"application/json\":" ++
            "{\"schema\":{\"$ref\":\"#/components/schemas/DocUser\"}}}}",
    ) != null);

    // Every failure the document promises has the one shape all of them
    // take, described once (ADR 024).
    try testing.expect(std.mem.indexOf(u8, json, "\"Failure\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"$ref\":\"#/components/schemas/Failure\"",
    ) != null);
}

test "the document's Failure schema is the shape app.failures named" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});
    try app.failures(ApiError);
    try app.get("/users/:id", docFindUser);

    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"Failure\":{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":65535},\"detail\":{\"type\":\"string\"}}",
    ) != null);
    // Under `Failure` and not under its own name as well: one shape, one entry.
    try testing.expect(std.mem.indexOf(u8, json, "\"ApiError\"") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"$ref\":\"#/components/schemas/Failure\"") != null);
}

test "a field the server always writes is required in an answer, though a request may leave it out" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});
    try app.get("/users/:id", docFindUser);
    try app.post("/users", docMakeUser);

    const json = try docsFor(&app);
    // `admin` has a default and `DocUser` is only ever written, so a client
    // generated from this reads it without a null check. `age` and `plan` of
    // the body are the request's and keep the rule they had.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocUser\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"id\",\"name\",\"admin\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"required\":[\"name\",\"plan\"]") != null);
}

test "a shape used by more than one route is written once and referred to" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/users/:id", docGetUser);
    try app.get("/users", docListUsers);
    try app.post("/users", docCreateUser);

    const json = try docsFor(&app);

    // The shape itself appears once, under the name of the Zig type it came
    // from, and everywhere else is a reference to it.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocUser\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"DocNewUser\":{\"type\":\"object\"") != null);

    var found: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, json, at, "\"$ref\":\"#/components/schemas/DocUser\"")) |i| {
        found += 1;
        at = i + 1;
    }
    // Once for the single user, once inside the list, once for the created
    // one — three references and one copy, where there used to be three
    // copies.
    try testing.expectEqual(@as(usize, 3), found);
    try testing.expectEqual(@as(usize, 1), countOccurrences(json, "\"id\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}"));
}

/// Handlers that write their own answer, and one that merely reads the
/// request before returning a value. The difference is the whole point of
/// the test below: taking a `*Ctx` is not what makes an endpoint
/// undescribable — returning nothing while holding one is.
fn docStreamsIt(c: *Ctx, id: u32) !void {
    var body = try c.stream(202, "text/csv");
    try body.print("id\n{d}\n", .{id});
    try body.finish();
}

fn docReadsHeaderThenAnswers(c: *Ctx) !DocUser {
    return .{ .id = 1, .name = c.header("X-Who") orelse Str.static("nobody") };
}

test "a handler that writes its own answer says so, instead of promising an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});

    try app.get("/report/:id", docStreamsIt);
    try app.get("/me", docReadsHeaderThenAnswers);

    const json = try docsFor(&app);

    // The one that streams answers 202 with a CSV, and its signature says
    // none of that. Claiming "200, empty" — which is what reading the return
    // type alone produces — would be a document that is wrong twice.
    try testing.expect(std.mem.indexOf(u8, json, "may write its own response") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"an empty response\"") == null);

    // ...and holding a `*Ctx` is not itself the disqualification. This one
    // reads a header and still returns its answer, so the answer is known.
    try testing.expect(std.mem.indexOf(
        u8,
        json,
        "\"200\":{\"description\":\"the response\",\"content\":{\"application/json\":" ++
            "{\"schema\":{\"$ref\":\"#/components/schemas/DocUser\"}}}}",
    ) != null);
}

fn DocBox(comptime T: type) type {
    return struct { held: T, at: u32 };
}

fn docBoxedUser(db: *Db) !DocBox(DocUser) {
    _ = db;
    return .{ .held = .{ .id = 1, .name = .static("wati") }, .at = 0 };
}

fn docBoxedText(db: *Db) !DocBox([]const u8) {
    _ = db;
    return .{ .held = "hello", .at = 0 };
}

test "an instantiated generic keeps a name, made out of the one the compiler gives it" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/boxed/user", docBoxedUser);
    try app.get("/boxed/text", docBoxedText);

    const json = try docsFor(&app);

    // `app.DocBox(app.DocUser)` read back into an identifier. Without this a
    // generic envelope — which is how Zig says "the same shape twice", and
    // so the answer to writing every body struct out again with `Str` in it
    // — costs the shape its name in every generated client.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocBox_DocUser\":{\"type\":\"object\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"$ref\":\"#/components/schemas/DocBox_DocUser\"") != null);

    // A slice of bytes is text rather than `const_u8`, because that is what
    // it is on the wire and `DocBox_const_u8` is nobody's idea of a name.
    try testing.expect(std.mem.indexOf(u8, json, "\"DocBox_Text\":{\"type\":\"object\"") != null);
}

const nudged = struct {
    fn Box(comptime T: type) type {
        return struct { held: T };
    }
};

const shoved = struct {
    fn Box(comptime T: type) type {
        return struct { thrown: T };
    }
};

fn docNudgedBox(db: *Db) !nudged.Box(u32) {
    _ = db;
    return .{ .held = 1 };
}

fn docShovedBox(db: *Db) !shoved.Box(u32) {
    _ = db;
    return .{ .thrown = 2 };
}

test "a name two different generics both answer to belongs to neither" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.get("/nudged", docNudgedBox);
    try app.get("/shoved", docShovedBox);

    const json = try docsFor(&app);

    // Both render to `Box_u32` and they are not the same shape. A `$ref`
    // either way round would describe one endpoint as the other, so neither
    // gets the name and both are written out where they appear.
    try testing.expect(std.mem.indexOf(u8, json, "Box_u32") == null);
    try testing.expect(std.mem.indexOf(u8, json, "\"held\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"thrown\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}") != null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| {
        n += 1;
        at = i + 1;
    }
    return n;
}

test "the document is valid JSON, all of it" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{ .title = "A \"quoted\" name", .description = "line one\nline two" });

    try app.get("/users/:id", docGetUser);
    try app.get("/users", docListUsers);
    try app.post("/users", docCreateUser);
    try app.delete("/users/:id", docDeleteUser);
    try app.get("/files/*", docServeFile);
    try app.get("/", plainOk);

    const json = try docsFor(&app);

    // The assertions above check the shape a phrase at a time; this checks
    // that the whole thing parses, which is what a client generator will do
    // to it. Escaping is deliberately given something to escape.
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    try testing.expectEqual(@as(usize, 4), paths.count());
    try testing.expect(paths.contains("/users/{id}"));
    try testing.expect(paths.contains("/files/{path}"));
    try testing.expect(paths.contains("/"));

    const on_users_id = paths.get("/users/{id}").?.object;
    try testing.expectEqual(@as(usize, 2), on_users_id.count());
    try testing.expectEqualStrings(
        "getUsersId",
        on_users_id.get("get").?.object.get("operationId").?.string,
    );

    try testing.expectEqualStrings(
        "A \"quoted\" name",
        parsed.value.object.get("info").?.object.get("title").?.string,
    );
}

test "a route that says its own name gets it as the operationId" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});

    try app.named("showUser").get("/users/:id", docGetUser);
    // The derived name is still what a route that said nothing gets.
    try app.get("/users", docListUsers);
    // And it composes with a group's prefix and with `with`.
    const api = app.group("/api");
    try api.named("createUser").post("/users", docCreateUser);
    // A hyphen, which is how the generator on the other side of a port
    // spelled five of its names; the document carries it as written
    // (ADR 119).
    try api.named("auth-login").post("/auth/login", docCreateUser);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const paths = parsed.value.object.get("paths").?.object;
    try testing.expectEqualStrings(
        "showUser",
        paths.get("/users/{id}").?.object.get("get").?.object.get("operationId").?.string,
    );
    try testing.expectEqualStrings(
        "auth-login",
        paths.get("/api/auth/login").?.object.get("post").?.object.get("operationId").?.string,
    );
    try testing.expectEqualStrings(
        "getUsers",
        paths.get("/users").?.object.get("get").?.object.get("operationId").?.string,
    );
    try testing.expectEqualStrings(
        "createUser",
        paths.get("/api/users").?.object.get("post").?.object.get("operationId").?.string,
    );
}

/// One middleware and one table, which is the shape ADR 042 of the port
/// that asked for this argued for: a check per handler leaves the
/// ninety-first endpoint open with no error and no failing test, and a table
/// consulted from one place does not. Default-deny — a route the table does
/// not name is refused for everybody.
const permission_table = std.StaticStringMap([]const u8).initComptime(.{
    .{ "showUser", "read" },
    .{ "createUser", "write" },
    // A route that said nothing is keyed by the name the document prints.
    .{ "getUsers", "read" },
});

fn tableGuard(c: *Ctx, next: mw.Next) anyerror!void {
    const name = c.routeName() orelse return next.run(c);
    const needed = permission_table.get(name) orelse
        return fail.forbidden("{s} is not in the permission table", .{name});
    try c.setHeader("X-Needed", needed);
    try next.run(c);
}

fn echoRouteName(c: *Ctx) anyerror!void {
    try c.sendText(200, c.routeName() orelse "none");
}

test "a middleware can read the name of the route it is in front of" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(tableGuard);

    try app.named("showUser").get("/users/:id", echoRouteName);
    try app.get("/users", echoRouteName);
    const api = app.group("/api");
    try api.named("createUser").post("/users", echoRouteName);
    // Registered and named, and in the table under nothing: the write the
    // table forgot.
    try api.named("deleteUser").delete("/users/:id", echoRouteName);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    // Given, and derived, both as the document spells them — and the
    // handler sees the same word the middleware did.
    const one = try client.get(&app, "/users/7");
    try testing.expectEqual(@as(u16, 200), one.status);
    try testing.expectEqualStrings("read", one.header("X-Needed").?);
    try testing.expectEqualStrings("showUser", one.body);
    const listed = try client.get(&app, "/users");
    try testing.expectEqualStrings("read", listed.header("X-Needed").?);
    try testing.expectEqualStrings("getUsers", listed.body);
    const created = try client.post(&app, "/api/users", "");
    try testing.expectEqualStrings("write", created.header("X-Needed").?);
    try testing.expectEqualStrings("createUser", created.body);

    // A `HEAD` answered by the `GET` route carries the `GET`'s name, because
    // that is the operation that ran.
    const head = try client.send(&app, "HEAD /users/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("read", head.header("X-Needed").?);

    // Default-deny: a 403 with the name in it, not a handler that ran.
    const deleted = try client.send(&app, "DELETE /api/users/7 HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(@as(u16, 403), deleted.status);
    try testing.expect(std.mem.indexOf(u8, deleted.body, "deleteUser is not in the permission table") != null);

    // Nothing matched: null, and the middleware still runs (ADR 008).
    const missing = try client.get(&app, "/nothing-here");
    try testing.expectEqual(@as(u16, 404), missing.status);
    try testing.expect(missing.header("X-Needed") == null);
    const wrong_verb = try client.post(&app, "/users/7", "");
    try testing.expectEqual(@as(u16, 405), wrong_verb.status);
    try testing.expect(wrong_verb.header("X-Needed") == null);
}

test "twenty named routes on one group is a program, not a branch budget" {
    // Sixteen was the number that stopped compiling, and the message named a
    // line in this file and whichever route the walk happened to be on
    // (ADR 126). Twenty here, so the test fails if the sizing is ever taken
    // back out — and long names, because the cost is per byte.
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);

    const api = app.group("/api");
    inline for (.{
        "listPartnerCapabilities", "addPartnerCapability", "removePartnerCapability",
        "listPartnerContacts",     "addPartnerContact",    "updatePartnerContact",
        "listWorkItemLabels",      "addWorkItemLabel",     "removeWorkItemLabel",
        "listWorkItemPartners",    "addWorkItemPartner",   "tickWorkItemChecklist",
        "listCommitmentFacets",    "identifyCommitment",   "promiseCommitment",
        "startCommitment",         "deliverCommitment",    "breakDownCommitment",
        "changeCommitmentDueDate", "unfundCommitment",
    }, 0..) |name, i| {
        try api.named(name).tryRoute(.GET, std.fmt.comptimePrint("/thing/{d}", .{i}), docListUsers);
    }

    try testing.expect(wiring.nameTaken(&app, "changeCommitmentDueDate") != null);
    try testing.expect(wiring.nameTaken(&app, "listPartnerCapabilities") != null);
}

test "two routes cannot share a name" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);

    try app.named("showUser").tryRoute(.GET, "/users/:id", docGetUser);

    // The check, not the registration that runs it: registering the second
    // one writes a `std.log.err`, which the test runner counts as a failed
    // run whatever `testing.log_level` says. So this pins what the second
    // registration would find, the way `router.zig` pins `conflicting`.
    const taken = wiring.nameTaken(&app, "showUser") orelse return error.NameNotFound;
    try testing.expectEqualStrings("/users/:id", taken.pattern);
    try testing.expectEqual(@as(?openapi.Operation, null), wiring.nameTaken(&app, "listUsers"));
}

test "docs can be asked for before or after the routes, and both pages appear" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);

    // After the routes this time — the order-independence `use` and `get`
    // already have (ADR 008).
    try app.get("/users/:id", docGetUser);
    app.docs(.{ .title = "Late", .ui_path = "/reference" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const spec = h.send(&app, "GET /openapi.json HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, spec.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, spec.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, spec.response, "\"title\":\"Late\"") != null);
    // Served as a file, so it arrives with an ETag like any other.
    try testing.expect(std.mem.indexOf(u8, spec.response, "ETag: ") != null);

    const page = h.send(&app, "GET /reference HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, page.response, "Content-Type: text/html") != null);
    try testing.expect(std.mem.indexOf(u8, page.response, "data-url=\"/openapi.json\"") != null);
    // The script it loads runs in this origin beside the session cookie, so
    // it is one version and one file, held by its hash.
    try testing.expect(std.mem.indexOf(u8, page.response, "@scalar/api-reference@") != null);
    try testing.expect(std.mem.indexOf(u8, page.response, " integrity=\"sha384-") != null);
    try testing.expect(std.mem.indexOf(u8, page.response, " crossorigin=\"anonymous\"") != null);
}

test "no docs asked for, no documents served" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", docGetUser);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    try testing.expect(app.docs_set == null);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /openapi.json HTTP/1.1\r\nHost: t\r\n\r\n").response,
        "HTTP/1.1 404 Not Found\r\n",
    ));
}

test "a route of your own at the docs path still wins" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{ .ui_path = "/docs" });
    try app.get("/docs", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Routes are matched before anything static is looked at, docs included
    // — so this is the handler, not the reader page.
    const result = h.send(&app, "GET /docs HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "handler"));
}

test "a single-page app serving everything does not swallow the document" {
    // The setup most likely to want an API description is also the one that
    // would hide it: an SPA fallback answers for every path there is.
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "index.html", "<h1>app</h1>" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{ .title = "Behind an SPA" });
    try app.tryStaticWith("/", files.path, .{ .spa_fallback = "index.html" });

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // The fallback really does answer for every path, which is the premise
    // this test exists for rather than an aside.
    try testing.expect(std.mem.indexOf(
        u8,
        h.send(&app, "GET /whatever/deep HTTP/1.1\r\nHost: t\r\nSec-Fetch-Mode: navigate\r\n\r\n").response,
        "<h1>app</h1>",
    ) != null);

    const spec = h.send(&app, "GET /openapi.json HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, spec.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, spec.response, "\"title\":\"Behind an SPA\"") != null);
}

test "rebuilding the document twice does not leak the first one" {
    var db = Db{ .rows = &.{} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    app.docs(.{});
    try app.get("/users/:id", docGetUser);

    // `resolveChains` is what `listen()` calls, and a test — or a program
    // that listens twice — can reach it more than once.
    try app.resolveChains();
    try app.resolveChains();
    try app.resolveChains();
    try testing.expect(app.docs_set != null);
}

// ---- groups and plugins (ADR 014) ----

/// A plugin: an ordinary function that registers into whatever group it is
/// handed. Taking `anytype` rather than a named type is what lets the same
/// function be mounted at any prefix, or at none.
fn healthPlugin(g: anytype) !void {
    try g.get("/healthz", plainOk);
    try g.get("/readyz", plainOk);
}

test "a group puts its prefix on every route inside it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api/v1");
    try api.get("/users", plainOk);
    try api.post("/users", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api/v1/users HTTP/1.1\r\nHost: t\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
    // And the unprefixed path is not a route, which is the other half of
    // what "the prefix is on every route" means.
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /users HTTP/1.1\r\nHost: t\r\n\r\n").response,
        "HTTP/1.1 404 Not Found\r\n",
    ));
}

test "a group's own path is the prefix, with no trailing slash left on it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.get("/", plainOk);

    // Registered as "/api", not "/api/" — the two match the same requests,
    // but only one of them reads correctly in an error message or in the
    // generated documentation.
    try testing.expectEqualStrings("/api", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api HTTP/1.1\r\nHost: t\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "use on a group scopes the middleware to the group" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.use(tagInner);
    try api.get("/thing", plainOk);
    try app.get("/health", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const inside = h.send(&app, "GET /api/thing HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, inside.response, "X-Inner: yes") != null);

    const outside = h.send(&app, "GET /health HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, outside.response, "X-Inner") == null);
}

test "groups nest, and nesting is the same as writing the prefix out" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/api").group("/v1");
    try v1.get("/users/:id", plainOk);

    try testing.expectEqualStrings("/api/v1/users/:id", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    try testing.expect(std.mem.startsWith(
        u8,
        h.send(&app, "GET /api/v1/users/7 HTTP/1.1\r\nHost: t\r\n\r\n").response,
        "HTTP/1.1 200 OK\r\n",
    ));
}

test "a plugin is a function taking a group, and mounts wherever it is put" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // The same function, twice, at two prefixes — which is the thing a
    // group buys that repeating the prefix by hand does not.
    try healthPlugin(app.group("/internal"));
    try healthPlugin(app.group("/admin"));

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    for ([_][]const u8{
        "GET /internal/healthz HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /internal/readyz HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /admin/healthz HTTP/1.1\r\nHost: t\r\n\r\n",
        "GET /admin/readyz HTTP/1.1\r\nHost: t\r\n\r\n",
    }) |request| {
        try testing.expect(std.mem.startsWith(
            u8,
            h.send(&app, request).response,
            "HTTP/1.1 200 OK\r\n",
        ));
    }
}

test "a group at the root registers exactly what it was given" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // What a plugin mounted at the top gets. `use` here has to mean every
    // route rather than every route under "", which is not a prefix.
    const root = app.group("");
    try root.use(tagInner);
    try healthPlugin(root);

    try testing.expectEqualStrings("/healthz", app.router.routes.items[0].pattern);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /healthz HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Inner: yes") != null);
}

test "a duplicate route inside a group is still refused, naming the joined path" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const api = app.group("/api");
    try api.get("/users/:id", plainOk);

    // Checked through the detection rather than the refusal, for the reason
    // the test above this one gives: both forms of the refusal reach a
    // `std.log.err` that Zig's test runner reads as a failure.
    //
    // A prefix is not a namespace — it is text on the front — so the
    // collision is against the joined pattern and nothing else (ADR 012).
    try testing.expect(app.router.conflicting(.GET, "/api/users/:name") != null);
    try testing.expect(app.router.conflicting(.GET, "/users/:id") == null);
}

// ---- resolved values (ADR 015) ----
//
// The gap ADR 008 wrote down and left open: middleware can refuse a
// request but cannot hand the handler the user it just looked up. These
// tests are that gap closed, end to end through a real request.

/// Counts its lookups, because "how many times did this run" is the whole
/// question for the memoisation below.
const Sessions = struct {
    rows: []const struct { token: []const u8, user_id: u32 } = &.{},
    lookups: usize = 0,

    fn userFor(self: *Sessions, token: []const u8) ?u32 {
        self.lookups += 1;
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.token, token)) return row.user_id;
        }
        return null;
    }
};

const SignedIn = struct {
    pub const nilo_resolve = authenticateRequest;

    id: u32,
};

fn authenticateRequest(c: *Ctx, sessions: *Sessions) !SignedIn {
    const token = c.header("Authorization") orelse
        return fail.unauthorized("this endpoint needs an Authorization header", .{});
    return .{
        .id = sessions.userFor(token.view()) orelse
            return fail.unauthorized("that token is not valid", .{}),
    };
}

fn whoAmI(user: SignedIn) !UserOut {
    return .{ .id = user.id, .name = "wati" };
}

/// The other half of the pattern: middleware guards a whole prefix, and the
/// handler behind it still gets the value as an argument.
fn requireSignedIn(c: *Ctx, next: mw.Next) anyerror!void {
    _ = try c.resolve(SignedIn);
    try next.run(c);
}

test "a handler asks for the signed-in user by writing it in its arguments" {
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);
    try app.checkServices();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: t0k\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

test "a resolver that refuses answers its own status and the handler never runs" {
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();

    const no_header = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, no_header.response, "HTTP/1.1 401 Unauthorized\r\n"));
    try testing.expect(std.mem.indexOf(u8, no_header.response, "needs an Authorization header") != null);

    const wrong = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: nope\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 401 Unauthorized\r\n"));
    // Refusing a request is a normal thing to do, not a reason to hang up.
    try testing.expect(wrong.keep_alive);
}

test "a middleware and the handler behind it resolve the user once between them" {
    // Without memoisation this is the shape that quietly doubles every
    // authenticated request's database work: the guard looks the user up to
    // decide, and the handler looks the same user up to answer.
    var sessions = Sessions{ .rows = &.{.{ .token = "t0k", .user_id = 7 }} };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.useOn("/me", requireSignedIn);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: t0k\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expectEqual(@as(usize, 1), sessions.lookups);
}

test "what one request resolved does not leak into the next on the same connection" {
    var sessions = Sessions{ .rows = &.{
        .{ .token = "wati", .user_id = 7 },
        .{ .token = "budi", .user_id = 9 },
    } };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&sessions);
    try app.get("/me", whoAmI);

    var h = Harness.init();
    defer h.deinit();

    const first = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: wati\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, first.response, "\"id\":7") != null);

    // Same connection, different token. The cache lives in the request
    // arena and the arena is reset between requests, so this is the second
    // user and not the first one again — which would be the worst bug this
    // feature could have.
    const second = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: budi\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, second.response, "\"id\":9") != null);
    try testing.expectEqual(@as(usize, 2), sessions.lookups);
}

test "a service only a resolver needs is still caught before serving" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    // `*Sessions` appears nowhere in whoAmI's arguments — only inside the
    // resolver behind `SignedIn`. Missing it has to stop `listen()` all the
    // same (ADR 005), or the first authenticated request finds out instead.
    try app.get("/me", whoAmI);

    // Through the predicate rather than `checkServices()`, which logs the
    // gap before failing — and a test counting those logs reads as a failed
    // suite. Same check, no stderr.
    const missing = app.missingService().?;
    try testing.expectEqualStrings(@typeName(Sessions), missing.type_name);
    try testing.expectEqualStrings("/me", missing.route);
}

test "a route that resolves nothing still costs what it always did" {
    // ADR 017's rule, as a test: a feature nobody used must not show up on
    // the request path. `_resolved` starts empty and allocates only when
    // something is put in it, so this is the same budget as before.
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed("GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n");
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: no CORS, so no response header list, and no body to read, so no
    // copy of the head. All that is left is the JSON.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
}

test "the in-flight request is readable, which is what the panic handler uses" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/known", plainOk);

    var h = Harness.init();
    defer h.deinit();
    _ = h.send(&app, "GET /known HTTP/1.1\r\nHost: t\r\n\r\n");

    // App records these before running the chain, so a panic anywhere
    // inside it can name the request (ADR 007).
    try testing.expectEqualStrings("GET", h.in_flight.method);
    try testing.expectEqualStrings("/known", h.in_flight.path);
}

// ---- responses written in pieces (ADR 019) ----

fn streamRows(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/csv");
    for ([_][]const u8{ "wati", "budi", "sari" }, 1..) |name, id| {
        try body.print("{d},{s}\n", .{ id, name });
        // Flushed one at a time so the test sees the framing, and because
        // this is what a report being watched actually wants.
        try body.flush();
    }
    try body.finish();
}

fn streamAndForget(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    try body.writeAll("half a thought");
    try body.flush();
    // No finish(). App has to make the connection safe anyway.
}

fn streamAfterHeader(c: *Ctx) anyerror!void {
    try c.setStaticHeader("X-Report", "quarterly");
    var body = try c.stream(200, "text/plain");
    try body.writeAll("ok");
    try body.finish();
}

fn streamNoContent(c: *Ctx) anyerror!void {
    var body = try c.stream(204, "text/plain");
    try body.finish();
}

fn streamNotModifiedWithLength(c: *Ctx) anyerror!void {
    var body = try c.streamWith(304, "text/plain", .{ .length = 5 });
    try body.finish();
}

test "a stream under a status that has no body is refused as an error the handler sees" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/nothing", streamNoContent);
    try app.get("/same", streamNotModifiedWithLength);

    var h = Harness.init();
    defer h.deinit();
    // Before the fix the head went out as a 204 carrying `Transfer-Encoding:
    // chunked`, which `writeHead` drops, and the chunks that followed were
    // read by the client as the next response.
    const none = h.send(&app, "GET /nothing HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, none.response, "HTTP/1.1 500"));
    try testing.expect(std.mem.indexOf(u8, none.response, "Transfer-Encoding") == null);
    try testing.expect(std.mem.indexOf(u8, none.response, "no body") != null);

    const same = h.send(&app, "GET /same HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, same.response, "HTTP/1.1 500"));
}

test "peer() hands back the connection's Peer, not a copy whose address dies with the call" {
    // A `Peer` holds its address inline, so `address()` is a slice into the
    // Peer it is called on. Returned by value, `c.peer().address()` pointed
    // into a temporary; a pointer into the Ctx lives as long as the request.
    const Returned = @typeInfo(@TypeOf(Ctx.peer)).@"fn".return_type.?;
    try testing.expect(@typeInfo(Returned) == .pointer);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/peer", struct {
        fn run(c: *Ctx) anyerror!void {
            // Read off the call with nothing bound: on a `Peer` returned by
            // value this slice pointed into a temporary. The stack is
            // dirtied before it is read so a dangling one cannot pass by
            // luck in either optimize mode.
            const addr = c.peer().address();
            var clobber: [256]u8 = undefined;
            @memset(&clobber, 0xAA);
            std.mem.doNotOptimizeAway(&clobber);
            try c.sendText(200, try c._arena.dupe(u8, addr));
        }
    }.run);

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");
    const answer = h.send(&app, "GET /peer HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

test "a streamed response is chunked, and the connection survives it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /rows HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding: chunked\r\n") != null);
    // No Content-Length: that is the whole reason to stream.
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Length") == null);

    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings(
        "7\r\n1,wati\n\r\n7\r\n2,budi\n\r\n7\r\n3,sari\n\r\n0\r\n\r\n",
        body,
    );
    try testing.expect(result.keep_alive);
}

test "a stream to an HTTP/1.0 client is unframed and ends with the connection" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /rows HTTP/1.0\r\n\r\n");

    // 1.0 has no chunked encoding, so the end of the body can only be the
    // end of the connection — and the head has to say so.
    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding") == null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Connection: close\r\n") != null);

    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("1,wati\n2,budi\n3,sari\n", body);
    try testing.expect(!result.keep_alive);
}

test "a HEAD of a streamed route gets the head a GET would have, and no body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/rows", streamRows);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "HEAD /rows HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding: chunked\r\n") != null);
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("", body);
    try testing.expect(result.keep_alive);
}

test "headers set before a stream go out in its head" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/report", streamAfterHeader);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /report HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Report: quarterly\r\n") != null);
}

test "a stream nobody finished still leaves the connection usable" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/oops", streamAndForget);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /oops HTTP/1.1\r\nHost: t\r\n\r\n");

    // App writes the terminator the handler forgot, so the client is told
    // where the body stopped rather than waiting for more.
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("e\r\nhalf a thought\r\n0\r\n\r\n", body);
    try testing.expect(result.keep_alive);
}

fn streamManyPieces(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    for (0..200) |i| {
        try body.print("{d} ", .{i});
        try body.flush();
    }
    try body.finish();
}

test "a stream allocates once, however many pieces it writes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/many", streamManyPieces);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed("GET /many HTTP/1.1\r\nHost: x\r\n\r\n");
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: the stream's own buffer. Two hundred pieces went out through it
    // and not one of them allocated — which is the promise ADR 019 makes, and
    // the reason a stream can run for a week. (It was two; the request head is
    // no longer copied for a request with no body.)
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

// ---- server-sent events ----

fn tickEvents(c: *Ctx) anyerror!void {
    var events = try c.events();
    try events.retry(2000);
    try events.send(.{ .name = "tick", .id = "1", .data = "first" });
    try events.json("state", .{ .open = true, .waiting = 2 });
    try events.close();
}

test "an event stream carries its events, and the headers a proxy needs" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/events", tickEvents);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /events HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "Cache-Control: no-cache\r\n") != null);
    // Without this an nginx in front holds the events back until a buffer
    // fills, which for a token stream is the whole point gone.
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Accel-Buffering: no\r\n") != null);

    // Each event is flushed on its own, so each is its own chunk — which is
    // what makes them arrive one at a time rather than in a batch.
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings(
        "d\r\nretry: 2000\n\n\r\n" ++
            "1f\r\nevent: tick\nid: 1\ndata: first\n\n\r\n" ++
            "2e\r\nevent: state\ndata: {\"open\":true,\"waiting\":2}\n\n\r\n" ++
            "0\r\n\r\n",
        body,
    );
    try testing.expect(result.keep_alive);
}

fn streamUntilStopped(c: *Ctx) anyerror!void {
    var events = try c.events();
    var sent: usize = 0;
    while (events.live()) : (sent += 1) {
        try events.data("tick");
        // A real handler waits for something; this one stops the server on
        // its own so the loop has a way out.
        if (sent == 1) c.service(*App).?.shutdown();
    }
    try events.close();
}

test "a shutdown asks a stream to wind up rather than cutting it off" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&app);
    try app.get("/forever", streamUntilStopped);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /forever HTTP/1.1\r\nHost: t\r\n\r\n");

    // Two events went out and the third was never started: `live()` went
    // false, the loop ended, and the body was closed properly (ADR 019).
    const body = result.response[std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4 ..];
    try testing.expectEqualStrings("c\r\ndata: tick\n\n\r\nc\r\ndata: tick\n\n\r\n0\r\n\r\n", body);

    // And the connection is not offered for another request, because the
    // server is going away.
    try testing.expect(!result.keep_alive);
}

// ---- request bodies read in pieces (ADR 019) ----

/// Counts the body rather than holding it, which is the point: this handler
/// works the same for eleven bytes and eleven gigabytes.
fn weighBody(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [8]u8 = undefined;
    var total: u64 = 0;
    var pieces: u32 = 0;
    while (try incoming.read(&buf)) |part| {
        total += part.len;
        pieces += 1;
    }
    try c.sendJson(200, .{ .bytes = total, .pieces = pieces, .said = incoming.size() });
}

/// Reads the first few bytes and loses interest. App has to leave the
/// connection at the next request anyway.
fn peekBody(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [4]u8 = undefined;
    const first = (try incoming.read(&buf)) orelse "";
    try c.sendText(200, first);
}

test "a body read in pieces arrives whole, and says how big it said it was" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /weigh HTTP/1.1\r\nHost: t\r\nContent-Length: 20\r\n\r\nabcdefghijklmnopqrst");

    // Twenty bytes through an eight-byte buffer: three reads, and the
    // handler never held more than eight of them.
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"bytes\":20,\"pieces\":3,\"said\":20}") != null);
    try testing.expect(result.keep_alive);
}

test "a chunked body read in pieces says nothing about its size" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /weigh HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n",
    );

    // Twelve bytes of body, and `said` is null: a chunked body announces no
    // length, which is the whole reason it exists.
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"bytes\":12,\"pieces\":2,\"said\":null}") != null);
}

test "a body the handler stopped reading is discarded, and the connection continues" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/peek", peekBody);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /peek HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n",
    );

    try testing.expect(std.mem.endsWith(u8, result.response, "hell"));
    // Eight bytes of body were never read and the connection is still
    // offered: App finished what the handler started.
    try testing.expect(result.keep_alive);
}

test "a Content-Length past the ceiling is refused before a byte is read" {
    const refuse = struct {
        fn run(c: *Ctx) anyerror!void {
            var incoming = c.bodyStreamWith(.{ .max_bytes = 8 }) catch
                return fail.tooLarge("that upload is bigger than this endpoint takes", .{});
            var buf: [8]u8 = undefined;
            while (try incoming.read(&buf)) |_| {}
            try c.sendText(200, "took it");
        }
    }.run;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/upload", refuse);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /upload HTTP/1.1\r\nHost: t\r\nContent-Length: 20\r\n\r\nabcdefghijklmnopqrst");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 413"));
    try testing.expect(std.mem.indexOf(u8, result.response, "bigger than this endpoint takes") != null);
    // The body was never read, but it is still discarded, so the connection
    // is usable — a 413 is an answer, not a reason to hang up.
    try testing.expect(result.keep_alive);
}

test "a body read in pieces allocates nothing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "POST /weigh HTTP/1.1\r\nHost: t\r\nContent-Length: 200\r\n\r\n" ++ (&@as([200]u8, @splat('x')));
    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // Two: the request head, and the JSON answer. Two hundred bytes of body
    // went past in twenty-five reads and not one of them allocated —
    // `c.body()` would have made it three and held the lot.
    try testing.expectEqual(@as(usize, 2), counting.allocs);
}

// ---- asking for part of a file (ADR 020) ----

test "a range asks for part of a file and gets a 206" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    // A whole-file request advertises that ranges are possible at all.
    const whole = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, whole.response, "Accept-Ranges: bytes\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, whole.response, "abcdefghijklmnopqrstuvwxyz"));

    const part = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=3-7\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, part.response, "HTTP/1.1 206 Partial Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, part.response, "Content-Range: bytes 3-7/26\r\n") != null);
    // Content-Length is the part's length, not the file's.
    try testing.expect(std.mem.indexOf(u8, part.response, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, part.response, "defgh"));
    try testing.expect(part.keep_alive);

    // Resuming a download: everything from here on.
    const rest = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, rest.response, "Content-Range: bytes 20-25/26\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, rest.response, "uvwxyz"));

    // The tail, counted from the end.
    const tail = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=-3\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, tail.response, "Content-Range: bytes 23-25/26\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, tail.response, "xyz"));
}

test "a range past the end of a file says how big it really is" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const past = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=100-200\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, past.response, "HTTP/1.1 416 Range Not Satisfiable\r\n"));
    // The whole content of the answer, and the reason a client asked wrong.
    try testing.expect(std.mem.indexOf(u8, past.response, "Content-Range: bytes */26\r\n") != null);
    try testing.expect(past.keep_alive);

    // Nonsense is ignored rather than refused: the whole file is a correct
    // answer to every request, and a 416 for a typo helps nobody.
    const nonsense = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=abc-def\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, nonsense.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, nonsense.response, "abcdefghijklmnopqrstuvwxyz"));

    // More than one range wants a multipart body nilo does not assemble.
    const several = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=0-2,10-12\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, several.response, "HTTP/1.1 200 OK\r\n"));
}

test "If-Range holds a resumed download to the file it started with" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    // Read the ETag off a normal response, the way a client resuming would.
    const first = h.send(&app, "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\n\r\n");
    const etag_at = std.mem.indexOf(u8, first.response, "ETag: ").? + 6;
    const etag_end = std.mem.indexOfPos(u8, first.response, etag_at, "\r\n").?;
    var etag_buf: [64]u8 = undefined;
    const etag = etag_buf[0 .. etag_end - etag_at];
    @memcpy(etag, first.response[etag_at..etag_end]);

    var request: [256]u8 = undefined;
    const matching = std.fmt.bufPrint(
        &request,
        "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: {s}\r\n\r\n",
        .{etag},
    ) catch unreachable;
    const resumed = h.send(&app, matching);
    try testing.expect(std.mem.startsWith(u8, resumed.response, "HTTP/1.1 206"));

    // A stale ETag means the file is no longer the one the client started
    // with, so byte 20 of it is not the byte they wanted. All of it, then.
    const stale = h.send(
        &app,
        "GET /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=20-\r\nIf-Range: \"nope\"\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, stale.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, stale.response, "abcdefghijklmnopqrstuvwxyz"));
}

test "a HEAD with a range gets the head a GET would have, and no body" {
    var files = try TmpFiles.init(testing.allocator, &.{
        .{ "alphabet.txt", "abcdefghijklmnopqrstuvwxyz" },
    });
    defer files.deinit(testing.allocator);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static("/", files.path);

    var h = Harness.init();
    defer h.deinit();

    const head = h.send(&app, "HEAD /alphabet.txt HTTP/1.1\r\nHost: t\r\nRange: bytes=3-7\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, head.response, "HTTP/1.1 206 Partial Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, head.response, "Content-Range: bytes 3-7/26\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, head.response, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, head.response, "\r\n\r\n"));
}

// ---- what a failure keeps of the headers the request collected (ADR 024) ----

fn describedThenFailed(c: *Ctx) anyerror!void {
    try c.setHeader("Content-Encoding", "gzip");
    try c.setHeader("Cache-Control", "public, max-age=31536000, immutable");
    try c.setHeader("Expires", "Thu, 01 Dec 2094 16:00:00 GMT");
    try c.setHeader("ETag", "\"v1\"");
    try c.setHeader("Last-Modified", "Wed, 21 Oct 2015 07:28:00 GMT");
    try c.setHeader("Content-Range", "bytes 0-9/100");
    try c.setHeader("Content-Disposition", "attachment; filename=\"report.csv\"");
    try c.setHeader("Location", "/orders/7");
    try c.setHeader("Set-Cookie", "seen=1; Path=/");
    try c.setHeader("Vary", "Origin");
    try c.setHeader("X-Request-Id", "abc");
    try c.setHeader("Retry-After", "5");
    return fail.conflict("order 7 already exists", .{});
}

fn noStoreThenFailed(c: *Ctx) anyerror!void {
    try c.setHeader("Cache-Control", "no-store");
    return fail.conflict("nope", .{});
}

test "a failure drops the headers that described the answer it replaced, and keeps the rest" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", describedThenFailed);
    try app.post("/private", noStoreThenFailed);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    const head = result.response[0..std.mem.indexOf(u8, result.response, "\r\n\r\n").?];
    try testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 409 "));
    for ([_][]const u8{ "Content-Encoding", "Cache-Control", "Expires", "ETag", "Last-Modified", "Content-Range", "Content-Disposition", "Location" }) |gone| {
        if (std.ascii.findIgnoreCase(head, gone) != null) {
            std.debug.print("still there: {s}\n", .{gone});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "Set-Cookie: seen=1", "Vary: Origin", "X-Request-Id: abc", "Retry-After: 5" }) |kept| {
        try testing.expect(std.mem.indexOf(u8, head, kept) != null);
    }

    // A Cache-Control that forbids keeping the answer forbids keeping the
    // failure too, so it is the one that stays.
    const private = h.send(&app, "POST /private HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, private.response, "Cache-Control: no-store\r\n") != null);
}

// ---- a second answer is an error, not an assert ----

var second_answers: [3]?anyerror = .{ null, null, null };

fn answeredThenStream(c: *Ctx) anyerror!void {
    try c.sendText(200, "first");
    _ = c.streamWith(200, "text/plain", .{}) catch |err| {
        second_answers[0] = err;
    };
}

fn answeredThenUpgrade(c: *Ctx) anyerror!void {
    try c.sendText(200, "first");
    c.upgrade(echoLoop, {}) catch |err| {
        second_answers[1] = err;
    };
}

fn answeredThenEvents(c: *Ctx) anyerror!void {
    try c.sendText(200, "first");
    c.eventsFrom(feed_room, .{}) catch |err| {
        second_answers[2] = err;
    };
}

test "a stream, an upgrade or an event stream after the request was answered is AlreadyAnswered" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/stream", answeredThenStream);
    try app.get("/upgrade", answeredThenUpgrade);
    try app.get("/events", answeredThenEvents);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    second_answers = .{ null, null, null };
    for ([_][]const u8{ "/stream", "/upgrade", "/events" }, 0..) |path, i| {
        var buf: [64]u8 = undefined;
        const request = try std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHost: t\r\n\r\n", .{path});
        const result = h.send(&app, request);
        try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
        try testing.expect(std.mem.endsWith(u8, result.response, "first"));
        try testing.expectEqual(@as(?anyerror, error.AlreadyAnswered), second_answers[i]);
    }
}

// ---- WebSocket (ADR 021) ----

fn echoSocket(c: *Ctx) anyerror!void {
    return c.upgrade(echoLoop, {});
}

fn echoLoop(socket: *websocket.Socket) anyerror!void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

const upgrade_request = "GET /ws HTTP/1.1\r\nHost: x\r\n" ++
    "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
    "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";

/// The rooms `joinAndForgetLoop` sits in. A loop's state is its own; a test
/// that reads the rooms after the connection is over needs them out here.
var forgetful_room: *room_mod.Room = undefined;
var forgetful_second: *room_mod.Room = undefined;

fn joinAndForget(c: *Ctx) anyerror!void {
    return c.upgrade(joinAndForgetLoop, {});
}

fn joinAndForgetLoop(socket: *websocket.Socket) anyerror!void {
    try forgetful_room.join(socket);
    try forgetful_second.join(socket);
    while (try socket.receive()) |_| {}
}

test "every seat a WebSocket loop never gave up is given up when the loop returns" {
    // Each seat's bell is in the connection's frame. Left taken, the next
    // `say` rings it after that frame has returned (ADR 082), in the second
    // room as much as the first.
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer room.deinit();
    var second = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 2 });
    defer second.deinit();
    forgetful_room = &room;
    forgetful_second = &second;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", joinAndForget);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, upgrade_request);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 101"));
    try testing.expectEqual(@as(usize, 0), room.count());
    try testing.expectEqual(@as(usize, 0), second.count());
    try room.sayText("nobody is here");
    try second.sayText("nor here");
}

/// The room `feed` sits its event stream in, and says three things into once
/// the stream is seated: a WebSocket frame has nowhere for the second's name
/// and id, and an event stream has no way to carry the third.
var feed_room: *room_mod.Room = undefined;

fn feed(c: *Ctx) anyerror!void {
    try c.eventsFrom(feed_room, .{ .retry_ms = 5_000 });
    try feed_room.sayText("hello");
    try feed_room.event(.{ .name = "tick", .id = "7", .data = "{}" });
    try feed_room.sayBinary("\x00\x01");
}

test "an event stream from a room is handed to the connection, and hears what the room says" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feed);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: text/event-stream\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Accel-Buffering: no\r\n") != null);
    // The retry first, then each post as its own chunk, and the end of the
    // body once the client has gone (the harness's Waker answers every wait
    // with "go and read", which is a client that spoke).
    try testing.expect(std.mem.endsWith(
        u8,
        result.response,
        "\r\n\r\nd\r\nretry: 5000\n\n\r\n" ++
            "d\r\ndata: hello\n\n\r\n" ++
            "1c\r\nevent: tick\nid: 7\ndata: {}\n\n\r\n" ++
            "0\r\n\r\n",
    ));
    // A stream that never ends leaves nothing to keep alive, and every seat
    // is given up on the way out.
    try testing.expect(!result.keep_alive);
    try testing.expectEqual(@as(usize, 0), room.count());
}

var full_room: *room_mod.Room = undefined;

fn feedFull(c: *Ctx) anyerror!void {
    return c.eventsFrom(full_room, .{});
}

test "an event stream into a full room is a 503 the client can read, not a stream that ends at once" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();
    full_room = &room;

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var sitting: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };
    try room.join(&sitting);
    defer room.leave(&sitting);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedFull);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 503"));
    try testing.expect(std.mem.indexOf(u8, result.response, "every seat in this room is taken") != null);
    try testing.expectEqual(@as(usize, 1), room.count());
}

test "a HEAD for an event stream from a room gets the head and takes no seat" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 1, .backlog = 2 });
    defer room.deinit();
    full_room = &room;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedFull);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "HEAD /feed HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "data:") == null);
    try testing.expectEqual(@as(usize, 0), room.count());
}

var kept_room: *room_mod.Room = undefined;

fn feedKept(c: *Ctx) anyerror!void {
    try c.eventsFrom(kept_room, .{});
    try kept_room.event(.{ .id = "4", .data = "four" });
}

/// A room that kept three events while nobody was listening.
fn keptThree(room: *room_mod.Room) !void {
    try room.event(.{ .id = "1", .data = "one" });
    try room.event(.{ .id = "2", .data = "two" });
    try room.event(.{ .id = "3", .data = "three" });
}

test "a client coming back with Last-Event-ID gets what the room said after it, then what is new" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4, .history = 8 });
    defer room.deinit();
    kept_room = &room;
    try keptThree(&room);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedKept);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\nLast-Event-ID: 1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    // Two and three from the room's history, in the order they were said,
    // then four, which arrived after the stream sat down. Nothing twice.
    try testing.expect(std.mem.endsWith(
        u8,
        result.response,
        "\r\n\r\n11\r\nid: 2\ndata: two\n\n\r\n" ++
            "13\r\nid: 3\ndata: three\n\n\r\n" ++
            "12\r\nid: 4\ndata: four\n\n\r\n" ++
            "0\r\n\r\n",
    ));
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a first connection, or an id the room never kept, replays nothing" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4, .history = 8 });
    defer room.deinit();
    kept_room = &room;
    try keptThree(&room);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedKept);

    const only_new = "\r\n\r\n12\r\nid: 4\ndata: four\n\n\r\n0\r\n\r\n";
    {
        var h = Harness.init();
        defer h.deinit();
        const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");
        try testing.expect(std.mem.endsWith(u8, result.response, only_new));
    }
    {
        // Forgotten, or said by another room: there is no telling which, and
        // guessing would send somebody events twice.
        var h = Harness.init();
        defer h.deinit();
        const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\nLast-Event-ID: 99\r\n\r\n");
        try testing.expect(std.mem.endsWith(u8, result.response, only_new));
    }
}

var named_pool: *rooms_mod.Rooms = undefined;

fn feedMine(c: *Ctx) anyerror!void {
    try c.eventsFrom(.{ feed_room, named_pool.named("user:1") }, .{});
    try named_pool.sayText("user:1", "just you");
    try named_pool.sayText("user:2", "somebody else");
}

test "an event stream sits under a key beside a Room, and the key goes back when it ends" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    var pool = try rooms_mod.Rooms.initWith(testing.allocator, .{ .rooms = 2, .seats = 2 });
    defer pool.deinit();
    named_pool = &pool;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedMine);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\n10\r\ndata: just you\n\n\r\n0\r\n\r\n"));
    try testing.expectEqual(@as(usize, 0), room.count());
    try testing.expectEqual(@as(usize, 0), pool.count("user:1"));
    try testing.expect(pool.pool.names.get("user:1") == null);
}

test "an event stream under a key when every Room is lent is a 503 naming the number" {
    var room = try room_mod.Room.initWith(testing.allocator, .{ .seats = 2, .backlog = 4 });
    defer room.deinit();
    feed_room = &room;
    var pool = try rooms_mod.Rooms.initWith(testing.allocator, .{ .rooms = 1, .seats = 2 });
    defer pool.deinit();
    named_pool = &pool;

    var in = std.Io.Reader.fixed("");
    var bytes: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    var sitting: websocket.Socket = .{ ._in = &in, ._out = &out, ._stopping = null };
    try pool.join("user:9", &sitting);
    defer pool.leave("user:9", &sitting);

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/feed", feedMine);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 503"));
    try testing.expect(std.mem.indexOf(u8, result.response, "the pool's rooms is the number to raise") != null);
    // The seat in the Room the stream had already taken is given back.
    try testing.expectEqual(@as(usize, 0), room.count());
}

test "a WebSocket handshake is answered with the key every client checks" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, upgrade_request);

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 101 Switching Protocols\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Upgrade: websocket\r\n") != null);
    // The answer from RFC 6455 §1.3 for that key.
    try testing.expect(std.mem.indexOf(
        u8,
        result.response,
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
    ) != null);

    // The connection has stopped being HTTP, so it cannot carry another
    // request whatever anybody asked for.
    try testing.expect(!result.keep_alive);
}

test "a message sent over the upgraded connection comes back" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();

    // The handshake and one masked text frame in the same buffer, which is
    // how a client that starts talking immediately looks on the wire.
    const frame = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58"; // "Hello"
    const result = h.send(&app, upgrade_request ++ frame);

    const after_head = std.mem.indexOf(u8, result.response, "\r\n\r\n").? + 4;
    // 0x81 = FIN + text, 0x05 = five bytes, no mask bit: a server never masks.
    try testing.expectEqualStrings("\x81\x05Hello", result.response[after_head..]);
}

test "a WebSocket allocates nothing per message, however many it carries" {
    // The claim the docs make about `receive`, which nothing checked. A
    // stream and a body reader each have a test like this one; the largest
    // and longest-lived of the three had none, which is the wrong way round
    // — a per-message allocation on a socket open for a day is a leak with
    // a nicer name.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    // "Hello", masked, two hundred times over.
    const frame = "\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58";
    const conversation = comptime upgrade_request ++ repeat(frame, 200);

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            // Unmasked in place, so it cannot be the read-only literal.
            var bytes = conversation.*;
            var in = std.Io.Reader.fixed(&bytes);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    counting.reset();
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // One: the request head. Not the handshake, not the frame headers, and
    // not one of the two hundred messages — `receive` reads into the buffer
    // the handler already owns, and a server frame is a ten-byte header
    // written straight to the connection.
    try testing.expectEqual(@as(usize, 1), counting.allocs);
    try testing.expectEqual(@as(usize, 0), counting.resizes);
}

test "the loop runs after the handler has returned, not inside it" {
    // The whole point of the shape: `serveRequest` is finished with — its
    // `Ctx`, its parsed head and its route match are gone — before a byte of
    // the conversation is read (ADR 062).
    const Trace = struct {
        var handler_returned: bool = false;
        var loop_saw_it: bool = false;

        fn open(c: *Ctx) anyerror!void {
            handler_returned = false;
            loop_saw_it = false;
            defer handler_returned = true;
            return c.upgrade(loop, {});
        }
        fn loop(socket: *websocket.Socket) anyerror!void {
            loop_saw_it = handler_returned;
            while (try socket.receive()) |_| {}
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", Trace.open);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, upgrade_request);

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 101"));
    try testing.expect(Trace.loop_saw_it);
}

test "what the handler knew reaches the loop, by value" {
    // A `Str` off the query is the case `examples/chat` needs: the handler can
    // read the request and the loop cannot, so whatever it learned has to
    // travel across on its own.
    const Carry = struct {
        var seen: [32]u8 = undefined;
        var seen_len: usize = 0;

        fn open(c: *Ctx) anyerror!void {
            const name = c.query("name") orelse return error.NoName;
            return c.upgrade(loop, name);
        }
        fn loop(socket: *websocket.Socket, name: str_mod.Str) anyerror!void {
            seen_len = name.view().len;
            @memcpy(seen[0..seen_len], name.view());
            while (try socket.receive()) |_| {}
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", Carry.open);

    var h = Harness.init();
    defer h.deinit();
    _ = h.send(&app, "GET /ws?name=ada HTTP/1.1\r\nHost: x\r\n" ++
        "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n");

    try testing.expectEqualStrings("ada", Carry.seen[0..Carry.seen_len]);
}

test "a request that is not asking to be upgraded is told which part is missing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();

    const plain = h.send(&app, "GET /ws HTTP/1.1\r\nHost: x\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, plain.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, plain.response, "Upgrade: websocket") != null);

    const no_version = h.send(
        &app,
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, no_version.response, "missing Sec-WebSocket-Version") != null);

    const wrong_version = h.send(
        &app,
        "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Version: 8\r\nSec-WebSocket-Key: x\r\n\r\n",
    );
    try testing.expect(std.mem.indexOf(u8, wrong_version.response, "speaks WebSocket version 13") != null);
}

test "a handshake key that is not sixteen bytes of base64 is a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);

    var h = Harness.init();
    defer h.deinit();
    for ([_][]const u8{ "x", "dGhlIHNhbXBsZSBub25jZQ", "dGhlIHNhbXBsZSBub25jZQ=!" }) |key| {
        var buf: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &buf,
            "GET /ws HTTP/1.1\r\nHost: t\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n\r\n",
            .{key},
        );
        const result = h.send(&app, request);
        try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400"));
        try testing.expect(std.mem.indexOf(u8, result.response, "101") == null);
    }
}

fn chatSocket(c: *Ctx) anyerror!void {
    return c.upgradeWith(echoLoop, {}, .{ .protocols = &.{ "chat.v1", "chat.v2" } });
}

test "a sub-protocol is answered only when the client offered one the route speaks" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/chat", chatSocket);

    var h = Harness.init();
    defer h.deinit();
    const base = "GET /chat HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n";

    const offered = h.send(&app, base ++ "Sec-WebSocket-Protocol: mqtt, chat.v2\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, offered.response, "Sec-WebSocket-Protocol: chat.v2\r\n") != null);

    // The browser's plain `new WebSocket(url)` offers nothing, and a name it
    // did not offer is a connection it fails.
    const silent = h.send(&app, base ++ "\r\n");
    try testing.expect(std.mem.startsWith(u8, silent.response, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, silent.response, "Sec-WebSocket-Protocol") == null);

    const other = h.send(&app, base ++ "Sec-WebSocket-Protocol: mqtt\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, other.response, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, other.response, "Sec-WebSocket-Protocol") == null);
}

test "a socket a page on another origin asked for is not opened" {
    const Named = struct {
        fn open(c: *Ctx) anyerror!void {
            return c.upgradeWith(echoLoop, {}, .{ .origins = &.{"https://app.example.com"} });
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", echoSocket);
    try app.get("/named", Named.open);

    var h = Harness.init();
    defer h.deinit();

    const rest = "Upgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n";

    // The whole reason this check exists: a browser applies no CORS to a
    // WebSocket, sends no preflight and honours no `Access-Control-Allow-
    // Origin`, so nothing in front of the handshake refuses this — and the
    // handshake is an ordinary GET, so it arrives with the session cookie on
    // it. Nothing but the server can say no.
    const foreign = h.send(&app, "GET /ws HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Origin: https://evil.dev\r\n" ++ rest);
    try testing.expect(std.mem.startsWith(u8, foreign.response, "HTTP/1.1 403"));
    try testing.expect(std.mem.indexOf(u8, foreign.response, "101") == null);
    try testing.expect(std.mem.indexOf(u8, foreign.response, ".origins") != null);

    // The server's own page, which is the ordinary case and needs no option.
    const own = h.send(&app, "GET /ws HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Origin: https://example.dev\r\n" ++ rest);
    try testing.expect(std.mem.startsWith(u8, own.response, "HTTP/1.1 101"));

    // No `Origin` at all is not a browser, and the ambient cookie this
    // guards is a browser's. `wstest` and every command-line client send
    // none.
    const headless = h.send(&app, "GET /ws HTTP/1.1\r\nHost: example.dev\r\n" ++ rest);
    try testing.expect(std.mem.startsWith(u8, headless.response, "HTTP/1.1 101"));

    // And a page on the host the route named, which is what a socket served
    // from a different host to the page needs.
    const named = h.send(&app, "GET /named HTTP/1.1\r\nHost: api.example.com\r\n" ++
        "Origin: https://app.example.com\r\n" ++ rest);
    try testing.expect(std.mem.startsWith(u8, named.response, "HTTP/1.1 101"));

    const unnamed = h.send(&app, "GET /named HTTP/1.1\r\nHost: api.example.com\r\n" ++
        "Origin: https://other.example.com\r\n" ++ rest);
    try testing.expect(std.mem.startsWith(u8, unnamed.response, "HTTP/1.1 403"));
}

// ---- what the request said, beyond the parts a handler asks for by name ----

fn echoQueries(c: *Ctx) anyerror!void {
    var out: std.ArrayList(u8) = .empty;
    var it = c.queries();
    while (it.next()) |q| {
        try out.print(c._arena, "{f}={f};", .{ q.name, q.value });
    }
    try c.sendText(200, out.items);
}

fn echoQueryString(c: *Ctx) anyerror!void {
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "[{f}]", .{c.queryString()}));
}

test "every query parameter can be walked, including a name sent twice" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/q", echoQueries);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // The case `query(name)` cannot serve at all: names that are data, and a
    // name sent more than once (ADR 090).
    const answer = h.send(
        &app,
        "GET /q?filter%5Bstatus%5D=open&tag=a&tag=b&empty= HTTP/1.1\r\nHost: t\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(
        u8,
        answer.response,
        "filter[status]=open;tag=a;tag=b;empty=;",
    ));

    // No query at all is no parameters rather than one empty one.
    const bare = h.send(&app, "GET /q HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, bare.response, "\r\n\r\n"));
}

test "the query string is also readable as the bytes that arrived" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/raw", echoQueryString);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // Still encoded, and with no `?` on the front: this is for a signature or
    // a proxy, where what was sent matters and not what it meant.
    const answer = h.send(&app, "GET /raw?a=1&b=%20two HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "[a=1&b=%20two]"));

    const none = h.send(&app, "GET /raw HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, none.response, "[]"));
}

// ---- the URL the client used, which is not the one nilo saw ----

fn echoBaseUrl(c: *Ctx) anyerror!void {
    try c.sendText(200, try std.fmt.allocPrint(
        c._arena,
        "{f}://{f}",
        .{ c.scheme(), c.host() },
    ));
}

test "with no proxy trusted, the scheme is the connection's and the host is the Host header" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/where", echoBaseUrl);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // Forged, and ignored: nilo did not see TLS and nobody said a proxy did.
    const answer = h.send(
        &app,
        "GET /where HTTP/1.1\r\nHost: api.example.com\r\n" ++
            "X-Forwarded-Proto: https\r\nX-Forwarded-Host: evil.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, answer.response, "http://api.example.com"));
}

test "with a proxy trusted, the scheme and host are the ones it forwarded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/where", echoBaseUrl);
    try app.resolveChains();
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();

    // The ordinary deployment: TLS terminated in front, the internal Host
    // rewritten to the pod, and the real one in X-Forwarded-Host.
    const answer = h.send(
        &app,
        "GET /where HTTP/1.1\r\nHost: 10.0.0.4:8080\r\n" ++
            "X-Forwarded-Proto: https\r\nX-Forwarded-Host: api.example.com\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, answer.response, "https://api.example.com"));

    // A chain writes a list, and the first entry is what the client asked for.
    const chained = h.send(
        &app,
        "GET /where HTTP/1.1\r\nHost: 10.0.0.4:8080\r\n" ++
            "X-Forwarded-Proto: https, http\r\nX-Forwarded-Host: api.example.com, 10.0.0.4\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, chained.response, "https://api.example.com"));

    // A value that is not a host does not go into a URL somebody clicks.
    const nonsense = h.send(
        &app,
        "GET /where HTTP/1.1\r\nHost: 10.0.0.4:8080\r\n" ++
            "X-Forwarded-Host: api.example.com/../evil\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, nonsense.response, "http://10.0.0.4:8080"));

    // And a proxy that forwards plain HTTP is believed about that too.
    const plain = h.send(
        &app,
        "GET /where HTTP/1.1\r\nHost: api.example.com\r\nX-Forwarded-Proto: http\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, plain.response, "http://api.example.com"));
}

test "with the proxies named, the scheme and host are read only from a connection one of them made" {
    // The deploying guide's shape: `.trusted_proxies`, no hop count. Both
    // accessors used to read `trusted_hops` alone, so this deployment saw
    // `http` behind TLS for ever, and `trusted_hops = 1` to fix it believed
    // `X-Forwarded-Host` from a request straight to the pod (ADR 090).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/where", echoBaseUrl);
    try app.resolveChains();
    try wiring.parseTrustedProxies(&app, &.{"10.0.0.0/8"});
    app.limits.trusted_proxies = app.trusted_proxies;

    var h = Harness.init();
    defer h.deinit();
    const forwarded = "GET /where HTTP/1.1\r\nHost: 10.0.0.4:8080\r\n" ++
        "X-Forwarded-Proto: https\r\nX-Forwarded-Host: api.example.com\r\n\r\n";

    h.peer = try bulkhead.Peer.from("10.0.0.1");
    const through = h.send(&app, forwarded);
    try testing.expect(std.mem.endsWith(u8, through.response, "https://api.example.com"));

    // The same headers from an address nobody named are the sender's own.
    h.peer = try bulkhead.Peer.from("198.51.100.7");
    const around = h.send(&app, forwarded);
    try testing.expect(std.mem.endsWith(u8, around.response, "http://10.0.0.4:8080"));
}

test "on a listener with its own TLS the scheme is https, whatever a header says" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/where", echoBaseUrl);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");
    h.peer.tls = true;
    const answer = h.send(&app, "GET /where HTTP/1.1\r\nHost: api.example.com\r\nX-Forwarded-Proto: http\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "https://api.example.com"));
}

// ---- a body under an encoding nilo cannot read ----

test "a body under a Content-Encoding nilo cannot decode is refused with a 415 naming the header" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/things", plainOk);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // What used to happen: the stream reached the JSON parser and came back
    // as "malformed body", which is true of the bytes and useless to whoever
    // sent them (ADR 089). gzip is decoded now; brotli is not.
    const brotli = h.send(
        &app,
        "POST /things HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\n" ++
            "Content-Type: application/json\r\nContent-Length: 3\r\n\r\nabc",
    );
    try testing.expect(std.mem.startsWith(u8, brotli.response, "HTTP/1.1 415"));
    try testing.expect(std.mem.indexOf(u8, brotli.response, "Content-Encoding") != null);
    try testing.expect(std.mem.indexOf(u8, brotli.response, "gzip") != null);

    // Two codings stacked is a coding nilo cannot read, whichever they are.
    const stacked = h.send(
        &app,
        "POST /things HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip, br\r\n" ++
            "Content-Length: 3\r\n\r\nabc",
    );
    try testing.expect(std.mem.startsWith(u8, stacked.response, "HTTP/1.1 415"));

    // `identity` is the one coding that means "these are the bytes".
    const plain = h.send(
        &app,
        "POST /things HTTP/1.1\r\nHost: t\r\nContent-Encoding: identity\r\n" ++
            "Content-Length: 2\r\n\r\nhi",
    );
    try testing.expect(std.mem.startsWith(u8, plain.response, "HTTP/1.1 200"));

    // A header on a request with no body says nothing about anything, and is
    // left alone rather than turned into a refusal nobody expected.
    const bodyless = h.send(
        &app,
        "GET /nothing HTTP/1.1\r\nHost: t\r\nContent-Encoding: br\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, bodyless.response, "HTTP/1.1 404"));
}

/// `text`, gzipped by std, framed as a request body of that length.
fn gzippedRequest(gpa: std.mem.Allocator, head: []const u8, text: []const u8) ![]u8 {
    // `Compress.init` asserts its output has somewhere to write, and an
    // `Allocating` starts with a buffer of nothing at all (see `static.zig`).
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer out.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress: std.compress.flate.Compress = try .init(&out.writer, &window, .gzip, .default);
    try compress.writer.writeAll(text);
    try compress.finish();
    const packed_bytes = out.written();
    return std.fmt.allocPrint(gpa, "{s}Content-Length: {d}\r\n\r\n{s}", .{ head, packed_bytes.len, packed_bytes });
}

const Greeting = struct { name: []const u8, times: u32 };

fn greetGzipped(g: Greeting) ![]const u8 {
    _ = g.times;
    return g.name;
}

test "a gzipped body is inflated before anything reads it, so a typed handler sees the JSON" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/greet", greetGzipped);
    try app.post("/echo", echoBody);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // A typed body: what the stock OpenTelemetry Collector and most agents
    // send by default reaches `c.json` as JSON (ADR 089).
    const greeting = try gzippedRequest(
        testing.allocator,
        "POST /greet HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\nContent-Type: application/json\r\n",
        "{\"name\":\"wati\",\"times\":3}",
    );
    defer testing.allocator.free(greeting);
    const greeted = h.send(&app, greeting);
    try testing.expect(std.mem.startsWith(u8, greeted.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, greeted.response, "\r\n\r\nwati"));

    // `c.body()` too, and the old spelling of the coding.
    const text = repeat("the same line, sent again and again and again and again, ", 20);
    const raw = try gzippedRequest(testing.allocator, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: x-gzip\r\n", text);
    defer testing.allocator.free(raw);
    const echoed = h.send(&app, raw);
    try testing.expect(std.mem.startsWith(u8, echoed.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, echoed.response, text));
    try testing.expect(echoed.keep_alive);
}

test "a gzipped body that does not decode is a 400 that names the coding, and one over the ceiling is a 413" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    // The JSON somebody forgot to compress, under a header that says they did.
    const not_gzip = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\n" ++
            "Content-Length: 27\r\n\r\n{\"name\":\"wati\",\"a\":1,\"b\":2}",
    );
    try testing.expect(std.mem.startsWith(u8, not_gzip.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, not_gzip.response, "Content-Encoding: gzip") != null);
    // Answered, and the connection is still good for the next request: the
    // body was read whole before it was found wanting.
    try testing.expect(not_gzip.keep_alive);

    // Over `max_body` once inflated, by the stream's own account — refused
    // by the number, before a byte is inflated.
    const big = repeat("0123456789abcdef", 64 * 1024 / 16 + 1);
    const over = try gzippedRequest(testing.allocator, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\n", big);
    defer testing.allocator.free(over);
    app.limits.max_body = 64 * 1024;
    const refused = h.send(&app, over);
    try testing.expect(std.mem.startsWith(u8, refused.response, "HTTP/1.1 413"));
}

test "a body read as a stream is not decoded, and says so with a 415" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/weigh", weighBody);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    const raw = try gzippedRequest(testing.allocator, "POST /weigh HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\n", "twenty bytes of body");
    defer testing.allocator.free(raw);
    const result = h.send(&app, raw);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 415"));
    try testing.expect(std.mem.indexOf(u8, result.response, "stream") != null);
}

// ---- who the client is (X-Forwarded-For) ----

fn echoClientIp(c: *Ctx) anyerror!void {
    try c.sendText(200, try std.fmt.allocPrint(c._arena, "{f}", .{c.clientIp()}));
}

// The whole point of the default. A server that believed the header
// without being told to would let anyone be any address they liked, and
// the things that read a client address — rate limits, audit logs,
// blocklists — are exactly the things worth lying to.
test "with no proxies trusted, a forged X-Forwarded-For is ignored" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");

    const answer = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

test "with one proxy trusted, the client is the entry that proxy wrote" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // Nothing forged: the proxy appended the address it saw, and that is
    // the only entry there is.
    const plain = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, plain.response, "203.0.113.9"));

    // The client sent an address of its own and the proxy appended after
    // it. Counting from the right reads the proxy's entry; the forgery is
    // to the left of it and is never looked at. This is why the count is
    // from the right and not from the left.
    const forged = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 9.9.9.9, 203.0.113.9\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, forged.response, "203.0.113.9"));
}

test "with two proxies trusted, the client is two entries from the right" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 2;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // A CDN saw the client and appended it; the load balancer saw the CDN
    // and appended that. Two hops back from the right is the client.
    const answer = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9, 198.51.100.2\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, answer.response, "203.0.113.9"));
}

test "naming the network reads the client whatever the chain's length turned out to be" {
    // The gap a hop count leaves: grow a hop and the count is silently wrong,
    // because `clientIp()` goes on returning something that looks like an
    // address (ADR 102). Described instead, the length stops mattering.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    try wiring.parseTrustedProxies(&app, &.{"private"});
    app.limits.trusted_proxies = app.trusted_proxies;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // One proxy in front.
    const one = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, one.response, "203.0.113.9"));

    // Two, on the same configuration and with nothing changed. This is the
    // line a hop count of 1 would have got wrong, quietly.
    const two = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9, 10.0.0.4\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, two.response, "203.0.113.9"));

    // And a client forging entries of its own: they sit to the left of the
    // first address that is not ours, and are never reached.
    const forged = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.1.1.1, 203.0.113.9, 10.0.0.4\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, forged.response, "203.0.113.9"));
}

test "a header from a machine that is not one of ours is not read" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    try wiring.parseTrustedProxies(&app, &.{"10.0.0.0/8"});
    app.limits.trusted_proxies = app.trusted_proxies;

    var h = Harness.init();
    defer h.deinit();
    // Straight off the internet. Whatever it claims to be forwarding for is
    // its own invention, and the socket's address is the honest answer.
    h.peer = try bulkhead.Peer.from("198.51.100.7");

    const answer = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

test "a named network wins over a hop count left over from before" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    try wiring.parseTrustedProxies(&app, &.{"10.0.0.0/8"});
    app.limits.trusted_proxies = app.trusted_proxies;
    // Set, and wrong for this chain. The description is what the operator
    // meant; the number is the thing it exists to stop mattering.
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    const answer = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 203.0.113.9, 10.0.0.4\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, answer.response, "203.0.113.9"));
}

test "a trusted proxy that is not an address stops the server rather than being ignored" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try testing.expectError(
        error.TrustedProxyNotAnAddress,
        wiring.parseTrustedProxies(&app, &.{ "10.0.0.0/8", "the load balancer" }),
    );
    // Nothing half-parsed is left behind for `clientIp` to read.
    try testing.expectEqual(@as(usize, 0), app.trusted_proxies.len);
    // And the sentence `listen()` prints names the rule that was wrong, not
    // the one before it.
    try testing.expectEqualStrings(
        "the load balancer",
        proxies_mod.firstBad(&.{ "10.0.0.0/8", "the load balancer" }).?,
    );
}

test "a proxy that adds a field of its own is read the same as one that appends" {
    // HAProxy's `option forwardfor` adds an `X-Forwarded-For` field rather
    // than appending to the one the client sent, so a forged header arrives
    // as two fields: the forgery first, the proxy's own after it. RFC 9110
    // §5.3 reads them as one list in wire order, and so does nilo — reading
    // the first field alone answered "1.2.3.4" here with the rules set, which
    // is the address the client typed.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    try wiring.parseTrustedProxies(&app, &.{"10.0.0.0/8"});
    app.limits.trusted_proxies = app.trusted_proxies;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.7");

    const named = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.2.3.4\r\nX-Forwarded-For: 203.0.113.9, 10.0.0.7\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, named.response, "203.0.113.9"));

    // The count reads the same list: one hop back from the right is the
    // proxy's entry, in the second field.
    app.limits.trusted_proxies = &.{};
    app.limits.trusted_hops = 1;
    const counted = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.2.3.4\r\nX-Forwarded-For: 203.0.113.9\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, counted.response, "203.0.113.9"));

    // A client that stuffs the head with fields of its own, private
    // addresses to pass as a proxy, and HAProxy adding the real one as a
    // field after them. The last eight are read, from the right, so the
    // client is found; answering with the socket's address, as past eight
    // once did, answered with the proxy's, `10.0.0.7`, and an allow-list of
    // private addresses let the client in.
    app.limits.trusted_hops = 0;
    app.limits.trusted_proxies = app.trusted_proxies;
    const stuffed = h.send(
        &app,
        "GET /who HTTP/1.1\r\nHost: t\r\n" ++ (repeat("X-Forwarded-For: 10.0.0.9\r\n", 8)) ++
            "X-Forwarded-For: 203.0.113.9\r\n\r\n",
    );
    try testing.expect(std.mem.endsWith(u8, stuffed.response, "203.0.113.9"));
}

test "a header with fewer entries than there are hops falls back to the socket" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", echoClientIp);
    try app.resolveChains();
    app.limits.trusted_hops = 2;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("10.0.0.1");

    // Two proxies were configured and one entry turned up, so the chain is
    // not the one this server was told about. The closest guess would be
    // the client's own forgery, so there is no guess.
    const short = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 9.9.9.9\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, short.response, "10.0.0.1"));

    // And no header at all is the same answer.
    const none = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, none.response, "10.0.0.1"));
}

test "the socket's own address is there whatever the header says" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/peer", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, try std.fmt.allocPrint(c._arena, "{f}", .{c.peer()}));
        }
    }.run);
    try app.resolveChains();
    app.limits.trusted_hops = 1;

    var h = Harness.init();
    defer h.deinit();
    h.peer = try bulkhead.Peer.from("198.51.100.7");

    const answer = h.send(&app, "GET /peer HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: 1.2.3.4\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "198.51.100.7"));
}

// ---- the body ceiling is a number somebody can change ----

test "a body past max_body is a 413, and max_body is what listen() was told" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const body = "0123456789";
    const request = "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 10\r\n\r\n" ++ body;

    // Ten bytes is under the default megabyte.
    const allowed = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, allowed.response, "HTTP/1.1 200"));

    // The same ten bytes against a ceiling of four.
    app.limits.max_body = 4;
    const refused = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, refused.response, "HTTP/1.1 413"));

    // And raising it past the default works in the other direction, which
    // is the half a proxy in front cannot do for you.
    app.limits.max_body = 32 * 1024 * 1024;
    const raised = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, raised.response, "HTTP/1.1 200"));
}

test "a chunked body is counted against max_body as it arrives" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", struct {
        fn run(c: *Ctx) anyerror!void {
            try c.sendText(200, (try c.body()).view());
        }
    }.run);
    try app.resolveChains();
    app.limits.max_body = 4;

    var h = Harness.init();
    defer h.deinit();

    // No Content-Length to refuse up front, so the only way to catch this
    // is to count the chunks.
    const answer = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++
            "5\r\nhello\r\n0\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 413"));
}

// ---- static files, gzipped once at startup ----

/// Big enough and repetitive enough to be worth compressing, which is what
/// a real stylesheet or bundle is.
const test_css = repeat("body { margin: 0; padding: 0; } ", 64);

fn cssApp(gpa: std.mem.Allocator) !App {
    var app = App.init(gpa);
    errdefer app.deinit();
    try app.static_sets.append(gpa, try static_mod.fromMemory(gpa, &.{.{
        .url = "/app.css",
        .bytes = test_css,
        .content_type = "text/css",
    }}));
    try app.resolveChains();
    return app;
}

test "a client that says gzip gets the copy made at startup" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding: gzip") != null);
    // Whenever there are two representations, whichever one goes out.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Accept-Encoding") != null);

    const body = answer.response[std.mem.indexOf(u8, answer.response, "\r\n\r\n").? + 4 ..];
    try testing.expect(body.len < test_css.len);
    try testing.expectEqual(@as(u8, 0x1f), body[0]);
    try testing.expectEqual(@as(u8, 0x8b), body[1]);
}

test "a client that says nothing gets the file as it is, and still gets Vary" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    // Said even though the plain copy is the one going out: a shared cache
    // that stored this without it would hand it to every client after,
    // including the ones that could have had the small one.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Accept-Encoding") != null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css));
}

test "a CORS Vary and a compression Vary are both sent, not one over the other" {
    // The two layers each name a different header the response was chosen
    // by, and `setHeader` used to treat the second as somebody changing
    // their mind about the first. A shared cache that stored this with only
    // `Accept-Encoding` on it would hand one origin's response to another
    // (`http1.repeats`).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(cors.with(.{ .origins = &.{"https://example.com"} }));
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{.{
        .url = "/app.css",
        .bytes = test_css,
        .content_type = "text/css",
    }}));
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Origin") != null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary: Accept-Encoding") != null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding: gzip") != null);
}

test "a client that refuses gzip with q=0 is not sent gzip" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip;q=0\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css));
}

test "the ETag of one representation does not answer for the other" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    // Collect both tags, from the two answers that carry them.
    var plain_buf: [128]u8 = undefined;
    const plain = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\n\r\n");
    const plain_etag = try dupeHeader(&plain_buf, plain.response, "ETag");

    var gz_buf: [128]u8 = undefined;
    const gz = h.send(&app, "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    const gz_etag = try dupeHeader(&gz_buf, gz.response, "ETag");

    try testing.expect(!std.mem.eql(u8, plain_etag, gz_etag));

    // Each tag is a 304 for its own representation.
    var buf: [512]u8 = undefined;
    const plain_again = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nIf-None-Match: {s}\r\n\r\n",
        .{plain_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, plain_again.response, "HTTP/1.1 304"));

    const gz_again = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nIf-None-Match: {s}\r\n\r\n",
        .{gz_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, gz_again.response, "HTTP/1.1 304"));

    // And neither is a 304 for the other. This is the failure the two tags
    // exist to prevent: a client holding the plain copy, now asking for
    // gzip, must be sent gzip rather than told what it has is current.
    const crossed = h.send(&app, try std.fmt.bufPrint(
        &buf,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nIf-None-Match: {s}\r\n\r\n",
        .{plain_etag},
    ));
    try testing.expect(std.mem.startsWith(u8, crossed.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, crossed.response, "Content-Encoding: gzip") != null);
}

test "a range is served from the plain file even when gzip was offered" {
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    var h = Harness.init();
    defer h.deinit();

    // A range is an offset into a representation. Answering with gzipped
    // bytes would hand back the wrong ones, silently.
    const answer = h.send(
        &app,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nRange: bytes=0-4\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 206"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css[0..5]));
}

test "response compression leaves a static range as the plain bytes it names" {
    // Static files answer through `Ctx.send`, the same door compression sits
    // in. A 206 gzipped there carries a Content-Range counted in plain bytes
    // over a body that is not them.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.compress(.{ .min_bytes = 1 });
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{.{
        .url = "/app.css",
        .bytes = test_css,
        .content_type = "text/css",
    }}));
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(
        &app,
        "GET /app.css HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\nRange: bytes=0-1999\r\n\r\n",
    );
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 206"));
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, test_css[0..2000]));
}

test "response compression does not gzip a static file that has no gzipped copy" {
    // Too short for a copy at load, long enough for `min_bytes`. Gzipped per
    // request it would go out under the plain file's strong ETag, and a
    // cache holding it could hand gzip to a client that cannot read it.
    const text = repeat("plain text that was not worth a gzipped copy at load. ", 10);
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.compress(.{ .min_bytes = 16 });
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{.{
        .url = "/notes.txt",
        .bytes = text,
        .content_type = "text/plain",
    }}));
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    var plain_buf: [128]u8 = undefined;
    const plain = h.send(&app, "GET /notes.txt HTTP/1.1\r\nHost: t\r\n\r\n");
    const plain_etag = try dupeHeader(&plain_buf, plain.response, "ETag");

    var offered_buf: [128]u8 = undefined;
    const offered = h.send(&app, "GET /notes.txt HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, offered.response, "Content-Encoding") == null);
    try testing.expect(std.mem.endsWith(u8, offered.response, text));
    try testing.expectEqualStrings(plain_etag, try dupeHeader(&offered_buf, offered.response, "ETag"));
}

test "a file too small to be worth gzipping has one representation and no Vary" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{.{
        .url = "/hi.txt",
        .bytes = "hello",
        .content_type = "text/plain",
    }}));
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const answer = h.send(&app, "GET /hi.txt HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "Content-Encoding") == null);
    try testing.expect(std.mem.indexOf(u8, answer.response, "Vary") == null);
    try testing.expect(std.mem.endsWith(u8, answer.response, "hello"));
}

/// A response header, copied out of the raw answer into `buf` so it can
/// outlive the harness buffer the next request will overwrite.
fn dupeHeader(buf: []u8, response: []const u8, name: []const u8) ![]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoHead;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len > buf.len) return error.NoRoom;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }
    return error.NoSuchHeader;
}

// The static half of the budget above. A compressed asset carries five
// response headers where a plain one carried three, and five is the number
// `inline_headers` was raised past — so this is what says the extra two did
// not quietly become an allocation on the path every asset goes down.
test "serving a gzipped static file allocates nothing, middleware included" {
    // Middleware in front of it, deliberately — this test used to leave it
    // out and say so, because a path that matched no route built its chain
    // out of the request arena and that one allocation would have hidden
    // what the test was measuring. Leaving it out meant the shape nearly
    // every app deploys — assets behind a logger — was the one shape the
    // allocation budget never checked. The chains are resolved at
    // `listen()` now, per file, so this is the case that proves it.
    var app = try cssApp(testing.allocator);
    defer app.deinit();

    // One global and one scoped somewhere else, so the chain is a genuine
    // filter of the registrations rather than all of them.
    try app.use(passThrough);
    try app.useOn("/api", passThrough);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [8192]u8 = undefined;

    const request = "GET /app.css HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Accept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";

    const send = struct {
        fn once(a: *App, gpa: std.mem.Allocator, l: *str_mod.Lifetime, f: *fail.InFlight, b: []u8) void {
            var in = std.Io.Reader.fixed(request);
            var out = std.Io.Writer.fixed(b);
            _ = a.handleRequest(gpa, l, f, &in, &out, .off, .off, .{});
            l.end();
        }
    }.once;

    for (0..3) |_| {
        send(&app, counting.allocator(), &lifetime, &in_flight, &buf);
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    pass_through_runs = 0;
    send(&app, counting.allocator(), &lifetime, &in_flight, &buf);

    // The global one, and not the one scoped to `/api`.
    try testing.expectEqual(@as(usize, 1), pass_through_runs);

    // Zero, not one: the bytes were compressed when the App was built and
    // the body going out is a slice of them. Nothing is serialised, nothing
    // is copied, the five headers fit in the Ctx, and the chain the
    // middleware runs in was worked out before the socket opened.
    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

test "a middleware scoped below a static prefix still runs, and still costs nothing" {
    // The case that decided this is resolved per file rather than per set.
    // A set has one prefix, so one chain for the whole of it would be the
    // chain for `/assets` — and this middleware, scoped underneath, would
    // never run. Getting that wrong is silent, and it is silent in the
    // direction of not running somebody's auth.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.static_sets.append(testing.allocator, try static_mod.fromMemory(testing.allocator, &.{
        .{ .url = "/assets/open.css", .bytes = test_css, .content_type = "text/css" },
        .{ .url = "/assets/private/secret.css", .bytes = test_css, .content_type = "text/css" },
    }));
    try app.useOn("/assets/private", rejectingMiddleware);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    const open = h.send(&app, "GET /assets/open.css HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, open.response, "HTTP/1.1 200"));

    const shut = h.send(&app, "GET /assets/private/secret.css HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, shut.response, "HTTP/1.1 401"));
}

// ---- cookies, forms and redirects, down the real request path ----
//
// Each of the three has its own module and its own tests; what these are
// for is the wiring — that a cookie survives the head being parsed, that a
// form is read out of a body the connection really delivered, and that a
// redirect's Location comes out of the same header machinery everything
// else uses.

fn echoCookie(c: *Ctx) anyerror!void {
    const session = c.cookie("session") orelse
        return c.sendText(200, "no cookie");
    try c.sendText(200, session.view());
}

test "a cookie is read out of the head the connection delivered" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nCookie: theme=dark; session=abc123\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "abc123"));

    // A request carrying no cookie at all takes the other branch rather
    // than reading somebody else's head.
    const bare = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, bare.response, "no cookie"));
}

test "a cookie split across two Cookie headers is still found" {
    // What an HTTP/2 client's request looks like once a proxy has turned it
    // back into HTTP/1.1.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /me HTTP/1.1\r\nHost: t\r\nCookie: theme=dark\r\nCookie: session=abc123\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, answer.response, "abc123"));
}

test "reading a cookie allocates nothing" {
    // The claim `Ctx.cookie` makes: the header is walked where it lies, so a
    // request that carries cookies costs the same as one that does not
    // (ADR 017's hard invariant, ADR 029).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", echoCookie);
    try app.resolveChains();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;

    const request = "GET /me HTTP/1.1\r\nHost: example.dev\r\n" ++
        "Cookie: theme=dark; lang=id; session=abc123; consent=yes\r\n\r\n";

    for (0..3) |_| {
        var warm_in = std.Io.Reader.fixed(request);
        var warm_out = std.Io.Writer.fixed(&buf);
        _ = app.handleRequest(counting.allocator(), &lifetime, &in_flight, &warm_in, &warm_out, .off, .off, .{});
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }

    counting.reset();
    var in = std.Io.Reader.fixed(request);
    var out = std.Io.Writer.fixed(&buf);
    _ = app.handleRequest(counting.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});

    try testing.expectEqual(@as(usize, 0), counting.allocs);
}

fn answersWithEntropy(c: *Ctx) anyerror!void {
    const first = try c.entropy(16);
    const second = try c.entropy(16);
    const zeroes = @as([16]u8, @splat(0));

    if (std.mem.eql(u8, &first, &second)) return c.sendText(500, "twice the same");
    if (std.mem.eql(u8, &first, &zeroes)) return c.sendText(500, "all zero");
    try c.sendText(200, "unguessable");
}

test "a handler can ask for entropy, and gets different bytes every time" {
    // Driven through a whole request rather than called directly, because
    // what is being checked is that the Bulkhead answers at all outside a
    // running server — a handler is an ordinary function and this suite has
    // no Engine under it (ADR 042). Two readings rather than one, because
    // a source that is broken open answers zeroes and a source that is
    // broken shut answers the same bytes twice; neither would fail a test
    // that only looked at the length.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/token", answersWithEntropy);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/token");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("unguessable", answer.body);
}

fn setsTwoCookies(c: *Ctx) anyerror!void {
    try c.setCookie(.{ .name = "session", .value = "abc123" });
    try c.setCookie(.{ .name = "theme", .value = "dark", .http_only = false, .secure = false });
    try c.sendEmpty(200);
}

test "two cookies are two Set-Cookie lines, not one replacing the other" {
    // The reason `http1.repeats` exists. Every other header replaces on a
    // second `setHeader`, and applying that rule here would have delivered
    // only the theme — silently, and only in the case where a login sets a
    // session alongside anything else.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/sign-in", setsTwoCookies);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/sign-in");
    try testing.expectEqual(@as(usize, 2), answer.headerCount("Set-Cookie"));
    try testing.expectEqualStrings(
        "session=abc123; Path=/; Secure; HttpOnly; SameSite=Lax",
        answer.setCookie("session").?,
    );
    try testing.expectEqualStrings("theme=dark; Path=/; SameSite=Lax", answer.setCookie("theme").?);
}

fn signsOut(c: *Ctx) anyerror!void {
    try c.clearCookie(.{ .name = "session" });
    try c.sendEmpty(204);
}

test "clearing a cookie sends one that has already expired" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-out", signsOut);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.post(&app, "/sign-out", "");
    try testing.expectEqual(@as(u16, 204), answer.status);
    const line = answer.setCookie("session").?;
    try testing.expect(std.mem.indexOf(u8, line, "Max-Age=0") != null);
    try testing.expect(std.mem.indexOf(u8, line, "Expires=Thu, 01 Jan 1970") != null);
}

fn setsASmuggledCookie(c: *Ctx) anyerror!void {
    // A value assembled from something the request supplied, which is how
    // this happens for real.
    try c.setCookie(.{ .name = "session", .value = "abc; Path=/admin" });
    try c.sendEmpty(200);
}

test "a cookie value that would smuggle an attribute is refused, not escaped" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/bad", setsASmuggledCookie);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /bad HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 500"));
    try testing.expect(try Harness.saysFailure(answer.response, "holds a character a cookie value cannot"));
    // And nothing went out with it.
    try testing.expect(std.mem.indexOf(u8, answer.response, "Set-Cookie") == null);
}

const SignIn = struct {
    email: Str,
    password: Str,
    remember: bool = false,
};

fn signIn(incoming: form_mod.Form(SignIn)) !redirect_mod.Redirect(303) {
    if (!incoming.value.email.eql("wati@example.dev")) {
        return fail.unauthorized("no such account", .{});
    }
    return .with("/welcome", .of(&.{
        .{ .name = "Set-Cookie", .value = "session=abc123; Path=/; HttpOnly" },
    }));
}

test "a urlencoded form reaches a typed handler, and its redirect carries the cookie" {
    // The whole shape of a sign-in, which is what these three features were
    // added for: a form in, a session cookie out, and a 303 so the browser's
    // reload does not post the form again.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/sign-in",
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&password=hunter2&remember=true",
    );
    try testing.expectEqual(@as(u16, 303), answer.status);
    try testing.expectEqualStrings("/welcome", answer.header("Location").?);
    try testing.expectEqualStrings("session=abc123; Path=/; HttpOnly", answer.setCookie("session").?);
    // A redirect has no body to read.
    try testing.expectEqualStrings("", answer.body);
}

test "a form that does not fit is a 400 naming the field, like a query param" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const missing = h.send(&app, "POST /sign-in HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 24\r\n\r\n" ++
        "email=wati%40example.dev");
    try testing.expect(std.mem.startsWith(u8, missing.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(missing.response, "the form is missing \"password\""));

    const wrong_type = h.send(&app, "POST /sign-in HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, wrong_type.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(wrong_type.response, "this endpoint takes a form"));
}

const Filters = struct {
    age: ?u32 = null,
    page: u32 = 1,
    sort: ?Sort = null,
    note: ?Str = null,
};

fn filtersAnswer(arena: std.mem.Allocator, f: Filters) ![]const u8 {
    const age: i64 = if (f.age) |a| a else -1;
    const note = if (f.note) |n| n.view() else "(none)";
    const sort = if (f.sort) |s| @tagName(s) else "(none)";
    return std.fmt.allocPrint(arena, "age={d} page={d} sort={s} note=[{s}]", .{ age, f.page, sort, note });
}

fn filtersFromForm(arena: std.mem.Allocator, in: form_mod.Form(Filters)) ![]const u8 {
    return filtersAnswer(arena, in.value);
}

fn filtersFromBoundForm(arena: std.mem.Allocator, b: bound_mod.Bound(form_mod.Form(Filters))) ![]const u8 {
    return filtersAnswer(arena, b.value() orelse return b.fail());
}

fn filtersFromQuery(arena: std.mem.Allocator, q: typed.Query(Filters)) ![]const u8 {
    return filtersAnswer(arena, q.value);
}

fn filtersFromBoundQuery(arena: std.mem.Allocator, b: bound_mod.Bound(typed.Query(Filters))) ![]const u8 {
    return filtersAnswer(arena, b.value() orelse return b.fail());
}

test "a box left blank is a field not given, where blank is not a value of its type" {
    // A browser sends an empty text box as `age=`, not as nothing. That was a
    // 400 saying an optional age has to be a whole number, on the first form
    // anybody submitted without filling in every box.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/form", filtersFromForm);
    try app.post("/bound-form", filtersFromBoundForm);
    try app.get("/query", filtersFromQuery);
    try app.get("/bound-query", filtersFromBoundQuery);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const blank = "age=&page=&sort=&note=";
    // An empty `?Str` keeps its empty text: blank is a value of text.
    const expected = "age=-1 page=1 sort=(none) note=[]";
    for ([_][]const u8{ "/form", "/bound-form" }) |path| {
        const answer = try client.postWith(&app, path, "application/x-www-form-urlencoded", blank);
        try testing.expectEqual(@as(u16, 200), answer.status);
        try testing.expectEqualStrings(expected, answer.body);
    }
    for ([_][]const u8{ "/query?" ++ blank, "/bound-query?" ++ blank }) |path| {
        const answer = try client.get(&app, path);
        try testing.expectEqual(@as(u16, 200), answer.status);
        try testing.expectEqualStrings(expected, answer.body);
    }

    // A value that is there and wrong is still wrong.
    const wrong = try client.get(&app, "/query?age=soon");
    try testing.expectEqual(@as(u16, 400), wrong.status);

    // And a field that has to be given has to be given something.
    try app.post("/register", register);
    const required = try client.postWith(&app, "/register", "application/x-www-form-urlencoded", "email=a%40b.c&age=");
    try testing.expectEqual(@as(u16, 422), required.status);
}

// ---- `?T` with no default is optional in every slot (ADR 030, ADR 011) ----

/// Whether an answer's failure sentence holds `wanted`, read off the JSON
/// the client got back.
fn answerSays(answer: nilo_testing.Answer, wanted: []const u8) !bool {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, answer.body, .{});
    defer parsed.deinit();
    const message = (parsed.value.object.get("error") orelse return false).string;
    return std.mem.indexOf(u8, message, wanted) != null;
}

const Contact = struct {
    name: Str,
    nickname: ?Str,
    age: ?u32,
};

fn contactAnswer(arena: std.mem.Allocator, c: Contact) ![]const u8 {
    const nickname = if (c.nickname) |n| n.view() else "(none)";
    const age: i64 = if (c.age) |a| a else -1;
    return std.fmt.allocPrint(arena, "name={s} nickname={s} age={d}", .{ c.name.view(), nickname, age });
}

fn contactFromQuery(arena: std.mem.Allocator, q: typed.Query(Contact)) ![]const u8 {
    return contactAnswer(arena, q.value);
}

fn contactFromForm(arena: std.mem.Allocator, f: form_mod.Form(Contact)) ![]const u8 {
    return contactAnswer(arena, f.value);
}

fn contactFromJson(arena: std.mem.Allocator, c: Contact) ![]const u8 {
    return contactAnswer(arena, c);
}

fn contactFromBoundJson(arena: std.mem.Allocator, b: bound_mod.Bound(Contact)) ![]const u8 {
    return contactAnswer(arena, b.value() orelse return b.fail());
}

test "a ?T with no default is null when absent in a query, a form and a JSON body alike" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/query", contactFromQuery);
    try app.post("/form", contactFromForm);
    try app.post("/json", contactFromJson);
    try app.post("/bound", contactFromBoundJson);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const expected = "name=wati nickname=(none) age=-1";
    const from_query = try client.get(&app, "/query?name=wati");
    try testing.expectEqual(@as(u16, 200), from_query.status);
    try testing.expectEqualStrings(expected, from_query.body);

    const from_form = try client.postWith(&app, "/form", "application/x-www-form-urlencoded", "name=wati");
    try testing.expectEqual(@as(u16, 200), from_form.status);
    try testing.expectEqualStrings(expected, from_form.body);

    for ([_][]const u8{ "/json", "/bound" }) |path| {
        const from_json = try client.postWith(&app, path, "application/json", "{\"name\":\"wati\"}");
        try testing.expectEqual(@as(u16, 200), from_json.status);
        try testing.expectEqualStrings(expected, from_json.body);

        // Sent as null is the same null, and sent with a value is that value.
        const null_sent = try client.postWith(&app, path, "application/json", "{\"name\":\"wati\",\"age\":null}");
        try testing.expectEqualStrings(expected, null_sent.body);
        const given = try client.postWith(&app, path, "application/json", "{\"name\":\"wati\",\"age\":7}");
        try testing.expectEqualStrings("name=wati nickname=(none) age=7", given.body);
    }

    // The field that has no `?` and no default is still the client's to send.
    const unnamed = try client.postWith(&app, "/json", "application/json", "{\"age\":7}");
    try testing.expectEqual(@as(u16, 400), unnamed.status);
    try testing.expect(try answerSays(unnamed, "the request body is missing \"name\" (text)"));
}

const Dropoff = struct { street: Str, unit: ?Str };
const Parcel = struct { to: Str, address: Dropoff, extras: []const Dropoff = &.{} };

fn parcelAnswer(p: Parcel) !struct { to: []const u8, unit: ?[]const u8, extras: usize } {
    return .{
        .to = p.to.view(),
        .unit = if (p.address.unit) |u| u.view() else null,
        .extras = p.extras.len,
    };
}

test "a ?T with no default is absent inside a nested object and a list of them" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/parcel", parcelAnswer);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const nested = try client.postWith(
        &app,
        "/parcel",
        "application/json",
        "{\"to\":\"wati\",\"address\":{\"street\":\"Jl. Braga\"},\"extras\":[{\"street\":\"a\"},{\"street\":\"b\",\"unit\":\"4\"}]}",
    );
    try testing.expectEqual(@as(u16, 200), nested.status);
    try testing.expectEqualStrings("{\"to\":\"wati\",\"unit\":null,\"extras\":2}", nested.body);

    // What the inside of an object lacks is still named, with its path.
    const lacking = try client.postWith(&app, "/parcel", "application/json", "{\"to\":\"wati\",\"address\":{\"unit\":\"4\"}}");
    try testing.expectEqual(@as(u16, 400), lacking.status);
    try testing.expect(try answerSays(lacking, "the request body is missing \"address.street\" (text)"));
}

test "a body that is wrong somewhere else never calls an absent ?T missing" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/json", contactFromJson);
    try app.post("/bound", contactFromBoundJson);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // The plain 400 names the field that is wrong, and the typo's sentence
    // lists the ones that may be left out.
    const wrong = try client.postWith(&app, "/json", "application/json", "{\"name\":\"wati\",\"age\":\"soon\"}");
    try testing.expectEqual(@as(u16, 400), wrong.status);
    try testing.expect(try answerSays(wrong, "\"age\" has to be a whole number"));
    const typo = try client.postWith(&app, "/json", "application/json", "{\"nme\":\"wati\"}");
    try testing.expect(try answerSays(typo, "It takes: name, nickname (optional), age (optional)"));

    // A binding collects the fields that did not bind, and an absent ?T is
    // not one of them.
    const bound = try client.postWith(&app, "/bound", "application/json", "{\"age\":\"soon\"}");
    try testing.expectEqual(@as(u16, 422), bound.status);
    try testing.expect(try answerSays(bound, "2 fields did not fit"));
    try testing.expect(try answerSays(bound, "the request body is missing \"name\" (text)"));
    try testing.expect(try answerSays(bound, "\"age\" has to be a whole number"));
    try testing.expect(std.mem.indexOf(u8, bound.body, "nickname") == null);

    // The same, with the field that is wrong inside an object that lacks a ?T.
    try app.post("/parcel", parcelAnswer);
    const inside = try client.postWith(
        &app,
        "/parcel",
        "application/json",
        "{\"to\":\"wati\",\"address\":{\"street\":\"Jl. Braga\"},\"extras\":{}}",
    );
    try testing.expectEqual(@as(u16, 400), inside.status);
    try testing.expect(try answerSays(inside, "\"extras\" has to be a list, not an object"));
}

test "the document says a ?T with no default may be left out of a query and a body alike" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/query", contactFromQuery);
    try app.post("/json", contactFromJson);

    const json = try docsFor(&app);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();

    const params = parsed.value.object.get("paths").?.object
        .get("/query").?.object.get("get").?.object.get("parameters").?.array.items;
    try testing.expect(params[0].object.get("required").?.bool);
    try testing.expect(!params[1].object.get("required").?.bool);
    try testing.expect(!params[2].object.get("required").?.bool);

    const required = parsed.value.object.get("components").?.object.get("schemas").?.object
        .get("Contact").?.object.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 1), required.len);
    try testing.expectEqualStrings("name", required[0].string);
}

// ---- request ids ----

const logger_mod = @import("logger.zig");

fn echoesItsRequestId(c: *Ctx) ![]const u8 {
    return c.requestId().view();
}

test "a request with no id of its own is given one, and told which" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));

    // Sixteen hex characters, and the handler and the response header agree
    // about which — one id per request, worked out once.
    const sent = sentHeader(answer.response, "X-Request-Id").?;
    try testing.expectEqual(@as(usize, 16), sent.len);
    for (sent) |ch| try testing.expect(std.ascii.isHex(ch));
    try testing.expect(std.mem.endsWith(u8, answer.response, sent));
}

test "an id from the proxy in front is adopted rather than replaced" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nX-Request-Id: 2f8a4c1e-5b6d\r\n\r\n");
    try testing.expectEqualStrings("2f8a4c1e-5b6d", sentHeader(answer.response, "X-Request-Id").?);
    try testing.expect(std.mem.endsWith(u8, answer.response, "2f8a4c1e-5b6d"));
}

test "an id that would smuggle something is ignored, not repeated" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.with(.{ .request_id = true }));
    try app.get("/x", echoesItsRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A header value cannot carry a bare CR or LF this far — the parser
    // stops that — so the shape that does arrive is the one with characters
    // a JSON log line or a downstream reader would take as structure.
    const answer = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nX-Request-Id: \"quoted, and long\"\r\n\r\n");
    const sent = sentHeader(answer.response, "X-Request-Id").?;
    try testing.expectEqual(@as(usize, 16), sent.len);
    for (sent) |ch| try testing.expect(std.ascii.isHex(ch));

    // And an over-long one is dropped for the same reason.
    const long = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nX-Request-Id: " ++ (&@as([65]u8, @splat('a'))) ++ "\r\n\r\n");
    try testing.expectEqual(@as(usize, 16), sentHeader(long.response, "X-Request-Id").?.len);
}

fn echoesItsErasedRequestId(c: *Ctx) ![]const u8 {
    // What a reaction behind a function pointer sees, and what `nilo_fetch`
    // reads by declaration: the same id, through the erasure (ADR 158).
    var erased = str_mod.AnyScope.of(c);
    const id = erased.requestId() orelse return error.NoRequestId;
    return id.view();
}

test "an erased Scope made from a request carries the request's id" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/x", echoesItsErasedRequestId);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const given = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nX-Request-Id: abc-123\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, given.response, "abc-123"));
    // No id sent: the one nilo mints, which is the same one `c.requestId()`
    // would answer, sixteen hex digits.
    const minted = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    const body = minted.response[minted.response.len - 16 ..];
    for (body) |ch| try testing.expect(std.ascii.isHex(ch));
}

/// The far side of a function pointer: what `TokenHolder` the request
/// resolved, or `NotGiven` (ADR 144).
const Reaction = *const fn (scope: *str_mod.AnyScope) anyerror![]const u8;
fn tokenBehindThePointer(scope: *str_mod.AnyScope) anyerror![]const u8 {
    const holder = scope.resolve(TokenHolder) catch |err| return @errorName(err);
    return holder.token.view();
}

fn resolvedThenErased(holder: TokenHolder, c: *Ctx) ![]const u8 {
    // A handler that took the value already resolved it; the erasure reads
    // it through by name, and hands it to a reaction that holds no `*Ctx`.
    _ = holder;
    var erased = str_mod.AnyScope.of(c);
    const react: Reaction = tokenBehindThePointer;
    return react(&erased);
}

fn erasedBeforeResolving(c: *Ctx) ![]const u8 {
    // Nothing asked for the value, so the erasure has nothing to answer:
    // an erased Scope cannot run a resolver, and says so.
    var erased = str_mod.AnyScope.of(c);
    const react: Reaction = tokenBehindThePointer;
    return react(&erased);
}

test "an erased Scope made from a request answers what the request resolved, and NotGiven otherwise" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/who", resolvedThenErased);
    try app.get("/nobody", erasedBeforeResolving);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const resolved = h.send(&app, "GET /who HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer t0k3n\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, resolved.response, "t0k3n"));
    const unasked = h.send(&app, "GET /nobody HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer t0k3n\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, unasked.response, "NotGiven"));
}

test "a request nobody asks about is given no id at all" {
    // The option costs a header on every response, so it is off by default
    // and `c.requestId()` is what a handler reaches for when it wants one.
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(logger_mod.standard);
    try app.get("/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, answer.response, "X-Request-Id") == null);
}

/// One response header's value, for the tests above.
fn sentHeader(response: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse response.len;
    var lines = std.mem.splitSequence(u8, response[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " ");
        }
    }
    return null;
}

// ---- a binding that hands its failures back ----

const Registration = struct {
    email: Str,
    age: u32,
    newsletter: bool = false,
};

/// The shortcut: everything or a 422 naming what went wrong.
fn register(b: bound_mod.Bound(form_mod.Form(Registration))) ![]const u8 {
    const form = b.value() orelse return b.fail();
    return form.email.view();
}

/// The other way in: the handler decides what a failure looks like, and
/// reads back the text that was typed so a page could show it again.
fn registerShowingTheForm(
    arena: std.mem.Allocator,
    b: bound_mod.Bound(form_mod.Form(Registration)),
) !struct { wrong: []const []const u8, typed_age: []const u8 } {
    var wrong: std.ArrayList([]const u8) = .empty;
    var it = b.failures();
    while (it.next()) |f| try wrong.append(arena, f.field);
    return .{ .wrong = wrong.items, .typed_age = b.given("age").view() };
}

test "a form binding hands every failed field back at once" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", register);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // Two things wrong at once. The all-or-nothing `Form(T)` would have said
    // only the first, which is the gap this exists to close.
    const answer = h.send(&app, "POST /register HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 9\r\n\r\n" ++
        "age=soon&");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer.response, "2 fields did not fit"));
    try testing.expect(try Harness.saysFailure(answer.response, "the form is missing \"email\" (text)"));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"age\" has to be a whole number, not \"soon\"",
    ));
}

test "a binding that bound answers exactly as the plain form would have" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", register);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/register",
        "application/x-www-form-urlencoded",
        "email=wati%40example.dev&age=31",
    );
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("wati@example.dev", answer.body);
}

test "a handler can answer its own way, and read back what was typed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/register", registerShowingTheForm);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.postWith(
        &app,
        "/register",
        "application/x-www-form-urlencoded",
        "age=soon",
    );
    // 200, because the handler chose to answer rather than to fail.
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "{\"wrong\":[\"email\",\"age\"],\"typed_age\":\"soon\"}",
        answer.body,
    );
}

const StageChange = struct {
    stage: patch_mod.Patch(enum { open, won, lost }) = .absent,
};

fn changeStageBound(b: bound_mod.Bound(StageChange)) ![]const u8 {
    _ = b.value() orelse return b.fail();
    return "changed";
}

test "a bound body whose Patch(Enum) field is not a choice is a 422, not a panic" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.patch("/deals/stage", changeStageBound);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "PATCH /deals/stage HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 16\r\n\r\n{\"stage\":\"nope\"}");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"stage\" is not one of the known choices (open, won, lost): \"nope\"",
    ));
}

/// The same, on a JSON body rather than a form.
const NewOrder = struct {
    reference: Str,
    quantity: u32,
    priority: enum { low, high } = .low,
};

fn placeBoundOrder(b: bound_mod.Bound(NewOrder)) ![]const u8 {
    const order = b.value() orelse return b.fail();
    return order.reference.view();
}

test "a JSON body binding names every field that did not bind" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeBoundOrder);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const body = "{\"quantity\":\"soon\",\"priority\":\"sideways\"}";
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "POST /orders HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;

    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;

    const answer = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer.response, "3 fields did not fit"));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "the request body is missing \"reference\" (text)",
    ));
    // Not `not "soon"`, the way a form would say it. In JSON a quoted value
    // is *text*, and sending text where a number belongs is a mistake about
    // the kind rather than about what the characters spell — which is the
    // sentence the body parser has always given, and this does not get to
    // reword it just because it collected several.
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"quantity\" has to be a whole number, not text",
    ));
    try testing.expect(try Harness.saysFailure(
        answer.response,
        "\"priority\" is not one of the known choices (low, high): \"sideways\"",
    ));
}

test "what leaves no binding to hand back is still a plain 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/orders", placeBoundOrder);
    try app.post("/register", register);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    // A field the endpoint has never heard of: naming the typo ends the
    // search, where "reference is missing" would not.
    const unknown = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 14\r\n\r\n" ++
        "{\"refrence\":1}");
    try testing.expect(std.mem.startsWith(u8, unknown.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(unknown.response, "a field \"refrence\" this endpoint does not know"));

    // Text that is not JSON at all is not a mistake about any one field.
    const garbage = h.send(&app, "POST /orders HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 5\r\n\r\n" ++
        "{[[[[");
    try testing.expect(std.mem.startsWith(u8, garbage.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(garbage.response, "not valid JSON"));

    // And a body that is not a form at all, on the form side.
    const not_a_form = h.send(&app, "POST /register HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    try testing.expect(std.mem.startsWith(u8, not_a_form.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(not_a_form.response, "this endpoint takes a form"));
}

const NewAvatar = struct {
    caption: Str,
    image: form_mod.Upload,
};

fn uploadAvatar(incoming: form_mod.Form(NewAvatar)) !struct {
    caption: []const u8,
    filename: []const u8,
    content_type: []const u8,
    bytes: usize,
} {
    const image = incoming.value.image;
    return .{
        .caption = incoming.value.caption.view(),
        .filename = image.filename.view(),
        .content_type = image.content_type.view(),
        .bytes = image.len(),
    };
}

test "a multipart upload reaches a typed handler with its bytes intact" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/avatars", uploadAvatar);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const body = "--X\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\nme, squinting\r\n" ++
        "--X\r\nContent-Disposition: form-data; name=\"image\"; filename=\"me.png\"\r\n" ++
        "Content-Type: image/png\r\n\r\n\x89PNG\r\n\x1a\n....\r\n" ++
        "--X--\r\n";

    const answer = try client.postWith(&app, "/avatars", "multipart/form-data; boundary=X", body);
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings(
        "{\"caption\":\"me, squinting\",\"filename\":\"me.png\"," ++
            "\"content_type\":\"image/png\",\"bytes\":12}",
        answer.body,
    );
}

test "an endpoint wanting a file, sent a form that cannot carry one, says which to send" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/avatars", uploadAvatar);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "POST /avatars HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 11\r\n\r\n" ++
        "caption=hey");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(answer.response, "has to be sent as multipart/form-data"));
}

fn redirectsItself(c: *Ctx) anyerror!void {
    try c.redirect(302, "/somewhere-else");
}

test "a *Ctx handler can redirect, and a redirect carries no body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/old", redirectsItself);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/old");
    try testing.expectEqual(@as(u16, 302), answer.status);
    try testing.expectEqualStrings("/somewhere-else", answer.header("Location").?);
    try testing.expectEqualStrings("0", answer.header("Content-Length").?);
    try testing.expectEqualStrings("", answer.body);
    // A redirect is an ordinary answer, so the connection carries on.
    try testing.expect(answer.keep_alive);
}

fn redirectsNowhere(c: *Ctx) anyerror!void {
    try c.redirect(302, "");
}

test "a redirect with nowhere to go is a 500 rather than a Location nobody can follow" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/old", redirectsNowhere);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = h.send(&app, "GET /old HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 500"));
    try testing.expect(try Harness.saysFailure(answer.response, "has to say where to"));
}

fn docsSignIn(_: form_mod.Form(SignIn)) !redirect_mod.Redirect(303) {
    return .to("/welcome");
}

fn docsUpload(_: form_mod.Form(NewAvatar)) !typed.Status(201, DocUser) {
    return .{ .value = .{ .id = 1, .name = .static("x") } };
}

test "the document says which encoding a form takes, and where a redirect sends you" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", docsSignIn);
    try app.post("/avatars", docsUpload);
    app.docs(.{ .title = "Forms" });

    // Borrowed from the App, which owns it — not a copy to free.
    const document = try docsFor(&app);

    // A form with no file in it is what a browser sends urlencoded; one with
    // a file can only be multipart, and a generated client that guessed
    // would post something the endpoint refuses.
    try testing.expect(std.mem.indexOf(u8, document, "\"application/x-www-form-urlencoded\":{\"schema\":") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"multipart/form-data\":{\"schema\":") != null);
    // The file itself is bytes, not the three-field struct carrying it.
    try testing.expect(std.mem.indexOf(u8, document, "\"image\":{\"type\":\"string\",\"format\":\"binary\"}") != null);
    // And the redirect promises the one header that makes it followable.
    try testing.expect(std.mem.indexOf(u8, document, "\"303\":{\"description\":\"the client is sent somewhere else\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "\"Location\"") != null);
    // Nothing about a JSON body, which neither of these takes.
    try testing.expect(std.mem.indexOf(u8, document, "\"requestBody\":{\"required\":true,\"content\":{\"application/json\"") == null);
}

// ---- a handler that holds its thread (ADR 013) ----
//
// The whole point of these is that the detector is watched failing, in the
// shape a person would hit it (ADR 032). They cost real milliseconds of
// wall clock, which is the price of measuring something whose unit is time.

/// Hold this thread for `ms`, the way a database driver waiting on a socket
/// would. Spelled out rather than reached for from `std`, which in Zig 0.16
/// only sleeps through an `Io` — and an `Io` is exactly the thing a handler
/// that makes this mistake does not have.
fn holdFor(ms: u64) void {
    const until = bulkhead.monotonicNanos() + ms * std.time.ns_per_ms;
    while (bulkhead.monotonicNanos() < until) {}
}

const held_ms = 30;

fn holdsTheThread(c: *Ctx) anyerror!void {
    holdFor(held_ms);
    try c.sendEmpty(200);
}

fn waitsProperly(c: *Ctx) anyerror!void {
    // The same wait, done right. With no Engine underneath, `blocking` runs
    // the call inline — so this test really does spend the 20ms on this
    // thread, and passes only because the wait is accounted for, not because
    // it did not happen.
    bulkhead.blocking(holdFor, .{held_ms});
    try c.sendEmpty(200);
}

test "a handler that blocks is caught, on the first request and with nobody else waiting" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/slow", holdsTheThread);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /slow HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

test "the same wait through nilo.blocking is not" {
    // The half that decides whether anybody keeps the detector switched on.
    // A guard that fires on correct code is a guard that gets turned off,
    // and then it is not a guard.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/slow", waitsProperly);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /slow HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

test "zero turns it off, and then even a blocking handler goes unremarked" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 0;
    try app.get("/slow", holdsTheThread);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    _ = h.send(&app, "GET /slow HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

fn streamsSlowly(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    holdFor(held_ms);
    try out.writeAll("done");
    try out.finish();
}

fn streamsProperly(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    // The same wait, done right. Every piece written closes a stretch, so the
    // 20ms here is spent on the other side of one and is nobody's handler
    // time — which is the half that decides whether the detector stays on.
    try out.writeAll("first");
    try out.flush();
    bulkhead.blocking(holdFor, .{held_ms});
    try out.writeAll("done");
    try out.finish();
}

test "a stream that blocks is caught, where it used to be excused" {
    // This test asserted the opposite until ADR 013: a stream, a body reader
    // and a WebSocket were excused entirely, so a blocking call inside one
    // was never reported — and a WebSocket loop is where it costs the most.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/feed", streamsSlowly);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /feed HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

test "and a stream that waits properly still is not" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/feed", streamsProperly);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /feed HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

fn blocksBetweenTwoWaits(c: *Ctx) anyerror!void {
    // Two stretches, each under the limit, with the whole request well over
    // it. The old metric summed elapsed-minus-parked and reported this; one
    // stretch does not, and a handler that yields every 6ms is not holding
    // its thread (ADR 013).
    for (0..4) |_| {
        bulkhead.blocking(holdFor, .{held_ms / 4});
        holdFor(held_ms / 4);
    }
    try c.sendEmpty(200);
}

test "a handler that yields between short stretches is not holding its thread" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = held_ms;
    try app.get("/chunky", blocksBetweenTwoWaits);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    _ = h.send(&app, "GET /chunky HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(before, watchdog.caught.load(.monotonic));
}

fn blocksAfterAnswering(c: *Ctx) anyerror!void {
    try c.sendEmpty(200);
    holdFor(held_ms);
}

test "work after the answer went out is still work, and still counted" {
    // Stopping the clock at the response would have been simpler and would
    // have missed a middleware that logs to a file after `next.run`, which
    // is the second most common way to block.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/late", blocksAfterAnswering);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    _ = h.send(&app, "GET /late HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

fn blocksThenFails(_: *Ctx) anyerror!void {
    holdFor(held_ms);
    return fail.notFound("nothing here", .{});
}

test "a handler that blocks and then fails is caught on the way out" {
    // Two exits from the chain, and the early one is the one a hand-written
    // pair of calls can forget.
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.limits.block_warning_ms = 10;
    try app.get("/gone", blocksThenFails);

    var h = Harness.init();
    defer h.deinit();

    const before = watchdog.caught.load(.monotonic);
    const answer = h.send(&app, "GET /gone HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 404"));
    try testing.expectEqual(before + 1, watchdog.caught.load(.monotonic));
}

fn locksAndAnswers(c: *Ctx) anyerror!void {
    var lock: bulkhead.Mutex = .init;
    try lock.lock();
    try testing.expect(!lock.tryLock());
    lock.unlock();
    try c.sendEmpty(200);
}

test "a nilo.Mutex still locks after being wrapped for the detector" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/guarded", locksAndAnswers);

    var h = Harness.init();
    defer h.deinit();
    const answer = h.send(&app, "GET /guarded HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 200"));
}

fn guard(c: *Ctx, next: mw.Next) anyerror!void {
    if (c.header("X-Operator") == null) return fail.unauthorized("sign in first", .{});
    try next.run(c);
}

fn signedIn() []const u8 {
    return "in";
}

fn signUp() []const u8 {
    return "made";
}

test "a tryRoute refused as a duplicate under without leaves the route already there guarded" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/v1");
    try v1.use(guard);
    try v1.post("/sign-in", signedIn);
    try testing.expectError(error.DuplicateRoute, v1.without(guard).tryRoute(.POST, "/sign-in", signUp));

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 401), (try client.post(&app, "/v1/sign-in", "")).status);
}

test "a tryRoute refused as a duplicate under with attaches nothing to the route already there" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try app.get("/x", plainOk);
    try testing.expectError(error.DuplicateRoute, app.with(tagOuter).tryRoute(.GET, "/x", plainOk));

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Order") == null);
}

test "a tryRoute refused for a name already taken leaves no route behind" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try app.named("whoami").get("/a", signedIn);
    try testing.expectError(error.DuplicateName, app.named("whoami").tryRoute(.GET, "/b", signedIn));

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 404), (try client.get(&app, "/b")).status);
}

test "a route can say a group's middleware does not cover it" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/v1");
    try v1.use(guard);
    try v1.get("/whoami", signedIn);

    // The whole shape this exists for: you cannot require a session to create
    // one (ADR 008). Default-deny — the guard is on the group and the route
    // says otherwise about itself.
    const open = v1.without(guard);
    try open.post("/sign-up", signUp);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    try testing.expectEqual(@as(u16, 401), (try client.get(&app, "/v1/whoami")).status);
    try testing.expectEqual(@as(u16, 200), (try client.post(&app, "/v1/sign-up", "")).status);

    // And the guard still works where it was not excused.
    const with_header = try client.send(
        &app,
        "GET /v1/whoami HTTP/1.1\r\nHost: t\r\nX-Operator: wati\r\n\r\n",
    );
    try testing.expectEqual(@as(u16, 200), with_header.status);
}

test "an exception frees one route from one middleware, and nothing else" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/v1");
    try v1.use(guard);
    const open = v1.without(guard);
    try open.post("/sign-up", signUp);
    // A sibling registered the ordinary way keeps the guard — the exception
    // is attached by the registration, not by the prefix.
    try v1.post("/invite", signUp);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();
    try testing.expectEqual(@as(u16, 200), (try client.post(&app, "/v1/sign-up", "")).status);
    try testing.expectEqual(@as(u16, 401), (try client.post(&app, "/v1/invite", "")).status);
}

fn adminOnly(c: *Ctx, next: mw.Next) anyerror!void {
    if (c.header("X-Admin") == null) return fail.forbidden("not yours to delete", .{});
    try next.run(c);
}

fn removed(id: u32) []const u8 {
    _ = id;
    return "gone";
}

fn shown(id: u32) []const u8 {
    _ = id;
    return "in";
}

test "a route can carry a middleware its neighbours do not" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // One endpoint inside a group needs a guard the rest do not. Before `with`
    // this meant a prefix invented to match only it, or a group of one
    // (ADR 099).
    const v1 = app.group("/v1");
    try v1.get("/users/:id", shown);
    try v1.with(adminOnly).delete("/users/:id", removed);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    // The sibling on the same path is untouched: this is exact, not a prefix.
    try testing.expectEqual(@as(u16, 200), (try client.get(&app, "/v1/users/7")).status);

    try testing.expectEqual(@as(u16, 403), (try client.send(
        &app,
        "DELETE /v1/users/7 HTTP/1.1\r\nHost: t\r\n\r\n",
    )).status);
    try testing.expectEqual(@as(u16, 200), (try client.send(
        &app,
        "DELETE /v1/users/7 HTTP/1.1\r\nHost: t\r\nX-Admin: wati\r\n\r\n",
    )).status);
}

test "a carried middleware runs inside the group's, whichever was written first" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    // `use` after the route, on purpose: chains are resolved at `listen()`, so
    // the order these two lines are written in still does not matter (ADR 008)
    // — and the carried one is still the inner of the two.
    const v1 = app.group("/v1");
    try v1.with(adminOnly).delete("/users/:id", removed);
    try v1.use(guard);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    // The group's guard is outermost, so its answer is the one that arrives
    // when neither header is there.
    try testing.expectEqual(@as(u16, 401), (try client.send(
        &app,
        "DELETE /v1/users/7 HTTP/1.1\r\nHost: t\r\n\r\n",
    )).status);

    // Past it, the route's own guard is what refuses.
    try testing.expectEqual(@as(u16, 403), (try client.send(
        &app,
        "DELETE /v1/users/7 HTTP/1.1\r\nHost: t\r\nX-Operator: wati\r\n\r\n",
    )).status);

    try testing.expectEqual(@as(u16, 200), (try client.send(
        &app,
        "DELETE /v1/users/7 HTTP/1.1\r\nHost: t\r\nX-Operator: wati\r\nX-Admin: wati\r\n\r\n",
    )).status);
}

test "with and without compose, and neither reaches the other's routes" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/v1");
    try v1.use(guard);
    // Excused from the group's guard, and carrying one of its own — the two
    // directions of the same question, on one route.
    try v1.without(guard).with(adminOnly).post("/sign-up", signUp);
    try v1.get("/whoami", signedIn);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    // No operator header, so the group's guard would have refused this. It was
    // excused; what refuses is the middleware the route asked for.
    try testing.expectEqual(@as(u16, 403), (try client.post(&app, "/v1/sign-up", "")).status);
    try testing.expectEqual(@as(u16, 200), (try client.send(
        &app,
        "POST /v1/sign-up HTTP/1.1\r\nHost: t\r\nX-Admin: wati\r\nContent-Length: 0\r\n\r\n",
    )).status);

    // And the neighbour has the group's guard and not the route's.
    try testing.expectEqual(@as(u16, 401), (try client.get(&app, "/v1/whoami")).status);
}

fn urlBuilder(c: *Ctx) anyerror!void {
    const where = try c.url("/users/:id/posts/:slug", .{ .id = @as(u32, 42), .slug = "a b/c" });
    try c.send(200, "text/plain", where.view());
}

test "the route table can be read from outside, and printed" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    try app.get("/users/:id", shown);
    try app.post("/users", signUp);
    const v1 = app.group("/v1");
    try v1.named("removeUser").delete("/users/:id", removed);

    // In registration order, with the joined pattern a group produced — the
    // same literal an error message would quote.
    try testing.expectEqual(@as(usize, 3), app.routes().len());
    try testing.expectEqual(http1.Method.GET, app.routes().at(0).method);
    try testing.expectEqualStrings("/users/:id", app.routes().at(0).pattern);
    try testing.expectEqualStrings("/users", app.routes().at(1).pattern);
    try testing.expectEqualStrings("/v1/users/:id", app.routes().at(2).pattern);
    try testing.expectEqual(http1.Method.DELETE, app.routes().at(2).method);
    // And the name each answers to — derived where the route said nothing,
    // given where it did — so a table keyed by it can be held against the
    // route table (ADR 162).
    try testing.expectEqualStrings("getUsersId", app.routes().at(0).name);
    try testing.expectEqualStrings("postUsers", app.routes().at(1).name);
    try testing.expectEqualStrings("removeUser", app.routes().at(2).name);

    // One log call prints the lot, which is the whole question this answers.
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}", .{app.routes()});
    try testing.expectEqualStrings(
        "  GET /users/:id\n  POST /users\n  DELETE /v1/users/:id",
        w.buffered(),
    );
}

test "a URL is built from the pattern, with every value encoded" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/build", urlBuilder);

    var client = try @import("testing.zig").Client.init(testing.allocator, .{});
    defer client.deinit();

    // The slash in the slug is a character somebody typed, so it stays inside
    // one segment rather than inventing another (ADR 100).
    const answer = try client.get(&app, "/build");
    try testing.expectEqualStrings("/users/42/posts/a%20b%2Fc", answer.body);
}

test "a group says where it is mounted, so a plugin can ask" {
    var app = App.init(testing.allocator);
    defer app.deinit();

    const v1 = app.group("/v1");
    const inner = v1.group("/admin");
    try testing.expectEqualStrings("/v1", @TypeOf(v1).mounted_at);
    try testing.expectEqualStrings("/v1/admin", @TypeOf(inner).mounted_at);
    // Including through `without`, which is a different type and the same
    // prefix.
    try testing.expectEqualStrings("/v1", @TypeOf(v1.without(guard)).mounted_at);
    // And the App answers too, so a plugin handed either can ask.
    try testing.expectEqualStrings("", App.mounted_at);
}

test "the mode nilo reads off std is the one the program was built at" {
    // Here nilo and the program are the same compilation, so what this holds
    // is the *derivation* rather than the warning: `warnIfBuiltDifferently`
    // is only ever right if `std.log.default_level` tracks the optimize mode
    // of the root (ADR 069). If a future std stops doing that, the warning
    // starts firing at everybody or at nobody, and this is what notices.
    //
    // The suite runs in Debug and ReleaseSafe, so two of the three arms are
    // covered every run.
    switch (@import("builtin").mode) {
        .debug => {
            try testing.expectEqual(std.log.Level.debug, std.log.default_level);
            try testing.expect(std.debug.runtime_safety);
            try testing.expectEqual(@as(?std.lang.Optimize, .debug), wiring.program_mode);
        },
        .safe => {
            try testing.expectEqual(std.log.Level.info, std.log.default_level);
            try testing.expect(std.debug.runtime_safety);
            try testing.expectEqual(@as(?std.lang.Optimize, .safe), wiring.program_mode);
        },
        // ReleaseFast and ReleaseSmall are one answer, which is why the
        // warning names them as a pair rather than picking one.
        .fast, .small => {
            try testing.expectEqual(std.log.Level.info, std.log.default_level);
            try testing.expect(!std.debug.runtime_safety);
            try testing.expectEqual(@as(?std.lang.Optimize, null), wiring.program_mode);
        },
    }

    // And nothing is said here, because the two agree.
    app_mod.warnIfBuiltDifferently();
}

test "the arm the suite never builds in is checked anyway" {
    // The whole point of `modeFrom` being a function. Two of these three
    // lines cannot be reached by `wiring.program_mode` in a suite that runs Debug
    // and ReleaseSafe, and the unreachable one is the one that was wrong.
    try testing.expectEqual(@as(?std.lang.Optimize, .debug), wiring.modeFrom(.debug, true));
    try testing.expectEqual(@as(?std.lang.Optimize, .safe), wiring.modeFrom(.info, true));
    try testing.expectEqual(@as(?std.lang.Optimize, null), wiring.modeFrom(.info, false));

    // And the trap itself, stated: `.info` is *every* release mode. A
    // derivation that reads the level alone answers ReleaseSafe for a
    // ReleaseFast program, which fires the warning at somebody who did it
    // right. These two must not agree.
    try testing.expect(wiring.modeFrom(.info, false) != wiring.modeFrom(.info, true));
}

// ---- a body field that parses itself (ADR 166), and a bounded integer (ADR 167) ----

/// A stand-in for `sql.Uuid`: `http/` may not import `nilo_id`, and the
/// protocol is read by name so that it need not. Three capital letters.
const Sku = struct {
    letters: [3]u8,

    pub const nilo_type_name = "Sku";
    pub const nilo_openapi = .{ .type = "string", .format = "sku" };

    pub fn nilo_parse(text: []const u8) ?Sku {
        if (text.len != 3) return null;
        for (text) |ch| if (!std.ascii.isUpper(ch)) return null;
        return .{ .letters = text[0..3].* };
    }

    pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

    pub fn jsonStringify(self: Sku, jw: anytype) !void {
        try jw.write(&self.letters);
    }
};

const NewLine = struct {
    sku: Sku,
    parent: ?Sku = null,
    also: []const Sku = &.{},
    limit: @import("within.zig").Within(1, 200) = .of(50),
};

fn addLine(body: NewLine) !struct { sku: Sku, parent: ?Sku, count: usize, limit: u8 } {
    return .{ .sku = body.sku, .parent = body.parent, .count = body.also.len, .limit = body.limit.value };
}

fn addBoundLine(b: bound_mod.Bound(NewLine)) ![]const u8 {
    const line = b.value() orelse return b.fail();
    return &line.sku.letters;
}

fn postLine(h: *Harness, app: *App, body: []const u8) []const u8 {
    var head_buf: [128]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "POST /lines HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;
    return h.send(app, request).response;
}

test "a body field that parses itself is read from the text a response writes it as" {
    // Item 64: `sql.Uuid` in a body was handed to `std.json`, which read it
    // as the `{bytes: …}` struct it is and answered 400 to the 36 characters
    // the same server writes in every response (ADR 166).
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/lines", addLine);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const ok = postLine(&h, &app, "{\"sku\":\"ABC\",\"parent\":\"XYZ\",\"also\":[\"DEF\",\"GHI\"],\"limit\":20}");
    try testing.expect(std.mem.startsWith(u8, ok, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, ok, "{\"sku\":\"ABC\",\"parent\":\"XYZ\",\"count\":2,\"limit\":20}"));

    // Absent takes the defaults; null is null.
    const bare = postLine(&h, &app, "{\"sku\":\"ABC\",\"parent\":null}");
    try testing.expect(std.mem.endsWith(u8, bare, "{\"sku\":\"ABC\",\"parent\":null,\"count\":0,\"limit\":50}"));

    // Text the type refuses is quoted back in the sentence a query value of
    // the same type gets; the wrong kind of value is named by its kind.
    const wrong_text = postLine(&h, &app, "{\"sku\":\"abc\"}");
    try testing.expect(std.mem.startsWith(u8, wrong_text, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(wrong_text, "\"sku\" has to be a Sku, not \"abc\""));

    const wrong_kind = postLine(&h, &app, "{\"sku\":{\"letters\":[65,66,67]}}");
    try testing.expect(try Harness.saysFailure(wrong_kind, "\"sku\" has to be a Sku, not an object"));

    const inside_a_list = postLine(&h, &app, "{\"sku\":\"ABC\",\"also\":[\"DEF\",\"nope\"]}");
    try testing.expect(try Harness.saysFailure(inside_a_list, "\"also[1]\" has to be a Sku, not \"nope\""));

    const missing = postLine(&h, &app, "{}");
    try testing.expect(try Harness.saysFailure(missing, "the request body is missing \"sku\" (a Sku)"));

    // A bounded integer arrives as a number, and the bound is the sentence.
    const too_many = postLine(&h, &app, "{\"sku\":\"ABC\",\"limit\":500}");
    try testing.expect(std.mem.startsWith(u8, too_many, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(too_many, "\"limit\" has to be a whole number from 1 to 200, not \"500\""));
}

test "a binding records a field that parses itself in the same words" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/lines", addBoundLine);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const answer = postLine(&h, &app, "{\"sku\":\"abc\",\"limit\":0}");
    try testing.expect(std.mem.startsWith(u8, answer, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer, "2 fields did not fit"));
    try testing.expect(try Harness.saysFailure(answer, "\"sku\" has to be a Sku, not \"abc\""));
    try testing.expect(try Harness.saysFailure(answer, "\"limit\" has to be a whole number from 1 to 200, not \"0\""));
}

const ListQuery = struct {
    limit: @import("within.zig").Within(1, 200) = .of(50),
    offset: u32 = 0,
};

fn listLines(q: typed.Query(ListQuery)) !struct { limit: u8, offset: u32 } {
    return .{ .limit = q.value.limit.value, .offset = q.value.offset };
}

// ---- text with a shape, and a struct that checks itself (ADR 193) ----

const text_mod = @import("text.zig");

fn startsWithSku(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "SKU-");
}

const SignUp = struct {
    email: text_mod.Email,
    password: text_mod.Text(.{ .min = 10, .max = 72 }),
    confirm: Str,
    sku: text_mod.Text(.{ .check = startsWithSku, .said = "has to be a SKU code" }) = .of("SKU-0"),

    pub fn nilo_check(self: SignUp, r: *bound_mod.Rules(SignUp)) void {
        r.must("confirm", self.password.eql(self.confirm.view()), "has to match the password");
    }
};

fn signUpPlain(in: form_mod.Form(SignUp)) ![]const u8 {
    return in.value.email.view();
}

fn signUpBound(b: bound_mod.Bound(form_mod.Form(SignUp))) ![]const u8 {
    const form = b.value() orelse return b.fail();
    return form.email.view();
}

fn signUpJson(in: SignUp) ![]const u8 {
    return in.email.view();
}

const Lookup = struct {
    email: text_mod.Email,
    nick: text_mod.Text(.{ .max = 8 }) = .of(""),

    pub fn nilo_check(self: Lookup, r: *bound_mod.Rules(Lookup)) void {
        r.must("nick", !self.nick.eql("root"), "is taken");
    }
};

fn lookup(q: typed.Query(Lookup)) ![]const u8 {
    return q.value.email.view();
}

fn postSignUp(h: *Harness, app: *App, path: []const u8, content_type: []const u8, body: []const u8) []const u8 {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "POST {s} HTTP/1.1\r\nHost: t\r\n" ++
        "Content-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ path, content_type, body.len }) catch unreachable;
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "{s}{s}", .{ head, body }) catch unreachable;
    return h.send(app, request).response;
}

test "a form field with a shape is refused in the form's own words, and the text is never quoted" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/plain", signUpPlain);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const form = "application/x-www-form-urlencoded";
    const ok = postSignUp(&h, &app, "/plain", form, "email=wati%40example.com&password=correct+horse&confirm=correct+horse");
    try testing.expect(std.mem.endsWith(u8, ok, "wati@example.com"));

    const short = postSignUp(&h, &app, "/plain", form, "email=wati%40example.com&password=hunter2&confirm=hunter2");
    try testing.expect(std.mem.startsWith(u8, short, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(short, "\"password\" has to be text of 10 to 72 characters, not 7"));
    try testing.expect(std.mem.indexOf(u8, short, "hunter2") == null);

    const not_an_address = postSignUp(&h, &app, "/plain", form, "email=wati&password=correct+horse&confirm=correct+horse");
    try testing.expect(std.mem.startsWith(u8, not_an_address, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(not_an_address, "\"email\" has to look like an address, not \"wati\""));

    const missing = postSignUp(&h, &app, "/plain", form, "password=correct+horse&confirm=correct+horse");
    try testing.expect(try Harness.saysFailure(missing, "the form is missing \"email\" (an email address)"));
}

test "a struct's own check refuses a plain form with a 422, after the fields have bound" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/plain", signUpPlain);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const form = "application/x-www-form-urlencoded";
    const mismatch = postSignUp(&h, &app, "/plain", form, "email=wati%40example.com&password=correct+horse&confirm=correct+hoarse");
    try testing.expect(std.mem.startsWith(u8, mismatch, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(mismatch, "\"confirm\" has to match the password"));

    // A shape failure is answered first, as a 400, and the check waits.
    const both = postSignUp(&h, &app, "/plain", form, "email=wati&password=correct+horse&confirm=correct+hoarse");
    try testing.expect(std.mem.startsWith(u8, both, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(both, "\"email\" has to look like an address"));
}

test "under Bound the shape, the check and the handler's own rule are one 422" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/bound", signUpBound);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const form = "application/x-www-form-urlencoded";
    const shapes = postSignUp(&h, &app, "/bound", form, "email=wati&password=hunter2&confirm=hunter2&sku=abc");
    try testing.expect(std.mem.startsWith(u8, shapes, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(shapes, "3 fields did not fit"));
    try testing.expect(try Harness.saysFailure(shapes, "\"email\" has to look like an address, not \"wati\""));
    try testing.expect(try Harness.saysFailure(shapes, "\"password\" has to be text of 10 to 72 characters, not 7"));
    try testing.expect(try Harness.saysFailure(shapes, "\"sku\" has to be a SKU code"));

    const rule = postSignUp(&h, &app, "/bound", form, "email=wati%40example.com&password=correct+horse&confirm=correct+hoarse");
    try testing.expect(std.mem.startsWith(u8, rule, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(rule, "\"confirm\" has to match the password"));

    const ok = postSignUp(&h, &app, "/bound", form, "email=wati%40example.com&password=correct+horse&confirm=correct+horse");
    try testing.expect(std.mem.endsWith(u8, ok, "wati@example.com"));
}

test "a JSON body holds a shaped field the same way, escapes and all" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/json", signUpJson);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const ok = postSignUp(&h, &app, "/json", "application/json", "{\"email\":\"wati\\u0040example.com\",\"password\":\"correct horse\",\"confirm\":\"correct horse\"}");
    try testing.expect(std.mem.endsWith(u8, ok, "wati@example.com"));

    const short = postSignUp(&h, &app, "/json", "application/json", "{\"email\":\"wati@example.com\",\"password\":\"hunter2\",\"confirm\":\"hunter2\"}");
    try testing.expect(std.mem.startsWith(u8, short, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(short, "\"password\" has to be text of 10 to 72 characters, not 7"));

    const mismatch = postSignUp(&h, &app, "/json", "application/json", "{\"email\":\"wati@example.com\",\"password\":\"correct horse\",\"confirm\":\"correct hoarse\"}");
    try testing.expect(std.mem.startsWith(u8, mismatch, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(mismatch, "\"confirm\" has to match the password"));
}

test "a query string reads a shaped field and runs the struct's check, and the document says the shape" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/lookup", lookup);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const ok = h.send(&app, "GET /lookup?email=wati%40example.com&nick=wati HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, ok, "wati@example.com"));

    const long = h.send(&app, "GET /lookup?email=wati%40example.com&nick=watiwatiwati HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, long, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(long, "?nick has to be text of at most 8 characters, not 12"));

    const taken = h.send(&app, "GET /lookup?email=wati%40example.com&nick=root HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, taken, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(taken, "?nick is taken"));

    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"email\",\"in\":\"query\",\"required\":true,\"schema\":{\"type\":\"string\",\"maxLength\":254,\"format\":\"email\"}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"nick\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"string\",\"maxLength\":8}}") != null);
}

test "a query field carries its bounds, and the document says them" {
    // Item 68: `limit` between 1 and 200 was two lines at the top of every
    // list handler, and the document said nothing about either (ADR 167).
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.get("/lines", listLines);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const ok = h.send(&app, "GET /lines?limit=200&offset=40 HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, ok, "{\"limit\":200,\"offset\":40}"));

    const absent = h.send(&app, "GET /lines HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.endsWith(u8, absent, "{\"limit\":50,\"offset\":0}"));

    const over = h.send(&app, "GET /lines?limit=500 HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, over, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(over, "?limit has to be a whole number from 1 to 200, not \"500\""));

    // A `u32` is already refused below zero, which is the other line every
    // list handler carried.
    const below = h.send(&app, "GET /lines?offset=-1 HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, below, "HTTP/1.1 400"));

    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"limit\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200}}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"offset\",\"in\":\"query\",\"required\":false,\"schema\":{\"type\":\"integer\",\"minimum\":0,\"maximum\":4294967295}}") != null);
}

test "a body field that parses itself is described as what it said, and so is a bounded one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    app.docs(.{});
    try app.post("/lines", addLine);
    const json = try docsFor(&app);
    try testing.expect(std.mem.indexOf(u8, json, "\"sku\":{\"type\":\"string\",\"format\":\"sku\"}") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":200}") != null);
}

// ---- a body that cannot be read to its end, and an answer given twice (the audit of `http/` at `39896d2`) ----

test "a body the client cut short is the client's fault: a 400, and the connection is closed" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", echoBody);

    var h = Harness.init();
    defer h.deinit();

    // A hundred bytes promised, ten sent, then the client closes.
    const sized = h.send(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 100\r\n\r\n0123456789");
    try testing.expect(std.mem.startsWith(u8, sized.response, "HTTP/1.1 400"));
    try testing.expect(try Harness.saysFailure(sized.response, "ended before"));
    try testing.expect(!sized.keep_alive);

    // The same inside a chunk's data, which used to be a 500 where a size
    // line cut short was already a 400.
    const chunked = h.send(
        &app,
        "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++ "a\r\n01234",
    );
    try testing.expect(std.mem.startsWith(u8, chunked.response, "HTTP/1.1 400"));
    try testing.expect(!chunked.keep_alive);

    const size_line = h.send(&app, "POST /echo HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n" ++ "a");
    try testing.expect(std.mem.startsWith(u8, size_line.response, "HTTP/1.1 400"));
    try testing.expect(!size_line.keep_alive);
}

fn bodyTwice(c: *Ctx) anyerror!void {
    // A middleware that logged the first error and carried on.
    _ = c.body() catch {};
    const again = try c.body();
    try c.sendText(200, again.view());
}

test "a gzip body that did not inflate is not handed over as the body by the second read" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/twice", bodyTwice);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(
        &app,
        "POST /twice HTTP/1.1\r\nHost: t\r\nContent-Encoding: gzip\r\n" ++
            "Content-Length: 27\r\n\r\n{\"name\":\"wati\",\"a\":1,\"b\":2}",
    );
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400"));
    try testing.expect(std.mem.indexOf(u8, result.response, "\"name\":\"wati\"") == null);
}

var second_answer: ?anyerror = null;

fn answerTwice(c: *Ctx) anyerror!void {
    try c.sendText(200, "first");
    c.sendText(500, "second") catch |err| {
        second_answer = err;
        return err;
    };
}

test "a second answer is an error, not an assert, and the first answer stands" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/twice", answerTwice);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    second_answer = null;
    const result = h.send(&app, "GET /twice HTTP/1.1\r\nHost: t\r\n\r\n");

    try testing.expectEqual(@as(?anyerror, error.AlreadyAnswered), second_answer);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200"));
    try testing.expect(std.mem.endsWith(u8, result.response, "first"));
    try testing.expect(std.mem.indexOf(u8, result.response, "second") == null);
    try testing.expect(!result.keep_alive);
}

fn storeUpload(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [64]u8 = undefined;
    var stored: u64 = 0;
    while (try incoming.read(&buf)) |part| stored += part.len;
    try c.sendJson(200, .{ .stored = stored });
}

fn pourUpload(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const total = try incoming.writeTo(&sink.writer);
    try c.sendJson(200, .{ .stored = total });
}

test "an upload read through bodyStream that the client cut short is a failure, not a whole file" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/store", storeUpload);
    try app.post("/pour", pourUpload);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();

    for ([_][]const u8{ "/store", "/pour" }) |path| {
        var request_buf: [512]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &request_buf,
            "POST {s} HTTP/1.1\r\nHost: t\r\nContent-Length: 1000\r\n\r\n{s}",
            .{ path, &@as([300]u8, @splat('x')) },
        );
        const result = h.send(&app, request);
        try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400"));
        try testing.expect(std.mem.indexOf(u8, result.response, "\"stored\"") == null);
        try testing.expect(!result.keep_alive);
    }
}

fn swallowUpload(c: *Ctx) anyerror!void {
    var incoming = try c.bodyStream();
    var buf: [64]u8 = undefined;
    // A handler that read a cut-short upload and answered anyway.
    while (incoming.read(&buf) catch null) |_| {}
    try c.sendText(200, "ok");
}

test "a cut-short upload whose error the handler swallowed still closes the connection" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/swallow", swallowUpload);
    try app.resolveChains();

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /swallow HTTP/1.1\r\nHost: t\r\nContent-Length: 1000\r\n\r\n" ++ (&@as([300]u8, @splat('x'))));
    try testing.expect(!result.keep_alive);
}

/// What the request arena was asked for across one POST of `[` repeated
/// `depth` times to `/echo`, whose handler reads a plain struct. The bytes the
/// arena was asked for, not the bytes the process held: the same instrument
/// `bench/result/http.md` reports this with.
fn arenaBytesForOpenBrackets(depth: usize) !usize {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/echo", testEchoJson);
    try app.resolveChains();
    app.limits.max_body = 2 * 1024 * 1024;

    const brackets = try testing.allocator.alloc(u8, depth);
    defer testing.allocator.free(brackets);
    @memset(brackets, '[');
    const request = try std.fmt.allocPrint(
        testing.allocator,
        "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ depth, brackets },
    );
    defer testing.allocator.free(request);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var counting = budget.Counting{ .child = arena.allocator() };
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;
    var in = std.Io.Reader.fixed(request);
    var out = std.Io.Writer.fixed(&buf);
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    _ = app.handleRequest(counting.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});
    lifetime.end();
    try testing.expect(std.mem.startsWith(u8, out.buffered(), "HTTP/1.1 400"));
    return counting.bytes;
}

test "a body that fails to parse is not read a second time to its full depth, whatever the type" {
    // A plain struct cannot nest, so `refuseTooDeep` let this through, and
    // `describeBadBody` then read it again as a `std.json.Value`, which
    // allocates for every level (ADR 226, the audit of `http/` at `39896d2`).
    const depth = 4000;
    const bytes = try arenaBytesForOpenBrackets(depth);
    // The body itself, and some room for the head and the answer.
    try testing.expect(bytes < depth + 16 * 1024);
}

// ---- numbers in a JSON body (ADR 084) ----

const Counts = struct { small: u8, whole: u32, ratio: f64 = 0 };

fn takeCounts(incoming: Counts) !struct { ratio: f64 } {
    return .{ .ratio = incoming.ratio };
}

const Wide = struct { n: u128 };

fn takeWide(incoming: Wide) !struct { ok: bool } {
    _ = incoming;
    return .{ .ok = true };
}

/// One JSON POST, answered. The body is copied after a head built here.
fn postJson(h: *Harness, app: *App, path: []const u8, body: []const u8) []const u8 {
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "POST {s} HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body },
    ) catch unreachable;
    return h.send(app, request).response;
}

test "a number in a JSON body is spelled the way a query's is" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/counts", takeCounts);
    var h = Harness.init();
    defer h.deinit();

    // std.json hands a quoted number to `parseInt` and `parseFloat`, which read
    // Zig's literal grammar: these were 10, 7 and a NaN (ADR 084).
    for ([_][]const u8{
        "{\"small\":1,\"whole\":\"1_0\"}",
        "{\"small\":1,\"whole\":\"+7\"}",
        "{\"small\":1,\"whole\":1,\"ratio\":\"nan\"}",
        "{\"small\":1,\"whole\":1,\"ratio\":\"0x1p3\"}",
        // A whole number is digits: `1e2` and `5.0` are not, in a query either.
        "{\"small\":1e2,\"whole\":1}",
        "{\"small\":5.0,\"whole\":1}",
    }) |body| {
        const response = postJson(&h, &app, "/counts", body);
        testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n")) catch |err| {
            std.debug.print("body {s}\n  got: {s}\n", .{ body, response });
            return err;
        };
    }

    // What a query takes, a body takes: digits, a quoted number, an exponent.
    for ([_][]const u8{
        "{\"small\":1,\"whole\":\"10\"}",
        "{\"small\":1,\"whole\":1,\"ratio\":1e3}",
        "{\"small\":1,\"whole\":1,\"ratio\":\"2.5\"}",
        "{\"small\":1,\"whole\":1,\"ratio\":-1.5E-3}",
    }) |body| {
        const response = postJson(&h, &app, "/counts", body);
        testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n")) catch |err| {
            std.debug.print("body {s}\n  got: {s}\n", .{ body, response });
            return err;
        };
    }
}

test "a float no float holds is refused in a body, not read as infinity" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/counts", takeCounts);
    var h = Harness.init();
    defer h.deinit();

    const response = postJson(&h, &app, "/counts", "{\"small\":1,\"whole\":1,\"ratio\":1e999}");
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(try Harness.saysFailure(response, "\"ratio\" has to be a number"));
}

test "a u128 field posted as 2e38 is a 400, not a panic inside std" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/wide", takeWide);
    var h = Harness.init();
    defer h.deinit();

    const response = postJson(&h, &app, "/wide", "{\"n\":2e38}");
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
    // The digits are what a u128 reads.
    const exact = postJson(&h, &app, "/wide", "{\"n\":200000000000000000000000000000000000000}");
    try testing.expect(std.mem.startsWith(u8, exact, "HTTP/1.1 200 OK\r\n"));
}

test "a body number that does not fit its field is a 400 naming the field" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/counts", takeCounts);
    var h = Harness.init();
    defer h.deinit();

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        .{ .body = "{\"small\":300,\"whole\":1}", .says = "\"small\" has to be a whole number, not 300" },
        .{ .body = "{\"small\":1,\"whole\":1.5}", .says = "\"whole\" has to be a whole number, not 1.5" },
        .{ .body = "{\"small\":1,\"whole\":-1}", .says = "\"whole\" has to be a whole number, not -1" },
    };
    for (cases) |case| {
        const response = postJson(&h, &app, "/counts", case.body);
        try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
        testing.expect(try Harness.saysFailure(response, case.says)) catch |err| {
            std.debug.print("body {s}\n  wanted: {s}\n  got:    {s}\n", .{ case.body, case.says, response });
            return err;
        };
    }
}

const Tally = struct { small: u8, whole: u32 };

fn placeTally(b: bound_mod.Bound(Tally)) ![]const u8 {
    _ = b.value() orelse return b.fail();
    return "ok";
}

test "under Bound a body number that does not fit is collected like any other field" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/tally", placeTally);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    var request_buf: [512]u8 = undefined;
    const body = "{\"small\":300,\"whole\":-1}";
    const request = std.fmt.bufPrint(
        &request_buf,
        "POST /tally HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    ) catch unreachable;
    const answer = h.send(&app, request);
    try testing.expect(std.mem.startsWith(u8, answer.response, "HTTP/1.1 422"));
    try testing.expect(try Harness.saysFailure(answer.response, "2 fields did not fit"));
    try testing.expect(try Harness.saysFailure(answer.response, "\"small\" has to be a whole number, not 300"));
    try testing.expect(try Harness.saysFailure(answer.response, "\"whole\" has to be a whole number, not -1"));
}

const Sketch = struct {
    shape: Shape,

    const Shape = union(enum) {
        pub const nilo_json = .{ .tag = "kind" };
        pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

        circle: struct { r: u8 },
        square: struct { side: u8 },
    };
};

fn takeSketch(incoming: Sketch) !struct { ok: bool } {
    _ = incoming;
    return .{ .ok = true };
}

test "a second discriminator in a tagged body is a 400 naming the key" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sketch", takeSketch);
    var h = Harness.init();
    defer h.deinit();

    const fine = postJson(&h, &app, "/sketch", "{\"shape\":{\"kind\":\"circle\",\"r\":3}}");
    try testing.expect(std.mem.startsWith(u8, fine, "HTTP/1.1 200 OK\r\n"));

    const twice = postJson(&h, &app, "/sketch", "{\"shape\":{\"kind\":\"circle\",\"kind\":\"square\",\"r\":3,\"side\":1}}");
    try testing.expect(std.mem.startsWith(u8, twice, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(try Harness.saysFailure(twice, "\"kind\""));
}

const Queue = struct {
    steps: []const Step,

    /// Every variant a plain struct: the tag-first reader applies.
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };
        pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

        queued,
        run: struct { pid: u8 },
    };
};

const Pairs = struct {
    steps: []const Step,

    /// A variant that is a tuple: the general reader applies.
    const Step = union(enum) {
        pub const nilo_json = .{ .tag = "signal" };
        pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

        queued,
        run: struct { u8 },
    };
};

fn takeQueue(incoming: Queue) !struct { n: usize } {
    return .{ .n = incoming.steps.len };
}

fn takePairs(incoming: Pairs) !struct { n: usize } {
    return .{ .n = incoming.steps.len };
}

test "a stray closing bracket where a tagged value should start is a 400, not an abort" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/queue", takeQueue);
    try app.post("/pairs", takePairs);
    var h = Harness.init();
    defer h.deinit();

    const bodies = [_][]const u8{
        "{\"steps\":[{\"signal\":\"queued\"},{\"signal\":\"queued\"}},{}]}",
        "{\"steps\":[{\"signal\":\"queued\"}]}",
        "{\"steps\":[{\"signal\":\"queued\"},]}",
        "{\"steps\":[{\"signal\":\"queued\"}",
        "{\"steps\":[{\"signal\":\"queued\"},}",
        "{\"steps\":[}",
    };
    for (bodies, 0..) |body, i| {
        for ([_][]const u8{ "/queue", "/pairs" }) |path| {
            const answer = postJson(&h, &app, path, body);
            // The one well-formed body is the only 200.
            const want = if (i == 1) "HTTP/1.1 200 OK\r\n" else "HTTP/1.1 400 Bad Request\r\n";
            try testing.expect(std.mem.startsWith(u8, answer, want));
        }
    }
}

// ---- a type that skips the keys it does not know (ADR 168) ----

const LooseNote = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore };
    text: Str,
};
const TightNote = struct { text: Str };
/// Tolerant itself, strict about what it holds.
const LooseOuter = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore };
    note: TightNote,
};
/// Strict itself, tolerant about what it holds.
const TightOuter = struct { note: LooseNote };

fn takeLooseNote(incoming: LooseNote) !struct { text: []const u8 } {
    return .{ .text = incoming.text.view() };
}
fn takeTightNote(incoming: TightNote) !struct { text: []const u8 } {
    return .{ .text = incoming.text.view() };
}
fn takeLooseOuter(incoming: LooseOuter) !struct { text: []const u8 } {
    return .{ .text = incoming.note.text.view() };
}
fn takeTightOuter(incoming: TightOuter) !struct { text: []const u8 } {
    return .{ .text = incoming.note.text.view() };
}

/// The whole body is a tagged union, one variant of which skips unknown keys.
const Switch = union(enum) {
    pub const nilo_json = .{ .tag = "kind" };
    pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

    loose: struct {
        pub const nilo_json = .{ .unknown_fields = .ignore };
        n: u8,
    },
    tight: struct { n: u8 },
    off,
};

/// A union is not a handler argument, so it is the whole body by `Ctx.json`.
fn takeSwitch(c: *Ctx) anyerror!void {
    const incoming = try c.json(Switch);
    try c.sendJson(200, .{ .kind = @tagName(incoming) });
}

fn postBig(h: *Harness, app: *App, path: []const u8, body: []const u8) []const u8 {
    var request_buf: [2048]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "POST {s} HTTP/1.1\r\nHost: t\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body },
    ) catch unreachable;
    return h.send(app, request).response;
}

fn expectOk(response: []const u8) !void {
    testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n")) catch |err| {
        std.debug.print("wanted 200, got: {s}\n", .{response});
        return err;
    };
}

fn expect400(response: []const u8, says: []const u8) !void {
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 400 Bad Request\r\n"));
    testing.expect(try Harness.saysFailure(response, says)) catch |err| {
        std.debug.print("  wanted: {s}\n  got:    {s}\n", .{ says, response });
        return err;
    };
}

test "a type that says .ignore reads a body with keys it has no field for" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/loose", takeLooseNote);
    try app.post("/tight", takeTightNote);
    var h = Harness.init();
    defer h.deinit();

    const body = "{\"extra\":{\"a\":[1,2,{\"b\":null}]},\"text\":\"hi\",\"also\":1}";
    const loose = postJson(&h, &app, "/loose", body);
    try expectOk(loose);
    try testing.expect(std.mem.indexOf(u8, loose, "hi") != null);

    // A type that says nothing still refuses the same body, naming the key.
    try expect400(postJson(&h, &app, "/tight", body), "a field \"extra\" this endpoint does not know. It takes: text");

    // Skipping is not leniency about what the type does know.
    try expect400(postJson(&h, &app, "/loose", "{\"extra\":1}"), "the request body is missing \"text\"");
    try expect400(postJson(&h, &app, "/loose", "{\"text\":5,\"extra\":1}"), "\"text\" has to be text, not a number");
}

test "an unknown-field opt-out applies to its own type, not to the struct holding it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/loose-outer", takeLooseOuter);
    try app.post("/tight-outer", takeTightOuter);
    var h = Harness.init();
    defer h.deinit();

    // A tolerant parent skips its own keys and still refuses its strict child's.
    try expectOk(postJson(&h, &app, "/loose-outer", "{\"extra\":1,\"note\":{\"text\":\"a\"}}"));
    try expect400(
        postJson(&h, &app, "/loose-outer", "{\"note\":{\"text\":\"a\",\"extra\":1}}"),
        "a field \"note.extra\" this endpoint does not know. It takes: text",
    );

    // A strict parent refuses its own keys and lets its tolerant child skip.
    try expectOk(postJson(&h, &app, "/tight-outer", "{\"note\":{\"text\":\"a\",\"extra\":{\"x\":1}}}"));
    try expect400(
        postJson(&h, &app, "/tight-outer", "{\"extra\":1,\"note\":{\"text\":\"a\"}}"),
        "a field \"extra\" this endpoint does not know. It takes: note",
    );
}

test "a repeated known key is still refused under .ignore" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/loose", takeLooseNote);
    var h = Harness.init();
    defer h.deinit();

    try expect400(postJson(&h, &app, "/loose", "{\"text\":\"a\",\"extra\":1,\"text\":\"b\"}"), "the key \"text\" twice");
}

test "a value skipped under .ignore is held to the depth a read body is" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/loose", takeLooseNote);
    var h = Harness.init();
    defer h.deinit();

    const shallow = "{\"text\":\"a\",\"extra\":" ++ &@as([30]u8, @splat('[')) ++ &@as([30]u8, @splat(']')) ++ "}";
    try expectOk(postBig(&h, &app, "/loose", shallow));

    const deep = "{\"text\":\"a\",\"extra\":" ++ &@as([100]u8, @splat('[')) ++ &@as([100]u8, @splat(']')) ++ "}";
    try expect400(postBig(&h, &app, "/loose", deep), "nests deeper than 64 levels");
}

test "a tagged union that is the whole body says which variant and which key is wrong" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/switch", takeSwitch);
    var h = Harness.init();
    defer h.deinit();

    try expectOk(postJson(&h, &app, "/switch", "{\"kind\":\"tight\",\"n\":1}"));
    try expectOk(postJson(&h, &app, "/switch", "{\"kind\":\"off\"}"));
    // The variant that says .ignore skips what it does not know, and the one
    // that says nothing refuses it, inside a union exactly as outside one.
    try expectOk(postJson(&h, &app, "/switch", "{\"kind\":\"loose\",\"n\":1,\"extra\":[1]}"));

    const cases = [_]struct { body: []const u8, says: []const u8 }{
        .{
            .body = "{\"n\":1}",
            .says = "the request body is missing \"kind\", which names the variant: one of loose, tight, off",
        },
        .{
            .body = "{\"kind\":\"nope\"}",
            .says = "\"kind\" is not one of the known variants (loose, tight, off): \"nope\"",
        },
        .{
            .body = "{\"kind\":7}",
            .says = "\"kind\" has to be text naming the variant, one of loose, tight, off, not a number",
        },
        .{
            .body = "{\"kind\":\"tight\",\"n\":1,\"x\":2}",
            .says = "a field \"x\" the \"tight\" variant does not know. It takes: kind, n",
        },
        .{
            .body = "{\"kind\":\"loose\"}",
            .says = "the request body is missing \"n\"",
        },
        .{
            .body = "[1]",
            .says = "the request body has to be an object whose \"kind\" is one of loose, tight, off, not a list",
        },
        .{
            .body = "",
            .says = "the request body is empty. This endpoint expects an object whose \"kind\" is one of loose, tight, off",
        },
    };
    for (cases) |case| try expect400(postJson(&h, &app, "/switch", case.body), case.says);
}

// ---- a body type that answers its wrong shape with a 422 (ADR 251) ----

/// The request a port of an axum server reads: text that is not JSON is a
/// 400, and JSON that is not this shape a 422, which is what its clients and
/// its contract tests tell apart.
const Search = struct {
    pub const nilo_json = .{ .unknown_fields = .ignore, .misfit = 422 };
    start: Str,
    shards: []const u32 = &.{},
    limit: u32 = 500,
};
/// The same fields, saying nothing: every refusal stays the 400 it was.
const PlainSearch = struct {
    start: Str,
    shards: []const u32 = &.{},
    limit: u32 = 500,
};

fn takeSearch(incoming: Search) !struct { limit: u32 } {
    return .{ .limit = incoming.limit };
}
fn takePlainSearch(incoming: PlainSearch) !struct { limit: u32 } {
    return .{ .limit = incoming.limit };
}
fn takeSearchBound(b: bound_mod.Bound(Search)) !struct { limit: u32 } {
    const incoming = b.value() orelse return b.fail();
    return .{ .limit = incoming.limit };
}

/// A tagged union as the whole body, read by `Ctx.json`, chooses the same way.
const Signal = union(enum) {
    pub const nilo_json = .{ .tag = "kind", .misfit = 422 };
    pub const jsonParse = @import("jsonmark.zig").parseFor(@This());

    metrics: struct { name: Str },
    logs,
};
fn takeSignal(c: *Ctx) anyerror!void {
    const incoming = try c.json(Signal);
    try c.sendJson(200, .{ .kind = @tagName(incoming) });
}

fn expect422(response: []const u8, says: []const u8) !void {
    testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 422 Unprocessable Content\r\n")) catch |err| {
        std.debug.print("wanted 422, got: {s}\n", .{response});
        return err;
    };
    testing.expect(try Harness.saysFailure(response, says)) catch |err| {
        std.debug.print("  wanted: {s}\n  got:    {s}\n", .{ says, response });
        return err;
    };
}

test "a body type that says .misfit = 422 answers JSON of the wrong shape with a 422 and text that is not JSON with a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/search", takeSearch);
    var h = Harness.init();
    defer h.deinit();

    try expectOk(postJson(&h, &app, "/search", "{\"start\":\"0\",\"extra\":1}"));

    // Not JSON, or nothing at all: the request is not a body of any shape.
    try expect400(postJson(&h, &app, "/search", "{\"start\":"), "the request body is not valid JSON");
    try expect400(postJson(&h, &app, "/search", "start=0"), "the request body is not valid JSON");
    try expect400(postJson(&h, &app, "/search", ""), "the request body is empty");

    // JSON, and not this shape: the same sentence the 400 carried, as a 422.
    const cases = [_]struct { body: []const u8, says: []const u8 }{
        .{ .body = "{\"limit\":5}", .says = "the request body is missing \"start\"" },
        .{ .body = "{\"start\":7}", .says = "\"start\" has to be text, not a number" },
        .{ .body = "{\"start\":\"0\",\"limit\":\"lots\"}", .says = "\"limit\" has to be a whole number" },
        .{ .body = "{\"start\":\"0\",\"shards\":[1,\"two\"]}", .says = "\"shards[1]\"" },
        .{ .body = "[]", .says = "the request body has to be a JSON object with: start" },
        .{ .body = "{\"start\":\"0\",\"start\":\"1\"}", .says = "the key \"start\" twice" },
    };
    for (cases) |case| try expect422(postJson(&h, &app, "/search", case.body), case.says);
}

test "a body type that says nothing still answers every refusal of its shape with a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/search", takePlainSearch);
    var h = Harness.init();
    defer h.deinit();

    try expect400(postJson(&h, &app, "/search", "{\"limit\":5}"), "the request body is missing \"start\"");
    try expect400(postJson(&h, &app, "/search", "{\"start\":7}"), "\"start\" has to be text, not a number");
    try expect400(postJson(&h, &app, "/search", "[]"), "the request body has to be a JSON object with: start");
    try expect400(postJson(&h, &app, "/search", "{\"start\":"), "the request body is not valid JSON");
}

test "a bound body whose type says .misfit = 422 answers the refusals it cannot collect with a 422 too" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/search", takeSearchBound);
    var h = Harness.init();
    defer h.deinit();

    // Collected, and answered by the handler's own `b.fail()`, as before.
    try expect422(postJson(&h, &app, "/search", "{\"start\":7}"), "\"start\" has to be text, not a number");
    // The hard refusals of the shape: not an object, and a mistake nested
    // inside a field, now in the status the type chose.
    try expect422(postJson(&h, &app, "/search", "[1]"), "the request body has to be a JSON object with: start");
    try expect422(postJson(&h, &app, "/search", "{\"start\":\"0\",\"shards\":[\"x\"]}"), "\"shards[0]\"");
    // And text that is not JSON stays the 400 it always was.
    try expect400(postJson(&h, &app, "/search", "nope"), "the request body is not valid JSON");
}

test "a bound body whose type ignores unknown fields collects its mistakes past a key it does not know" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/search", takeSearchBound);
    var h = Harness.init();
    defer h.deinit();

    // `Search` says `.unknown_fields = .ignore`, which the plain read
    // honoured and the binding's second read did not: it answered "has a
    // field \"extra\" this endpoint does not know" and never reached `start`.
    try expect422(postJson(&h, &app, "/search", "{\"start\":7,\"extra\":1}"), "\"start\" has to be text, not a number");
    try expectOk(postJson(&h, &app, "/search", "{\"start\":\"0\",\"extra\":1}"));
}

test "a tagged union that says .misfit = 422 answers a variant it does not know with a 422" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/signal", takeSignal);
    var h = Harness.init();
    defer h.deinit();

    try expectOk(postJson(&h, &app, "/signal", "{\"kind\":\"logs\"}"));
    try expect422(
        postJson(&h, &app, "/signal", "{\"kind\":\"traces\"}"),
        "\"kind\" is not one of the known variants (metrics, logs): \"traces\"",
    );
    try expect422(postJson(&h, &app, "/signal", "{\"kind\":\"metrics\"}"), "the request body is missing \"name\"");
    try expect400(postJson(&h, &app, "/signal", "{kind}"), "the request body is not valid JSON");
}

fn sayListener(c: *Ctx) anyerror!void {
    try c.sendText(200, if (c.listener() == 0) "first" else if (c.listener() == 1) "second" else "other");
}

/// The ADR 252 example in the guide: a route that belongs to the second
/// listener refuses a request that came in on any other.
fn onlySecondListener(c: *Ctx, next: mw.Next) anyerror!void {
    if (c.listener() != 1) return c.sendText(404, "no such route");
    try next.run(c);
}

var listener_middleware_ran: u32 = 0;

fn countRun(c: *Ctx, next: mw.Next) anyerror!void {
    listener_middleware_ran += 1;
    try next.run(c);
}

test "a request knows which listener it arrived on" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/which", sayListener);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    try testing.expect(std.mem.endsWith(u8, h.send(&app, "GET /which HTTP/1.1\r\nHost: t\r\n\r\n").response, "first"));
    h.peer.listener = 1;
    try testing.expect(std.mem.endsWith(u8, h.send(&app, "GET /which HTTP/1.1\r\nHost: t\r\n\r\n").response, "second"));
    h.peer.listener = 2;
    try testing.expect(std.mem.endsWith(u8, h.send(&app, "GET /which HTTP/1.1\r\nHost: t\r\n\r\n").response, "other"));
}

test "a middleware can refuse a route on the wrong listener" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/ingest", onlySecondListener);
    try app.get("/ingest/logs", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    h.peer.listener = 1;
    try expectOk(h.send(&app, "GET /ingest/logs HTTP/1.1\r\nHost: t\r\n\r\n").response);
    h.peer.listener = 0;
    try testing.expect(std.mem.startsWith(u8, h.send(&app, "GET /ingest/logs HTTP/1.1\r\nHost: t\r\n\r\n").response, "HTTP/1.1 404 "));
}

test "a route bound to one listener is a 404 on the other and the unbound routes answer on both" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/both", plainOk);
    try app.onListener(&.{1}).post("/v1/logs", plainOk);
    try app.group("/api").onListener(&.{0}).get("/users", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const both = "GET /both HTTP/1.1\r\nHost: t\r\n\r\n";
    const ingest = "POST /v1/logs HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n";
    const users = "GET /api/users HTTP/1.1\r\nHost: t\r\n\r\n";

    h.peer.listener = 0;
    try expectOk(h.send(&app, both).response);
    try expectOk(h.send(&app, users).response);
    // Not a 405 either: the path is spelled out by a route that is not
    // this listener's, which is a path that is not here.
    const refused = h.send(&app, ingest).response;
    try testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 404 "));
    try testing.expect(std.mem.indexOf(u8, refused, "Allow:") == null);

    h.peer.listener = 1;
    try expectOk(h.send(&app, both).response);
    try expectOk(h.send(&app, ingest).response);
    try testing.expect(std.mem.startsWith(u8, h.send(&app, users).response, "HTTP/1.1 404 "));
    // A listener past the ones the routes were bound to answers the unbound.
    h.peer.listener = 7;
    try expectOk(h.send(&app, both).response);
    try testing.expect(std.mem.startsWith(u8, h.send(&app, ingest).response, "HTTP/1.1 404 "));
}

test "a route bound to a listener never reaches its handler from another one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.useOn("/secret", countRun);
    try app.onListener(&.{1}).get("/secret/x", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    h.peer.listener = 0;
    // A 404 runs the scoped middleware like any 404 does (ADR 008), so what
    // is shown is the handler: it is never reached.
    const refused = h.send(&app, "GET /secret/x HTTP/1.1\r\nHost: t\r\n\r\n").response;
    try testing.expect(std.mem.startsWith(u8, refused, "HTTP/1.1 404 "));
    try testing.expect(!std.mem.endsWith(u8, refused, "handler"));
    h.peer.listener = 1;
    try testing.expect(std.mem.endsWith(u8, h.send(&app, "GET /secret/x HTTP/1.1\r\nHost: t\r\n\r\n").response, "handler"));
}

test "a group bound twice is bound to the listeners both name" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.onListener(&.{ 1, 2 }).onListener(&.{ 2, 3 }).get("/narrow", plainOk);

    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    for ([_]u8{ 0, 1, 2, 3 }) |l| {
        h.peer.listener = l;
        const response = h.send(&app, "GET /narrow HTTP/1.1\r\nHost: t\r\n\r\n").response;
        if (l == 2) try expectOk(response) else try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 404 "));
    }
}

// ---- holding an answer, and trailers (ADR 008, ADR 254) ----

var late_header_refused = false;

/// The half after `next.run` setting a header, which has nowhere to go.
fn lateHeader(c: *Ctx, next: mw.Next) anyerror!void {
    try next.run(c);
    late_header_refused = false;
    c.setHeader("X-Late", "1") catch |err| {
        late_header_refused = err == error.Failed;
    };
}

/// The same, holding the answer first.
fn heldHeader(c: *Ctx, next: mw.Next) anyerror!void {
    const answer = try next.hold(c);
    try answer.setHeader("Server-Timing", "app;dur=1");
}

fn heldTrailer(c: *Ctx, next: mw.Next) anyerror!void {
    const answer = try next.hold(c);
    try answer.setTrailer("Server-Timing", "app;dur=1");
}

/// What a conditional-GET middleware does: the client has this body already.
fn heldNotModified(c: *Ctx, next: mw.Next) anyerror!void {
    const answer = try next.hold(c);
    if (answer.status() == 200 and answer.body() != null) try answer.replace(304, "", "");
}

fn heldThenRefused(c: *Ctx, next: mw.Next) anyerror!void {
    _ = try next.hold(c);
    return fail.forbidden("decided after the handler", .{});
}

/// Sends from a buffer of its own and then reuses it, which a held answer
/// must not see.
fn reusesItsBuffer(c: *Ctx) anyerror!void {
    var buf = "first".*;
    try c.send(200, "text/plain", &buf);
    @memset(&buf, 'x');
}

fn streamsAndFinishes(c: *Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    try body.writeAll("piece");
    try body.finish();
}

fn sendsWithTrailer(c: *Ctx) anyerror!void {
    try c.setTrailer("Server-Timing", "db;dur=3");
    try c.send(200, "text/plain", "hi");
}

fn barredTrailer(c: *Ctx) anyerror!void {
    try c.setTrailer("Content-Type", "text/html");
    try c.send(200, "text/plain", "hi");
}

var trailer_after_end_refused = false;

fn trailerAfterEnd(c: *Ctx) anyerror!void {
    try c.send(200, "text/plain", "hi");
    trailer_after_end_refused = false;
    c.setTrailer("Server-Timing", "db;dur=3") catch |err| {
        trailer_after_end_refused = err == error.Failed;
    };
}

test "a header set after next.run is refused, where it used to be lost without a word" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(lateHeader);
    try app.get("/x", plainOk);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, result.response, "X-Late") == null);
    try testing.expect(late_header_refused);
}

test "a middleware that holds the answer adds a header after the handler ran" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldHeader);
    try app.get("/x", plainOk);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, result.response, "Server-Timing: app;dur=1\r\n") != null);
    try testing.expect(result.keep_alive);
}

/// A timing middleware that covers failures too: a failure below `hold`
/// comes back as its error, as from `run`, and a header set on the way out
/// goes on the failure's answer as on any other.
fn timingEveryAnswer(c: *Ctx, next: mw.Next) anyerror!void {
    defer c.setHeader("Server-Timing", "app;dur=1") catch {};
    _ = try next.hold(c);
}

test "a holding middleware covers App's own 404 by setting its header on the way out" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(timingEveryAnswer);
    try app.get("/x", plainOk);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /nowhere HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 "));
    try testing.expect(std.mem.indexOf(u8, result.response, "Server-Timing: app;dur=1\r\n") != null);
}

test "a held answer can be replaced, and the replacement is what goes out" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldNotModified);
    try app.get("/x", plainOk);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 304 "));
}

test "a failure after next.hold replaces the held answer and keeps the connection" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldThenRefused);
    try app.get("/x", plainOk);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 403 "));
    try testing.expect(try Harness.saysFailure(result.response, "decided after the handler"));
    try testing.expect(result.keep_alive);
}

test "a held body is copied, so a buffer the handler reuses after send does not change it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldHeader);
    try app.get("/x", reusesItsBuffer);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\nfirst"));
}

test "a held stream takes a trailer after the handler finished it" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldTrailer);
    try app.get("/x", streamsAndFinishes);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, result.response, "Transfer-Encoding: chunked\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "5\r\npiece\r\n0\r\nServer-Timing: app;dur=1\r\n\r\n"));
    try testing.expect(result.keep_alive);
}

test "a whole answer's trailers go out chunked to a client that reads them, and not to one that did not ask" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/x", sendsWithTrailer);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);

    const asked = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nTE: trailers\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, asked.response, "Transfer-Encoding: chunked\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, asked.response, "2\r\nhi\r\n0\r\nServer-Timing: db;dur=3\r\n\r\n"));

    const plain = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, plain.response, "Content-Length: 2\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain.response, "Server-Timing") == null);
}

test "a trailer RFC 9110 keeps out of trailers is refused with a sentence" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/x", barredTrailer);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 500 "));
    try testing.expect(try Harness.saysFailure(result.response, "cannot be a trailer"));
}

test "a trailer set after the body ended is refused" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/x", trailerAfterEnd);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    _ = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nTE: trailers\r\n\r\n");
    try testing.expect(trailer_after_end_refused);
}

test "a typed Response carries its trailers" {
    const Typed = struct {
        fn handler() typed.Response([]const u8) {
            return .{ .value = "hi", .trailers = .of(&.{.{ .name = "Server-Timing", .value = "db;dur=4" }}) };
        }
    };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/x", Typed.handler);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\nTE: trailers\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "0\r\nServer-Timing: db;dur=4\r\n\r\n"));
}

test "a held answer with nothing held is App's empty 200, with the held middleware's header" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldHeader);
    try app.get("/x", answersNothing);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /x HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, result.response, "Server-Timing: app;dur=1\r\n") != null);
}

test "a held static file goes out after the chain with the middleware's header" {
    var files = try TmpFiles.init(testing.allocator, &.{.{ "a.txt", "alphabet" }});
    defer files.deinit(testing.allocator);
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.use(heldHeader);
    try app.static("/", files.path);
    var h = Harness.init();
    defer h.deinit();
    try h.ready(&app);
    const result = h.send(&app, "GET /a.txt HTTP/1.1\r\nHost: t\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 "));
    try testing.expect(std.mem.indexOf(u8, result.response, "Server-Timing: app;dur=1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, result.response, "\r\n\r\nalphabet"));
}

// ---- one request, two framings (ADR 259) ----
//
// The same request over HTTP/1.1 and over HTTP/2 reaches the same route and
// gets the same answer: the status, the headers other than the ones one
// framing writes for itself (`content-length` where the body is chunked,
// `date`, `connection`), the body, and the trailers. A table of requests
// rather than a test each, because what is being held is the sameness.

var framed_db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };

fn framedWelcome(c: *Ctx) anyerror!void {
    try c.redirect(302, "/welcome");
}

fn framedTrailing(c: *Ctx) anyerror!void {
    try c.setTrailer("x-sum", "ok");
    try c.sendText(200, "body");
}

fn framedCookie(c: *Ctx) anyerror!void {
    try c.sendText(200, if (c.header("cookie")) |h| h.view() else "no cookie");
}

fn framedSize(c: *Ctx) anyerror!void {
    var buf: [20]u8 = undefined;
    try c.sendText(200, std.fmt.bufPrint(&buf, "{d}", .{(try c.body()).view().len}) catch unreachable);
}

fn framedCapped(c: *Ctx) anyerror!void {
    var incoming = c.bodyStreamWith(.{ .max_bytes = 8 }) catch
        return fail.tooLarge("that upload is bigger than this endpoint takes", .{});
    var buf: [8]u8 = undefined;
    while (try incoming.read(&buf)) |_| {}
    try c.sendText(200, "took it");
}

fn framedMedium(c: *Ctx) anyerror!void {
    try c.send(200, "text/plain", repeat("0123456789", 250));
}

/// A streamed answer, a stream that promised its length, an event stream and
/// a file, each of which is the same bytes in chunks, in frames or from a
/// descriptor (ADR 260).
fn framedStreamed(c: *Ctx) anyerror!void {
    var out = try c.stream(200, "text/plain");
    for (0..30) |i| {
        try out.print("line {d}\n", .{i});
        try out.flush();
    }
    try out.finish();
}

fn framedPromised(c: *Ctx) anyerror!void {
    var out = try c.streamWith(200, "text/plain", .{ .length = 12 });
    try out.writeAll("twelve bytes");
    try out.finish();
}

fn framedEvents(c: *Ctx) anyerror!void {
    var events = try c.events();
    try events.send(.{ .name = "tick", .data = "1" });
    try events.send(.{ .id = "2", .data = "two" });
    try events.close();
}

var framed_room: ?*room_mod.Room = null;

/// A GET never ends on either framing, so the table asks it as a HEAD, which
/// is the head both framings write for a feed without a seat.
fn framedFeed(c: *Ctx) anyerror!void {
    return c.eventsFrom(framed_room.?, .{});
}

var framed_file: ?*bulkhead.Dir = null;
/// What the file route sends: more than the 65,535 bytes a connection's
/// window starts at, and more than a buffer of the pipe's.
const framed_file_bytes = repeat("0123456789abcdefghijklmnopqrstuvwxyz", 2_000);

fn framedFile(c: *Ctx) anyerror!void {
    const file = try framed_file.?.openFile("f.bin");
    return c.sendFile(.{ .file = file, .content_type = "application/octet-stream" });
}

fn framedApp() !App {
    var app = App.init(testing.allocator);
    errdefer app.deinit();
    try app.provide(&framed_db);
    try app.get("/streamed", framedStreamed);
    try app.get("/promised", framedPromised);
    try app.get("/events", framedEvents);
    try app.get("/file", framedFile);
    try app.get("/feed", framedFeed);
    try app.use(cors.permissive);
    try app.get("/users/:id", getUser);
    try app.post("/users", createUser);
    try app.post("/sum", sumOf);
    try app.post("/math.Sums/Find", findSum);
    try app.get("/go", framedWelcome);
    try app.get("/trailing", framedTrailing);
    try app.get("/cookie", framedCookie);
    try app.post("/size", framedSize);
    try app.post("/store", storeUpload);
    try app.post("/capped", framedCapped);
    try app.get("/medium", framedMedium);
    try app.resolveChains();
    return app;
}

const Spec = struct {
    method: []const u8 = "GET",
    path: []const u8,
    fields: []const hpack.Field = &.{},
    /// What HTTP/2 sends in `fields`' place, for a request one framing
    /// spells differently: a client splits a `cookie` for compression.
    h2_fields: ?[]const hpack.Field = null,
    body: []const u8 = "",
    window: ?u32 = null,
    /// What both must say, so a table of two 404s is not a table of anything.
    status: u16,
    says: []const u8 = "",
};

const Answered = struct {
    status: u16,
    headers: []const hpack.Field,
    body: []const u8,
    trailers: []const hpack.Field,
};

/// An HTTP/1.1 answer read back into what an HTTP/2 one carries, in `a`.
fn readHttp1(a: std.mem.Allocator, response: []const u8, head_only: bool) !Answered {
    const status = try std.fmt.parseInt(u16, response[9..12], 10);
    const blank = std.mem.indexOf(u8, response, "\r\n\r\n").?;
    var headers: std.ArrayList(hpack.Field) = .empty;
    var lines = std.mem.splitSequence(u8, response[std.mem.indexOf(u8, response, "\r\n").? + 2 .. blank], "\r\n");
    var chunked = false;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':').?;
        const name = try std.ascii.allocLowerString(a, line[0..colon]);
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.mem.eql(u8, name, "transfer-encoding")) chunked = true;
        try headers.append(a, .{ .name = name, .value = value });
    }
    var rest = response[blank + 4 ..];
    if (head_only) rest = "";
    var body: std.ArrayList(u8) = .empty;
    var trailers: std.ArrayList(hpack.Field) = .empty;
    if (chunked and !head_only) {
        while (true) {
            const eol = std.mem.indexOf(u8, rest, "\r\n").?;
            const n = try std.fmt.parseInt(usize, rest[0..eol], 16);
            rest = rest[eol + 2 ..];
            if (n == 0) break;
            try body.appendSlice(a, rest[0..n]);
            rest = rest[n + 2 ..];
        }
        var tl = std.mem.splitSequence(u8, rest, "\r\n");
        while (tl.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':').?;
            try trailers.append(a, .{ .name = try std.ascii.allocLowerString(a, line[0..colon]), .value = std.mem.trim(u8, line[colon + 1 ..], " ") });
        }
    } else try body.appendSlice(a, rest);
    return .{ .status = status, .headers = headers.items, .body = body.items, .trailers = trailers.items };
}

/// Whether `name` is one only one framing writes for itself.
fn framingOwn(name: []const u8) bool {
    return std.mem.eql(u8, name, "date") or std.mem.eql(u8, name, "connection") or
        std.mem.eql(u8, name, "transfer-encoding") or std.mem.eql(u8, name, "keep-alive");
}

fn valueOf(fields: []const hpack.Field, name: []const u8) ?[]const u8 {
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

fn expectSameAnswer(app: *App, spec: Spec) !void {
    if (comptime !framing_mod.http2_built) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var text: std.Io.Writer.Allocating = .init(a);
    try text.writer.print("{s} {s} HTTP/1.1\r\nHost: localhost\r\n", .{ spec.method, spec.path });
    for (spec.fields) |f| try text.writer.print("{s}: {s}\r\n", .{ f.name, f.value });
    if (spec.body.len > 0) try text.writer.print("Content-Length: {d}\r\n", .{spec.body.len});
    try text.writer.print("\r\n{s}", .{spec.body});

    var h = Harness.init();
    defer h.deinit();
    const head_only = std.mem.eql(u8, spec.method, "HEAD");
    const one = try readHttp1(a, h.send(app, text.written()).response, head_only);

    var two = try h2test.roundTrip(app, .{
        .method = spec.method,
        .path = spec.path,
        .fields = spec.h2_fields orelse spec.fields,
        .body = spec.body,
        .frame = 7_000,
        .window = spec.window,
    });
    defer two.deinit();

    try testing.expectEqual(spec.status, one.status);
    try testing.expectEqual(one.status, two.status);
    try testing.expect(std.mem.indexOf(u8, one.body, spec.says) != null);
    try testing.expectEqualStrings(one.body, two.body);

    // Every header one says, the other says, with the same value, bar the
    // ones a framing writes for itself and a length HTTP/1.1 chunked away.
    for (one.headers) |f| {
        if (framingOwn(f.name)) continue;
        if (std.mem.eql(u8, f.name, "content-length") and valueOf(two.headers, f.name) == null) continue;
        try testing.expectEqualStrings(f.value, valueOf(two.headers, f.name) orelse {
            std.debug.print("HTTP/1.1 sent {s}, HTTP/2 did not\n", .{f.name});
            return error.HeaderMissingOnHttp2;
        });
    }
    for (two.headers) |f| {
        if (framingOwn(f.name)) continue;
        if (std.mem.eql(u8, f.name, "content-length") and valueOf(one.headers, f.name) == null) continue;
        _ = valueOf(one.headers, f.name) orelse {
            std.debug.print("HTTP/2 sent {s}, HTTP/1.1 did not\n", .{f.name});
            return error.HeaderMissingOnHttp1;
        };
    }
    try testing.expect(valueOf(two.headers, "date") != null);
    try testing.expectEqual(one.trailers.len, two.trailers.len);
    for (one.trailers) |t| try testing.expectEqualStrings(t.value, valueOf(two.trailers, t.name).?);
}

test "the same requests over HTTP/1.1 and over HTTP/2 get the same answers" {
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var app = try framedApp();
    defer app.deinit();

    const json = [_]hpack.Field{.{ .name = "content-type", .value = "application/json" }};
    const cross_origin = [_]hpack.Field{.{ .name = "origin", .value = "https://app.example" }};
    const asks_trailers = [_]hpack.Field{.{ .name = "te", .value = "trailers" }};
    const connect = [_]hpack.Field{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "connect-protocol-version", .value = "1" } };

    // A GET with a path parameter, and the two ways it can fail to be one.
    try expectSameAnswer(&app, .{ .path = "/users/7", .status = 200, .says = "wati" });
    try expectSameAnswer(&app, .{ .path = "/users/8", .status = 404, .says = "no user 8" });
    try expectSameAnswer(&app, .{ .path = "/users/seven", .status = 400 });
    try expectSameAnswer(&app, .{ .path = "/nowhere", .status = 404, .says = "there is no /nowhere" });
    try expectSameAnswer(&app, .{ .method = "DELETE", .path = "/users/7", .status = 405, .says = "not allowed" });

    // A typed body, a body that is not JSON, and one that breaks a rule.
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/sum", .fields = &json, .body = "{\"a\":1,\"b\":2}", .status = 200, .says = "{\"total\":3}" });
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/users", .fields = &json, .body = "{\"name\":", .status = 400 });
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/users", .fields = &json, .body = "{\"name\":\"\"}", .status = 422, .says = "name must not be empty" });
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/users", .fields = &json, .body = "{\"name\":\"wati\"}", .status = 201, .says = "\"id\":1" });

    // A HEAD has the head a GET would, and a middleware's headers go with it.
    try expectSameAnswer(&app, .{ .method = "HEAD", .path = "/users/7", .status = 200 });
    try expectSameAnswer(&app, .{ .path = "/users/7", .fields = &cross_origin, .status = 200, .says = "wati" });

    // Trailers, and a Connect call that fails in Connect's words.
    try expectSameAnswer(&app, .{ .path = "/trailing", .fields = &asks_trailers, .status = 200, .says = "body" });
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/math.Sums/Find", .fields = &connect, .body = "{\"a\":-2,\"b\":0}", .status = 404, .says = "\"code\":\"not_found\"" });

    // A body in several DATA frames, an answer written across several
    // windows, a cookie a client split, and a redirect.
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/size", .body = &@as([60_000]u8, @splat('x')), .status = 200, .says = "60000" });
    // A body read in pieces, as it arrives on HTTP/2 and as it is read
    // out of the buffer on HTTP/1.1, and one the route holds to a limit.
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/store", .body = &@as([60_000]u8, @splat('x')), .status = 200, .says = "\"stored\":60000" });
    try expectSameAnswer(&app, .{ .method = "POST", .path = "/capped", .body = "abcdefgh", .status = 200, .says = "took it" });
    try expectSameAnswer(&app, .{
        .method = "POST",
        .path = "/capped",
        .body = "abcdefghijklmnopqrst",
        .h2_fields = &.{.{ .name = "content-length", .value = "20" }},
        .status = 413,
        .says = "bigger than this endpoint takes",
    });
    try expectSameAnswer(&app, .{ .path = "/medium", .window = 700, .status = 200, .says = "0123456789" });
    try expectSameAnswer(&app, .{
        .path = "/cookie",
        .fields = &.{.{ .name = "cookie", .value = "a=1; b=2" }},
        .h2_fields = &.{ .{ .name = "cookie", .value = "a=1" }, .{ .name = "cookie", .value = "b=2" } },
        .status = 200,
        .says = "a=1; b=2",
    });
    try expectSameAnswer(&app, .{ .path = "/go", .status = 302 });
}

test "a streamed answer, an event stream and a file are the same over HTTP/1.1 and over HTTP/2" {
    if (comptime !framing_mod.http2_built) return error.SkipZigTest;
    const previous = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = previous;
    var tmp = nilo_testing.tmpDir();
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "f.bin", .data = framed_file_bytes });
    var path_buf: [128]u8 = undefined;
    var dir = try bulkhead.Dir.open(try tmp.path(&path_buf, ""));
    defer dir.close();
    framed_file = &dir;
    defer framed_file = null;
    var app = try framedApp();
    defer app.deinit();

    var expected_lines: std.Io.Writer.Allocating = .init(testing.allocator);
    defer expected_lines.deinit();
    for (0..30) |i| try expected_lines.writer.print("line {d}\n", .{i});

    try expectSameAnswer(&app, .{ .path = "/streamed", .status = 200, .says = expected_lines.written() });
    try expectSameAnswer(&app, .{ .path = "/streamed", .window = 100, .status = 200, .says = "line 29" });
    try expectSameAnswer(&app, .{ .method = "HEAD", .path = "/streamed", .status = 200 });
    try expectSameAnswer(&app, .{ .path = "/promised", .status = 200, .says = "twelve bytes" });
    try expectSameAnswer(&app, .{ .path = "/events", .status = 200, .says = "event: tick\ndata: 1\n\nid: 2\ndata: two\n\n" });
    var table_room = try room_mod.Room.initWith(testing.allocator, .{});
    defer table_room.deinit();
    framed_room = &table_room;
    defer framed_room = null;
    try expectSameAnswer(&app, .{ .method = "HEAD", .path = "/feed", .status = 200 });
    try expectSameAnswer(&app, .{ .path = "/file", .window = 65_535, .status = 200, .says = "0123456789abcdefghijklmnopqrstuvwxyz" });
    try expectSameAnswer(&app, .{ .method = "HEAD", .path = "/file", .status = 200 });
    try expectSameAnswer(&app, .{
        .path = "/file",
        .fields = &.{.{ .name = "range", .value = "bytes=100-90000" }},
        .window = 65_535,
        .status = 206,
        .says = "0123456789abcdefghijklmnopqrstuvwxyz",
    });
}

test "a request on HTTP/2 allocates no more than the same request on HTTP/1.1 from the second on a connection" {
    if (comptime !framing_mod.http2_built) return error.SkipZigTest;
    var db = Db{ .rows = &.{.{ .id = 7, .name = "wati" }} };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.provide(&db);
    try app.get("/users/:id", getUser);
    try app.use(cors.permissive);
    try app.resolveChains();

    // HTTP/1.1, as the budget test above measures it, counted where its
    // arena meets the general-purpose allocator: a warm arena keeps what a
    // request touched, so the second request reaches the allocator for none.
    var gpa_h1 = budget.Counting{ .child = testing.allocator };
    var arena = std.heap.ArenaAllocator.init(gpa_h1.allocator());
    defer arena.deinit();
    var lifetime = str_mod.Lifetime{};
    var in_flight = fail.InFlight{};
    var buf: [4096]u8 = undefined;
    const request = "GET /users/7 HTTP/1.1\r\nHost: example.dev\r\nUser-Agent: wrk\r\n" ++
        "Accept: */*\r\nAccept-Encoding: gzip\r\nConnection: keep-alive\r\n\r\n";
    for (0..3) |_| {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});
        lifetime.end();
        _ = arena.reset(.{ .retain_with_limit = app_mod.default_arena_keep });
    }
    gpa_h1.reset();
    {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&buf);
        _ = app.handleRequest(arena.allocator(), &lifetime, &in_flight, &in, &out, .off, .off, .{});
        lifetime.end();
    }
    const h1_allocs = gpa_h1.allocs;

    // The same request on HTTP/2: what two and twelve of them reach the
    // general-purpose allocator for differ by what ten more cost.
    //
    // Counted against a fixed buffer, fresh for each run, and not against
    // `testing.allocator`: the stream's arena asks its allocator to grow the
    // node it holds before it takes a new one, and whether that succeeds in
    // `testing.allocator` depends on where earlier tests left its buckets. A
    // fixed buffer grows the last allocation and nothing else, every time.
    const room = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(room);
    var gpa_h2 = budget.Counting{ .child = testing.allocator };
    var totals: [2]usize = undefined;
    for (&totals, [_]usize{ 2, 12 }) |*total, requests| {
        var fixed = std.heap.FixedBufferAllocator.init(room);
        gpa_h2.child = fixed.allocator();
        var client = try h2test.TestClient.init();
        defer client.deinit();
        var id: u31 = 1;
        for (0..requests) |_| {
            try h2test.requestOn(&client, id, .{ .path = "/users/7", .fields = &.{
                .{ .name = "user-agent", .value = "wrk" },
                .{ .name = "accept", .value = "*/*" },
                .{ .name = "accept-encoding", .value = "gzip" },
            } });
            id += 2;
        }
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var in: std.Io.Reader = .fixed(client.buf.written());
        var host = app.grpcHost();
        host.gpa = gpa_h2.allocator();
        gpa_h2.reset();
        @import("h2conn.zig").serveConnection(host, &in, &out.writer, .off, .off, .{});
        total.* = gpa_h2.allocs;
    }
    const per_request = (totals[1] - totals[0]) / 10;
    try testing.expectEqual(@as(usize, 0), h1_allocs);
    try testing.expect(per_request <= h1_allocs);
    try testing.expectEqual(@as(usize, 0), (totals[1] - totals[0]) % 10);
}

test "c.header finds a name whether the head is borrowed or was copied for a body, and a name that only starts like it is not it" {
    const Read = struct {
        fn run(c: *Ctx) anyerror!void {
            const wanted = if (c.header("x-wanted")) |v| v.view() else "none";
            const prefix = if (c.header("X-Want")) |v| v.view() else "none";
            const longer = if (c.header("X-Wanted-Too")) |v| v.view() else "none";
            const twice = if (c.header("X-Twice")) |v| v.view() else "none";
            var buf: [96]u8 = undefined;
            try c.sendText(200, try std.fmt.bufPrint(&buf, "{s}|{s}|{s}|{s}", .{ wanted, prefix, longer, twice }));
        }
    };

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/read", Read.run);
    try app.post("/read", Read.run);

    var h = Harness.init();
    defer h.deinit();
    const head = "/read HTTP/1.1\r\nHost: t\r\nX-Wanted-Too: b\r\nX-WANTED:  a \r\nX-Twice: 1\r\nX-Twice: 2\r\n";
    // Borrowed from the read buffer: a GET reads nothing after its head.
    const borrowed = h.send(&app, "GET " ++ head ++ "\r\n");
    try testing.expect(std.mem.endsWith(u8, borrowed.response, "a|none|b|1"));
    // Copied into the arena: a request with a body reads again.
    const kept = h.send(&app, "POST " ++ head ++ "Content-Length: 2\r\n\r\nhi");
    try testing.expect(std.mem.endsWith(u8, kept.response, "a|none|b|1"));
}

test "the head a Ctx holds ends at its blank line, over HTTP/1.1 and over HTTP/2, which is what findHeader relies on" {
    const Tail = struct {
        fn run(c: *Ctx) anyerror!void {
            const head = c._head;
            const closed = std.mem.endsWith(u8, head, "\r\n\r\n") or std.mem.endsWith(u8, head, "\n\n");
            // Nothing past the first blank line: it is the one at the end.
            const first = std.mem.indexOf(u8, head, "\r\n\r\n") orelse std.mem.indexOf(u8, head, "\n\n") orelse head.len;
            const only = first + (if (std.mem.indexOf(u8, head, "\r\n\r\n") != null) @as(usize, 4) else 2) == head.len;
            const value = if (c.header("x-wanted")) |v| v.view() else "none";
            var buf: [64]u8 = undefined;
            try c.sendText(200, try std.fmt.bufPrint(&buf, "tail {s} {s}", .{ if (closed and only) "ok" else "bad", value }));
        }
    };
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/tail", Tail.run);
    try app.post("/tail", Tail.run);

    var h = Harness.init();
    defer h.deinit();
    const got = h.send(&app, "GET /tail HTTP/1.1\r\nHost: t\r\nX-Wanted: a\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, got.response, "tail ok a"));
    const posted = h.send(&app, "POST /tail HTTP/1.1\r\nHost: t\r\nX-Wanted: a\r\nContent-Length: 17\r\n\r\nX-Wanted: b\r\n\r\nzz");
    try testing.expect(std.mem.endsWith(u8, posted.response, "tail ok a"));
    // The same route over HTTP/2, in a build that has it.
    if (comptime !framing_mod.http2_built) return;
    try expectSameAnswer(&app, .{ .path = "/tail", .fields = &.{.{ .name = "x-wanted", .value = "a" }}, .status = 200, .says = "tail ok a" });
}

/// `s` written `n` times over, at compile time: what `s ** n` said before
/// Zig 0.17 took the operator away.
fn repeat(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    // A comptime-known constant, so that `&built` is a pointer into the
    // binary and the call is as good at runtime as `**` was.
    const built = comptime blk: {
        @setEvalBranchQuota(10 * n + 1000);
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        const final = out;
        break :blk final;
    };
    return &built;
}
