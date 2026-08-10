//! App — one self-contained HTTP application: a set of routes and
//! services (middleware comes in stage 4). It wires the Bulkhead, the
//! HTTP/1.1 parser, the Router, the request arena, and Ctx into one thing.
//!
//! `handleRequest` is deliberately separate from the Engine: all it needs
//! is a `std.Io.Reader`/`Writer`, so every bit of App's HTTP behaviour can
//! be tested against in-memory buffers, without starting a server.

const std = @import("std");
const bulkhead = @import("bulkhead.zig");
const http1 = @import("http1.zig");
const router_mod = @import("router.zig");
const ctx_mod = @import("ctx.zig");
const str_mod = @import("str.zig");
const service_mod = @import("service.zig");
const typed = @import("typed.zig");
const fail = @import("fail.zig");

const Ctx = ctx_mod.Ctx;

const RESPONSE_400 = http1.staticResponse(400, "Bad Request", "text/plain", "malformed request\n", false);
const RESPONSE_431 = http1.staticResponse(431, "Request Header Fields Too Large", "text/plain", "head too long\n", false);

pub const App = struct {
    gpa: std.mem.Allocator,
    router: router_mod.Router,
    services: service_mod.Registry,
    /// The services handlers asked for, collected as routes are registered
    /// and checked once in `listen()` (ADR 0006).
    requirements: std.ArrayList(service_mod.Requirement) = .empty,

    pub fn init(gpa: std.mem.Allocator) App {
        return .{
            .gpa = gpa,
            .router = router_mod.Router.init(gpa),
            .services = service_mod.Registry.init(gpa),
        };
    }

    pub fn deinit(self: *App) void {
        self.requirements.deinit(self.gpa);
        self.services.deinit();
        self.router.deinit();
    }

    /// Register a service. `ptr` must outlive the App. Its order relative
    /// to route registration does not matter; all that matters is that it
    /// happens before `listen()`.
    pub fn provide(self: *App, ptr: anytype) !void {
        try self.services.add(ptr);
    }

    pub fn get(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.GET, pattern, handler);
    }

    pub fn post(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.POST, pattern, handler);
    }

    pub fn put(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.PUT, pattern, handler);
    }

    pub fn delete(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.DELETE, pattern, handler);
    }

    pub fn patch(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.PATCH, pattern, handler);
    }

    pub fn head(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.HEAD, pattern, handler);
    }

    pub fn options(self: *App, comptime pattern: []const u8, comptime handler: anytype) !void {
        try self.route(.OPTIONS, pattern, handler);
    }

    /// Every route registration goes through here. Whatever shape the
    /// handler has — `fn (*Ctx) !void` or a typed handler — the
    /// compile-time engine stitches it into a Ctx handler, so there is
    /// only ever one request path.
    pub fn route(
        self: *App,
        method: http1.Method,
        comptime pattern: []const u8,
        comptime handler: anytype,
    ) !void {
        try self.requirements.appendSlice(self.gpa, comptime typed.requirements(pattern, handler));
        try self.router.add(method, pattern, comptime typed.wrap(pattern, handler));
    }

    /// The first requirement that is not met, or null if every handler got
    /// what it asked for.
    pub fn missingService(self: *const App) ?service_mod.Requirement {
        for (self.requirements.items) |r| {
            if (!self.services.has(r)) return r;
        }
        return null;
    }

    /// Like `missingService`, but logs everything that is missing and then
    /// fails. Called automatically by `listen()` — this is what makes a
    /// forgotten service show up before a single request is served, rather
    /// than at three in the morning (ADR 0006).
    pub fn checkServices(self: *const App) error{MissingService}!void {
        if (self.missingService() == null) return;
        for (self.requirements.items) |r| {
            if (self.services.has(r)) continue;
            std.log.err(
                "the handler for route \"{s}\" needs service {s}{s}, which was never registered " ++
                    "— call app.provide() before app.listen()",
                .{ r.route, if (r.needs_mutable) "*" else "*const ", r.type_name },
            );
        }
        return error.MissingService;
    }

    /// Listen and serve until the process is stopped.
    pub fn listen(self: *App, options_: bulkhead.Options) !void {
        try self.checkServices();
        try bulkhead.serve(self.gpa, options_, self, handleConnection);
    }

    fn handleConnection(self: *App, in: *std.Io.Reader, out: *std.Io.Writer) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        var lifetime = str_mod.Lifetime{};

        // The fail-function Failure is bound to this fiber once, then
        // reused by every request on the same connection (ADR 0007).
        var failure = fail.Failure{};
        var binding = bulkhead.binding_unset;
        bulkhead.bindSlot(&binding, &failure);
        defer bulkhead.unbindSlot(&binding);

        while (true) {
            const keep_going = self.handleRequest(arena.allocator(), &lifetime, &failure, in, out);
            // The request is done: every Str of its goes stale, then the
            // bag is emptied in one go without giving up its capacity.
            lifetime.end();
            _ = arena.reset(.retain_capacity);
            if (!keep_going) return;
        }
    }

    /// Handle exactly one request from `in`, writing the answer to `out`.
    /// Returns true if the connection may be used for another request.
    pub fn handleRequest(
        self: *App,
        arena: std.mem.Allocator,
        lifetime: *str_mod.Lifetime,
        failure: *fail.Failure,
        in: *std.Io.Reader,
        out: *std.Io.Writer,
    ) bool {
        failure.clear();
        // On a real server the fiber slot is already installed and wins;
        // this is what keeps fail functions working when App is called
        // straight from a test, with no Engine underneath.
        const prev_slot = bulkhead.setFallbackSlot(failure);
        defer _ = bulkhead.setFallbackSlot(prev_slot);

        // The head is copied into the request arena so every Str from this
        // request stays valid even once the connection buffer is refilled
        // (when reading the body, say). One small memcpy, paid once.
        const raw_head = http1.readHead(in) catch |err| {
            switch (err) {
                error.EndOfStream, error.ReadFailed => {},
                error.HeadTooLong => sendFinal(out, RESPONSE_431),
            }
            return false;
        };
        const request_head = arena.dupe(u8, raw_head) catch return false;
        in.toss(raw_head.len);

        var r = http1.Request{};
        http1.parseHead(request_head, &r) catch {
            sendFinal(out, RESPONSE_400);
            return false;
        };

        var header_list: std.ArrayList(http1.HeaderIterator.Pair) = .empty;
        var iter = http1.HeaderIterator.from(request_head);
        while (iter.next()) |pair| header_list.append(arena, pair) catch return false;

        const qmark = std.mem.indexOfScalar(u8, r.target, '?');
        const path = if (qmark) |i| r.target[0..i] else r.target;

        var c = Ctx{
            .method = http1.methodFrom(r.method),
            ._arena = arena,
            ._lifetime = lifetime,
            ._in = in,
            ._out = out,
            ._request = &r,
            ._path = path,
            ._query = if (qmark) |i| r.target[i + 1 ..] else "",
            ._headers = header_list.items,
            ._params = &.{},
            ._services = &self.services,
        };

        const match = self.router.match(c.method, path) orelse {
            http1.discardBody(in, &r) catch return false;
            sendDirect(out, c.method, 404, "not found\n", r.keep_alive) catch return false;
            return r.keep_alive;
        };
        c._params = match.params[0..match.n_params];

        match.handler(&c) catch |err| {
            // A half-sent response cannot be taken back, so the connection
            // is closed: the next request on it would read leftover bytes
            // of unclear provenance.
            if (c._sent) {
                std.log.warn("handler {s} {s} failed after answering: {s}", .{ @tagName(c.method), path, @errorName(err) });
                return false;
            }
            // Nothing sent yet: this is a clean failure. A body nobody read
            // still has to be discarded so the connection can be reused —
            // a 404 from a fail function is a normal way to live, not a
            // reason to drop keep-alive.
            if (c._body == null) http1.discardBody(in, &r) catch return false;
            sendFailure(out, failure, err, c.method, path, r.keep_alive) catch return false;
            return r.keep_alive;
        };

        // A body the handler did not read is discarded so the next request
        // on this connection starts at the right byte.
        if (c._body == null) http1.discardBody(in, &r) catch return false;

        if (!c._sent) {
            sendDirect(out, c.method, 200, "", r.keep_alive) catch return false;
        }
        return r.keep_alive;
    }
};

fn sendFinal(out: *std.Io.Writer, response: []const u8) void {
    out.writeAll(response) catch return;
    out.flush() catch return;
}

/// Responses App assembles itself — a 404 for an unknown route, an empty
/// 200, a failure response — outside of `Ctx.send`. As there, the body
/// does not go out for a HEAD.
fn sendDirect(
    out: *std.Io.Writer,
    method: http1.Method,
    status: u16,
    body: []const u8,
    keep_alive: bool,
) !void {
    if (method == .HEAD) return http1.writeResponseHeadOnly(
        out,
        status,
        http1.statusPhrase(status),
        "text/plain",
        body.len,
        keep_alive,
    );
    try http1.writeResponse(out, status, http1.statusPhrase(status), "text/plain", body, keep_alive);
}

/// Turn a handler failure into a response. A fail function's message is
/// used if there is one; otherwise the error goes through the mapping
/// table, and anything unrecognised becomes a 500 logged with its error
/// name (ADR 0005).
fn sendFailure(
    out: *std.Io.Writer,
    failure: *const fail.Failure,
    err: anyerror,
    method: http1.Method,
    path: []const u8,
    keep_alive: bool,
) !void {
    var buf: [fail.max_message + 1]u8 = undefined;

    const status: u16, const message: []const u8 = if (failure.isSet())
        .{ failure.status, failure.message() }
    else blk: {
        const s = fail.statusFor(err);
        if (s == 500) {
            std.log.warn("handler {s} {s} failed: {s}", .{ @tagName(method), path, @errorName(err) });
            // Internal error names are not leaked to the client; anyone who
            // wants a readable message uses a fail function.
            break :blk .{ s, "internal server error" };
        }
        break :blk .{ s, http1.statusPhrase(s) };
    };

    // The message line ends in a newline so it reads nicely under curl.
    const body = std.fmt.bufPrint(&buf, "{s}\n", .{message}) catch message;
    try sendDirect(out, method, status, body, keep_alive);
}

// ---- tests: all of App's HTTP behaviour, without starting a server ----

const testing = std.testing;
const Str = str_mod.Str;

const Harness = struct {
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    failure: fail.Failure = .{},
    buf: [4096]u8 = undefined,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }

    fn send(self: *Harness, app: *App, request: []const u8) struct { response: []const u8, keep_alive: bool } {
        var in = std.Io.Reader.fixed(request);
        var out = std.Io.Writer.fixed(&self.buf);
        const keep_alive = app.handleRequest(self.arena.allocator(), &self.lifetime, &self.failure, &in, &out);
        self.lifetime.end();
        _ = self.arena.reset(.retain_capacity);
        return .{ .response = out.buffered(), .keep_alive = keep_alive };
    }
};

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
    const request = std.fmt.bufPrint(&request_buf, "POST /echo HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch unreachable;
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
    const result = h.send(&app, "POST /nowhere HTTP/1.1\r\nContent-Length: 4\r\n\r\nxxxxGET /here HTTP/1.1\r\n\r\n");
    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 404 Not Found\r\n"));
}

test "an unrecognised error becomes a 500, but the connection stays alive" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/explode", testExplode);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /explode HTTP/1.1\r\n\r\n");

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
    const result = h.send(&app, "GET /half HTTP/1.1\r\n\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(!result.keep_alive);
}

test "a quiet handler answers an empty 200" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/quiet", testQuiet);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "GET /quiet HTTP/1.1\r\n\r\n");
    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 0\r\n"));
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
    const result = h.send(&app, "GET /search?word=zig&empty= HTTP/1.1\r\nX-Token: secret\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200"));
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
    const result = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");

    try testing.expect(result.keep_alive);
    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":7,\"name\":\"wati\"}") != null);
}

// The main selling point (ADR 0003): a handler is tested as an ordinary
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
    const result = h.send(&app, "GET /users/99 HTTP/1.1\r\n\r\n");

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
    const result = h.send(&app, "GET /users/abc HTTP/1.1\r\n\r\n");

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

    const failed_first = h.send(&app, "GET /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed_first.response, "HTTP/1.1 404"));

    const then_succeeded = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
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
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 16\r\n\r\n{\"name\":\"wati\"}\r\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 201 Created\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "{\"id\":1,\"name\":\"wati\"}") != null);
}

test "a JSON body that breaks a rule becomes a 422 via a fail function" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 12\r\n\r\n{\"name\":\"\"}\n");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 422 Unprocessable Content\r\n"));
    try testing.expect(std.mem.indexOf(u8, result.response, "name must not be empty") != null);
}

test "broken JSON goes through the mapping table and becomes a 400" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/users", createUser);

    var h = Harness.init();
    defer h.deinit();
    const result = h.send(&app, "POST /users HTTP/1.1\r\nContent-Length: 5\r\n\r\n{name");

    try testing.expect(std.mem.startsWith(u8, result.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(result.keep_alive);
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

    const greeting = h.send(&app, "GET /greet/wati HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.indexOf(u8, greeting.response, "Content-Type: text/plain") != null);
    try testing.expect(std.mem.endsWith(u8, greeting.response, "wati"));

    const product = h.send(&app, "GET /times/6/7 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, product.response, "42"));

    const colour = h.send(&app, "GET /colour/green/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, colour.response, "green"));

    const wrong = h.send(&app, "GET /colour/purple/true HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, wrong.response, "HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(std.mem.indexOf(u8, wrong.response, ":c is not one of the known choices") != null);
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
    const result = h.send(&app, "GET /mode HTTP/1.1\r\n\r\n");
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

    const got = h.send(&app, "GET /users/7 HTTP/1.1\r\n\r\n");
    const got_head = got.response[0 .. std.mem.indexOf(u8, got.response, "\r\n\r\n").? + 4];

    const headed = h.send(&app, "HEAD /users/7 HTTP/1.1\r\n\r\n");

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

    const failed = h.send(&app, "HEAD /users/99 HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.startsWith(u8, failed.response, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(std.mem.endsWith(u8, failed.response, "\r\n\r\n"));
    try testing.expect(std.mem.indexOf(u8, failed.response, "no user 99") == null);

    const unrouted = h.send(&app, "HEAD /nowhere HTTP/1.1\r\n\r\n");
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
    const result = h.send(&app, "GET /raw/42/x HTTP/1.1\r\n\r\n");
    try testing.expect(std.mem.endsWith(u8, result.response, "42"));
}
