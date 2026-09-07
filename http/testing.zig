//! Driving one request into an App, for a test that has no server.
//!
//! Most handlers need none of this: a handler is an ordinary function, so a
//! test calls it and looks at what came back. That stops working the moment
//! a handler *writes* its answer rather than returning one — a stream has to
//! have somewhere to write to (ADR 0020) — and it was already awkward for
//! anything that wanted to check a header or a status.
//!
//! ```zig
//! test "the report streams its rows" {
//!     var app = nilo.App.init(testing.allocator);
//!     defer app.deinit();
//!     try app.get("/report.csv", report);
//!
//!     var client = nilo.testing.Client.init(testing.allocator, .{});
//!     defer client.deinit();
//!
//!     const answer = try client.get(&app, "/report.csv");
//!     try testing.expectEqual(@as(u16, 200), answer.status);
//!     try testing.expect(answer.chunked);
//! }
//! ```
//!
//! Nothing here belongs in a running server, and none of it is on the
//! request path.

const std = @import("std");

const app_mod = @import("app.zig");
const App = app_mod.App;
const bulkhead = @import("bulkhead.zig");
const fail = @import("fail.zig");
const str_mod = @import("nilo_core");

/// Whether the optimize-mode warning has already been given. One process
/// builds one nilo, so the answer is the same for every test in it.
var said_the_mode = false;

pub const Options = struct {
    /// The response buffer. A request whose answer does not fit gets a
    /// truncated one rather than a failure, so turn this up for a stream
    /// that produces a lot.
    response_bytes: usize = 64 * 1024,

    /// The address these requests appear to come from — what `c.peer()`
    /// answers, and what `c.clientIp()` falls back to.
    ///
    /// There is no socket here, so without this every request in a test
    /// arrives from nowhere. Middleware that counts requests per address,
    /// or refuses some of them, needs two different clients to be two
    /// different addresses before there is anything to test.
    client_address: []const u8 = "",

    /// Keep the cookies the answers set, and send them back — a browser's
    /// jar, so a test can sign in and then be that user.
    ///
    /// Off by default, and that is a decision rather than caution about the
    /// feature. This API shipped without one, so a suite written against it
    /// has requests that carry no cookie; turning a jar on underneath them
    /// would change what those tests assert without changing a line of them.
    /// A test that wants the jar says so, and says it once.
    cookies: bool = false,
};

/// One header to send, for `Client.setHeader` and `Request.headers`.
///
/// `nilo.Header` is the response side and this is the request side, which is
/// the same split `Ctx.RequestHeader` is on.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// A whole request, described rather than written out.
///
/// Every field has a default, so only what a test cares about is written:
///
/// ```zig
/// const answer = try client.sendRequest(&app, .{
///     .path = "/admin",
///     .headers = &.{.{ .name = "Authorization", .value = "Bearer t" }},
/// });
/// ```
///
/// `Host`, `Content-Type` and `Content-Length` are written for you and only
/// if `headers` does not already name them. That is not tidiness: a second
/// `Content-Length` is a 400 now, and so is a second `Host`
/// ([ADR 0101](../docs/adr/0101-a-request-nobody-else-would-answer-is-refused.md)),
/// so a helper that added its own on top of yours would answer 400 to a test
/// that looked correct.
pub const Request = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/",
    /// Sent after the client's own sticky headers, in this order.
    headers: []const Header = &.{},
    /// Written as `Content-Type` when it is not empty. A form has to have one,
    /// because `application/x-www-form-urlencoded` and `multipart/form-data`
    /// are told apart by nothing else (ADR 0031).
    content_type: []const u8 = "",
    body: []const u8 = "",
};

/// One answer, taken apart far enough to ask questions of.
pub const Answer = struct {
    /// Everything, exactly as it went on the wire.
    raw: []const u8,
    /// The status line and headers, without the blank line after them.
    head: []const u8,
    /// What follows the head. For a chunked response this is still framed —
    /// use `text` for the bytes a client would see.
    body: []const u8,
    status: u16,
    /// Whether the connection may carry another request.
    keep_alive: bool,
    /// Whether the body arrived in chunks, which is what a stream does.
    chunked: bool,
    /// The interim response that came before the final one, without its blank
    /// line — `HTTP/1.1 100 Continue` — or null if there was none.
    ///
    /// A real client reads one and keeps waiting, which is what the fields
    /// above do too: `status` is the final status whether or not an interim
    /// arrived. This is here so a test can assert the interim was sent, and so
    /// that one arriving cannot be mistaken for the answer (ADR 0094).
    interim: ?[]const u8 = null,

    /// The value of a response header, or null if it is not there.
    pub fn header(self: Answer, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }

    /// The `n`th header of this name, counting from zero.
    ///
    /// `header` answers with the first, which is right for every header
    /// except the one a response is supposed to send more than one of — see
    /// `setCookie` below, and `http1.repeats`.
    pub fn headerAt(self: Answer, name: []const u8, n: usize) ?[]const u8 {
        var seen: usize = 0;
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
            if (seen == n) return std.mem.trim(u8, line[colon + 1 ..], " \t");
            seen += 1;
        }
        return null;
    }

    /// How many headers of this name the response carries.
    pub fn headerCount(self: Answer, name: []const u8) usize {
        var n: usize = 0;
        while (self.headerAt(name, n) != null) n += 1;
        return n;
    }

    /// The whole `Set-Cookie` line that sets the cookie called `name`,
    /// attributes and all — or null if the response sets no such cookie.
    ///
    /// A response may set several, so asking by name is the only way to ask
    /// (ADR 0030).
    pub fn setCookie(self: Answer, name: []const u8) ?[]const u8 {
        var n: usize = 0;
        while (self.headerAt("Set-Cookie", n)) |line| : (n += 1) {
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, line[0..equals], name)) return line;
        }
        return null;
    }

    /// The body as the client sees it: chunk framing removed if there was
    /// any, and the bytes as they are otherwise.
    pub fn text(self: Answer, into: []u8) ![]const u8 {
        if (!self.chunked) {
            if (self.body.len > into.len) return error.NoRoom;
            @memcpy(into[0..self.body.len], self.body);
            return into[0..self.body.len];
        }
        var written: usize = 0;
        var rest = self.body;
        while (true) {
            const crlf = std.mem.indexOf(u8, rest, "\r\n") orelse return error.BadChunk;
            const size = std.fmt.parseInt(usize, rest[0..crlf], 16) catch return error.BadChunk;
            if (size == 0) return into[0..written];
            const start = crlf + 2;
            if (start + size > rest.len) return error.BadChunk;
            if (written + size > into.len) return error.NoRoom;
            @memcpy(into[written..][0..size], rest[start..][0..size]);
            written += size;
            rest = rest[start + size + 2 ..];
        }
    }
};

/// A value rendered the way it goes over the wire, for a failure message
/// somebody can read
/// ([ADR 0169](../docs/adr/0169-a-failed-assertion-that-can-be-read.md)).
///
/// ```zig
/// errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
/// ```
///
/// **`std.testing` prints with `{any}`, and `{any}` is the specifier that
/// means *do not call the type's own formatter*.** So a `Uuid` comes out as
/// sixteen decimal numbers and a `[]const u8` as its bytes — on a schema with
/// many uuid columns, nearly every row asserted on prints as noise. That is
/// not `std`'s bug and there is nothing below this layer that can decide
/// otherwise; what this layer has is a rendering for every type it carries,
/// and JSON is it. `Uuid.jsonStringify` writes text, `Str` writes a string, a
/// `Timestamp` writes RFC 3339, a `Decimal` its digits.
///
/// **A renderer rather than an assertion, and that is the whole shape.** An
/// `expectEqual` of nilo's own pulls in the rest of the assertion surface
/// behind it — `expectEqualDeep`, `expectEqualSlices`, `expectError` — where
/// every one nilo does not have looks like a gap and every one it does have
/// has to follow `std.testing`. And it would not have helped the failure this
/// was reported from, which was an `expectError` that found a payload rather
/// than two values that differed. One thing that hands back text works in
/// `expect`, in `expectError`, and in the `std.debug.print` somebody reaches
/// for while poking about, which is where it gets used most.
///
/// **Nothing is allocated.** It writes straight into whatever writer is
/// formatting it. For an actual `[]const u8`,
/// `std.fmt.allocPrint(gpa, "{f}", .{show(v)})` is the ordinary spelling and
/// needs nothing from here.
///
/// A `sql.Json(T)` column nests JSON inside the JSON, which reads well and is
/// **not** meant to be parsed back. This is for a person reading a failure.
pub fn show(value: anytype) Shown(@TypeOf(value)) {
    return .{ .value = value };
}

/// What `show` returns: the value, and the one way of printing it.
pub fn Shown(comptime T: type) type {
    return struct {
        value: T,

        pub fn format(self: @This(), w: *std.Io.Writer) !void {
            try std.json.Stringify.value(self.value, .{}, w);
        }
    };
}

/// What a fail function said, read back where there was no request
/// ([ADR 0161](../docs/adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)).
pub const Refused = struct {
    /// The status the fail function was given: 409, 422, whatever it wrote.
    status: u16,
    /// The sentence a person would have read. Borrowed from the `Refusals`
    /// this came out of, so it is good for as long as that is in scope.
    message: []const u8,
};

/// Catch what a service function refuses with, outside a request.
///
/// ```zig
/// var refusals: nilo.testing.Refusals = .{};
/// refusals.begin();
/// defer refusals.end();
///
/// try testing.expectError(error.Failed, comment.edit(&db, run, id, someone_else, "hi"));
/// const said = refusals.caught().?;
/// try testing.expectEqual(@as(u16, 409), said.status);
/// try testing.expect(std.mem.indexOf(u8, said.message, "somebody else's") != null);
/// ```
///
/// **Why this exists.** `fail.status` parks the code on the request in
/// flight and returns one error, so outside a request `current()` is null and
/// the status and the sentence are dropped. A service function that refuses
/// four different ways is then four identical `error.Failed`s to its caller,
/// and a test can only say "it failed" — which is a poor thing to assert in a
/// project whose convention is that errors are sentences.
///
/// Moving such a test over the wire, where `Client` gives a real status,
/// works and is a fair trade for an endpoint that has one. It is not a trade
/// available to a service function called by a CLI or a seed, and that is the
/// gap this closes.
///
/// **A test type and nothing else.** The slot it installs is the Bulkhead's
/// fallback, which is what a call made off the loop already uses; nothing
/// here runs in a server, and a running one has a real slot per fiber.
pub const Refusals = struct {
    in_flight: fail.InFlight = .{},
    previous: ?*anyopaque = null,
    installed: bool = false,

    /// Install the slot. Separate from a constructor on purpose: what goes in
    /// the slot is a pointer to this struct, so it has to be at the address
    /// the test will keep it at rather than at a returned temporary's.
    pub fn begin(self: *Refusals) void {
        self.in_flight = .{};
        // The `InFlight`, not this struct: what the slot holds is what
        // `fail.inFlight` casts it back to. It is the first field, so the two
        // addresses are the same one today — which is exactly the kind of
        // accident that stops being true and takes a fail function's message
        // with it.
        self.previous = bulkhead.setFallbackSlot(@ptrCast(&self.in_flight));
        self.installed = true;
    }

    /// Put back whatever was in the slot before. Safe to call twice, and safe
    /// on a `Refusals` that never began.
    pub fn end(self: *Refusals) void {
        if (!self.installed) return;
        _ = bulkhead.setFallbackSlot(self.previous);
        self.installed = false;
    }

    /// What the last refusal said, or null when nothing has refused.
    pub fn caught(self: *const Refusals) ?Refused {
        if (!self.in_flight.failure.isSet()) return null;
        return .{
            .status = self.in_flight.failure.status,
            .message = self.in_flight.failure.message(),
        };
    }

    /// Forget the last one, for a test that makes a second call. Without it
    /// the second assertion passes on the first call's sentence, which is the
    /// one way a test like this goes quietly wrong.
    pub fn clear(self: *Refusals) void {
        self.in_flight.failure.clear();
    }
};

/// A stand-in for a client on the other end of a connection.
pub const Client = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    buffer: []u8,
    peer: bulkhead.Peer = .{},
    /// Sent with every request this client makes. Owned here rather than in
    /// `arena`, which is reset after each one.
    sticky: std.ArrayList(Header) = .empty,
    /// The cookies the answers have set, when `Options.cookies` is on.
    jar: std.ArrayList(Header) = .empty,
    keep_cookies: bool = false,

    pub fn init(gpa: std.mem.Allocator, options: Options) !Client {
        // The one warning `listen()` gives that a test can also earn, and the
        // place it is worth most: a suite that runs in both optimize modes
        // and passes neither through to `b.dependency` is the case ADR 0084
        // was written about. Once per process, because a suite makes one of
        // these per test and the answer cannot change between them.
        if (!said_the_mode) {
            said_the_mode = true;
            app_mod.warnIfBuiltDifferently();
        }

        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .buffer = try gpa.alloc(u8, options.response_bytes),
            .peer = try bulkhead.Peer.from(options.client_address),
            .keep_cookies = options.cookies,
        };
    }

    pub fn deinit(self: *Client) void {
        for (self.sticky.items) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        self.sticky.deinit(self.gpa);
        for (self.jar.items) |c| {
            self.gpa.free(c.name);
            self.gpa.free(c.value);
        }
        self.jar.deinit(self.gpa);
        self.gpa.free(self.buffer);
        self.arena.deinit();
    }

    /// Send this header with every request from now on — an `Authorization`,
    /// an `Origin`, a tracing header of somebody else's shape.
    ///
    /// Setting the same name twice replaces it rather than sending two,
    /// because a test that meant to send two says so with `Request.headers`
    /// and a test that meant to change one should not have to remember
    /// whether it set it already.
    ///
    /// The name and value are copied, so a buffer the caller reuses is safe.
    pub fn setHeader(self: *Client, name: []const u8, value: []const u8) !void {
        const kept = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(kept);

        for (self.sticky.items) |*h| {
            if (!std.ascii.eqlIgnoreCase(h.name, name)) continue;
            self.gpa.free(h.value);
            h.value = kept;
            return;
        }
        const kept_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(kept_name);
        try self.sticky.append(self.gpa, .{ .name = kept_name, .value = kept });
    }

    /// What the jar holds for `name`, or null. For a test that wants to look
    /// at the cookie rather than only send it.
    pub fn cookie(self: *const Client, name: []const u8) ?[]const u8 {
        for (self.jar.items) |c| {
            if (std.mem.eql(u8, c.name, name)) return c.value;
        }
        return null;
    }

    pub fn get(self: *Client, app: *App, path: []const u8) !Answer {
        return self.sendRequest(app, .{ .path = path });
    }

    pub fn post(self: *Client, app: *App, path: []const u8, body: []const u8) !Answer {
        return self.sendRequest(app, .{ .method = "POST", .path = path, .body = body });
    }

    /// A POST that says what its body is — which a form has to, because
    /// `application/x-www-form-urlencoded` and `multipart/form-data` are told
    /// apart by nothing else (ADR 0031).
    ///
    /// ```zig
    /// const answer = try client.postWith(
    ///     &app,
    ///     "/sign-in",
    ///     "application/x-www-form-urlencoded",
    ///     "email=wati%40example.dev&password=hunter2",
    /// );
    /// ```
    pub fn postWith(
        self: *Client,
        app: *App,
        path: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) !Answer {
        return self.sendRequest(app, .{
            .method = "POST",
            .path = path,
            .content_type = content_type,
            .body = body,
        });
    }

    pub fn request(
        self: *Client,
        app: *App,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) !Answer {
        return self.sendRequest(app, .{ .method = method, .path = path, .body = body });
    }

    /// A request described field by field: a header, a method, a body, or all
    /// three. Every helper above is one of these with defaults.
    ///
    /// The sticky headers go out first, then `r.headers`, then the jar's
    /// `Cookie` if there is one. `Host: test` is written unless something
    /// already named it — see `Request`.
    pub fn sendRequest(self: *Client, app: *App, r: Request) !Answer {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);

        try text.print(self.gpa, "{s} {s} HTTP/1.1\r\n", .{ r.method, r.path });
        if (!self.names("Host", r)) try text.appendSlice(self.gpa, "Host: test\r\n");
        if (r.content_type.len > 0 and !self.names("Content-Type", r)) {
            try text.print(self.gpa, "Content-Type: {s}\r\n", .{r.content_type});
        }
        // Written even for a body of nothing, which is what the three helpers
        // above have always sent and what a test asserting on the raw bytes
        // would have seen.
        if (!self.names("Content-Length", r)) {
            try text.print(self.gpa, "Content-Length: {d}\r\n", .{r.body.len});
        }
        for (self.sticky.items) |h| try text.print(self.gpa, "{s}: {s}\r\n", .{ h.name, h.value });
        for (r.headers) |h| try text.print(self.gpa, "{s}: {s}\r\n", .{ h.name, h.value });

        if (self.jar.items.len > 0 and !self.names("Cookie", r)) {
            try text.appendSlice(self.gpa, "Cookie: ");
            for (self.jar.items, 0..) |c, i| {
                if (i > 0) try text.appendSlice(self.gpa, "; ");
                try text.print(self.gpa, "{s}={s}", .{ c.name, c.value });
            }
            try text.appendSlice(self.gpa, "\r\n");
        }

        try text.print(self.gpa, "\r\n{s}", .{r.body});
        return self.send(app, text.items);
    }

    /// Whether the caller has already written this header themselves, either
    /// on the client or on this one request.
    fn names(self: *const Client, name: []const u8, r: Request) bool {
        for (self.sticky.items) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        for (r.headers) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        return false;
    }

    /// The whole request, written out. For a version, a header or a shape
    /// the helpers above do not cover.
    ///
    /// The sticky headers and the jar are **not** applied here: the bytes are
    /// the caller's, exactly as given. The jar still *reads* the answer, so
    /// signing in with a hand-written request and going on with `get` works.
    pub fn send(self: *Client, app: *App, raw_request: []const u8) !Answer {
        // What `listen()` would have done. Idempotent, so calling it once
        // per request costs nothing after the first.
        //
        // **`checkServices` is deliberately not here** (ADR 0079). It was, for
        // an afternoon, and it refused a test that drives an App to fetch
        // `/openapi.json` and never touches the routes whose services are
        // missing — which is a fair thing to write and not a mistake. The
        // complaint it was answering was that nothing named the type; that is
        // answered where the route actually needs one, in `typed.zig`, which
        // has no false positive to have. `app.checkServices()` is public for a
        // test that wants the whole gate.
        try app.resolveChains();

        var in = std.Io.Reader.fixed(raw_request);
        var out = std.Io.Writer.fixed(self.buffer);
        const keep_alive = app.handleRequest(
            self.arena.allocator(),
            &self.lifetime,
            &self.in_flight,
            &in,
            &out,
            // There is no socket here, so there is nothing to time out.
            .off,
            // And nobody to post to it: a `receive` answers out of the fixed
            // buffer it was handed and never parks.
            .off,
            self.peer,
        );
        // One request, then everything it allocated goes — exactly as a
        // connection does between requests.
        self.lifetime.end();
        defer _ = self.arena.reset(.retain_capacity);

        const answer = try parse(out.buffered(), keep_alive);
        if (self.keep_cookies) try self.takeCookies(answer);
        return answer;
    }

    /// Put every cookie this answer set into the jar, and take out the ones it
    /// removed.
    ///
    /// A copy, because `answer` points into the response buffer and the next
    /// request writes over it.
    ///
    /// **Attributes are read for one thing only: whether the cookie is being
    /// removed.** `Max-Age` of zero or less is what `Cookie.remove` sends
    /// (ADR 0030), and it is the whole of what a test can produce. `Path`,
    /// `Domain` and `Secure` are ignored, which a browser would not do — this
    /// is a jar for driving one App on one host, and a jar that guessed at
    /// scope would be a second implementation of a browser to be wrong in.
    fn takeCookies(self: *Client, answer: Answer) !void {
        var n: usize = 0;
        while (answer.headerAt("Set-Cookie", n)) |line| : (n += 1) {
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const name = line[0..equals];
            const rest = line[equals + 1 ..];
            const semi = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;

            if (removes(rest[semi..])) {
                self.forget(name);
                continue;
            }
            try self.remember(name, rest[0..semi]);
        }
    }

    fn remember(self: *Client, name: []const u8, value: []const u8) !void {
        const kept = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(kept);

        for (self.jar.items) |*c| {
            if (!std.mem.eql(u8, c.name, name)) continue;
            self.gpa.free(c.value);
            c.value = kept;
            return;
        }
        const kept_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(kept_name);
        try self.jar.append(self.gpa, .{ .name = kept_name, .value = kept });
    }

    fn forget(self: *Client, name: []const u8) void {
        for (self.jar.items, 0..) |c, i| {
            if (!std.mem.eql(u8, c.name, name)) continue;
            self.gpa.free(c.name);
            self.gpa.free(c.value);
            _ = self.jar.orderedRemove(i);
            return;
        }
    }
};

/// Whether a `Set-Cookie`'s attributes say the cookie is going away.
fn removes(attributes: []const u8) bool {
    var parts = std.mem.splitScalar(u8, attributes, ';');
    while (parts.next()) |part| {
        const one = std.mem.trim(u8, part, " \t");
        const equals = std.mem.indexOfScalar(u8, one, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(one[0..equals], "Max-Age")) continue;
        const seconds = std.fmt.parseInt(i64, one[equals + 1 ..], 10) catch continue;
        return seconds <= 0;
    }
    return false;
}

fn parse(raw: []const u8, keep_alive: bool) !Answer {
    // A 100 is a response that is not the answer: the client reads it, drops
    // it and goes on waiting (RFC 9110 §15.2). Doing that here rather than in
    // every caller is what keeps `answer.status` meaning the same thing before
    // and after a request carried `Expect: 100-continue`.
    //
    // 100 by name rather than 1xx, because the other one nilo sends is a 101
    // and that *is* the answer — the connection stops being HTTP under it.
    var rest = raw;
    var interim: ?[]const u8 = null;
    if (std.mem.startsWith(u8, rest, "HTTP/1.1 100 ")) {
        const ends = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.NoHead;
        interim = rest[0..ends];
        rest = rest[ends + 4 ..];
    }

    const split = std.mem.indexOf(u8, rest, "\r\n\r\n") orelse return error.NoHead;
    const raw_final = rest;
    const head = rest[0..split];
    const first_line_end = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const line = head[0..first_line_end];

    // `HTTP/1.1 200 OK` — the status is between the two spaces.
    const after_version = (std.mem.indexOfScalar(u8, line, ' ') orelse return error.BadStatusLine) + 1;
    const digits_end = std.mem.indexOfScalarPos(u8, line, after_version, ' ') orelse line.len;
    const status = std.fmt.parseInt(u16, line[after_version..digits_end], 10) catch return error.BadStatusLine;

    var answer = Answer{
        // `raw` is everything that went on the wire, interim included, because
        // a test asking for the raw bytes is asking what the client saw.
        .raw = raw,
        .head = head,
        .body = raw_final[split + 4 ..],
        .status = status,
        .keep_alive = keep_alive,
        .chunked = false,
        .interim = interim,
    };
    if (answer.header("Transfer-Encoding")) |te| {
        answer.chunked = std.ascii.indexOfIgnoreCase(te, "chunked") != null;
    }
    return answer;
}

// ---- a WebSocket, driven from a test (ADR 0113) ----

/// What one frame carries. The four a handler ever sees, plus the two it
/// answers control frames with.
pub const Kind = enum { text, binary, ping, pong, close };

/// One frame the **server** sent, decoded.
pub const Message = struct {
    kind: Kind,
    bytes: []const u8,

    /// The code inside a close frame, or null when this is not one — or is
    /// one carrying no code, which is legal and means "no reason given".
    pub fn code(self: Message) ?u16 {
        if (self.kind != .close or self.bytes.len < 2) return null;
        return std.mem.readInt(u16, self.bytes[0..2], .big);
    }

    /// The reason text beside that code, which is `""` when there is none.
    pub fn reason(self: Message) []const u8 {
        if (self.kind != .close or self.bytes.len < 2) return "";
        return self.bytes[2..];
    }
};

/// What a conversation came back with: the handshake, then every frame the
/// server sent, in order.
pub const Talk = struct {
    /// The status line's code — 101 when the handshake was accepted, and
    /// whatever refused it otherwise.
    status: u16,
    /// The response head, blank line included, for a test that wants to read
    /// a header off it with `header`.
    head: []const u8,
    /// Every frame the server sent after the head, decoded in order.
    messages: []const Message,

    pub fn accepted(self: Talk) bool {
        return self.status == 101;
    }

    pub fn header(self: Talk, name: []const u8) ?[]const u8 {
        var lines = std.mem.splitSequence(u8, self.head, "\r\n");
        _ = lines.next(); // the status line
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
                return std.mem.trim(u8, line[colon + 1 ..], " \t");
            }
        }
        return null;
    }

    /// The `n`th message, or null. `talk.at(0)` reads better than an index
    /// into a slice a test then has to bounds-check itself.
    pub fn at(self: Talk, n: usize) ?Message {
        return if (n < self.messages.len) self.messages[n] else null;
    }

    /// The first message of this kind, which is what a test asserting "it
    /// answered the ping" or "it closed with 1009" actually wants.
    pub fn first(self: Talk, kind: Kind) ?Message {
        for (self.messages) |m| if (m.kind == kind) return m;
        return null;
    }

    /// The code the server closed with, or null if it never closed.
    pub fn closedWith(self: Talk) ?u16 {
        const closing = self.first(.close) orelse return null;
        return closing.code();
    }
};

/// A WebSocket conversation: the frames a client sends, and what came back.
///
/// A handler that upgrades never returns a value and never writes a response
/// a `Client` can read — it reads frames until they stop. So the only way to
/// test one was to hand `handleRequest` a buffer with hand-masked bytes in it
/// and index into the answer, which is how every WebSocket test in nilo's own
/// suite was written (ADR 0113).
///
/// ```zig
/// var chat: nilo.testing.Conversation = try .init(testing.allocator, .{});
/// defer chat.deinit();
///
/// try chat.text("hello");
/// try chat.close(1000, "bye");
///
/// const talk = try chat.open(&app, "/chat");
/// try testing.expect(talk.accepted());
/// try testing.expectEqualStrings("hello", talk.at(0).?.bytes);
/// ```
///
/// **The frames are queued before the server runs, not while it runs.** There
/// is one thread and no socket here, so a test cannot read what the server
/// said and then decide what to send next. What it can do is send a script and
/// read the whole answer, which is what nearly every WebSocket test is.
pub const Conversation = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    lifetime: str_mod.Lifetime = .{},
    in_flight: fail.InFlight = .{},
    buffer: []u8,
    peer: bulkhead.Peer = .{},
    /// The client's side of the wire: masked frames, in the order queued.
    wire: std.ArrayList(u8) = .empty,
    /// Extra request headers for the handshake — an `Origin`, a cookie, a
    /// `Sec-WebSocket-Protocol`.
    extra: std.ArrayList(Header) = .empty,

    /// The key every example uses, and the one RFC 6455 §1.3 works through:
    /// a server that hashes it correctly answers `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`.
    pub const key = "dGhlIHNhbXBsZSBub25jZQ==";
    pub const accept_for_key = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";

    /// Fixed rather than random, so a failing test shows the same bytes twice.
    /// A client must mask (RFC 6455 §5.3) and a server must refuse a frame
    /// that is not masked, so this is not a detail a test can skip.
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };

    pub fn init(gpa: std.mem.Allocator, options: Options) !Conversation {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .buffer = try gpa.alloc(u8, options.response_bytes),
            .peer = try bulkhead.Peer.from(options.client_address),
        };
    }

    pub fn deinit(self: *Conversation) void {
        for (self.extra.items) |h| {
            self.gpa.free(h.name);
            self.gpa.free(h.value);
        }
        self.extra.deinit(self.gpa);
        self.wire.deinit(self.gpa);
        self.gpa.free(self.buffer);
        self.arena.deinit();
    }

    /// Send this header with the handshake — an `Origin`, a `Cookie`, a
    /// `Sec-WebSocket-Protocol`. Copied, so a caller's buffer is safe.
    pub fn setHeader(self: *Conversation, name: []const u8, value: []const u8) !void {
        const kept_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(kept_name);
        const kept_value = try self.gpa.dupe(u8, value);
        try self.extra.append(self.gpa, .{ .name = kept_name, .value = kept_value });
    }

    pub fn text(self: *Conversation, message: []const u8) !void {
        try self.frame(0x1, message);
    }

    pub fn binary(self: *Conversation, bytes: []const u8) !void {
        try self.frame(0x2, bytes);
    }

    pub fn ping(self: *Conversation, bytes: []const u8) !void {
        try self.frame(0x9, bytes);
    }

    pub fn pong(self: *Conversation, bytes: []const u8) !void {
        try self.frame(0xA, bytes);
    }

    /// A close frame carrying a code and a reason. `1000` is the ordinary
    /// goodbye.
    pub fn close(self: *Conversation, code: u16, why: []const u8) !void {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);
        try payload.appendSlice(self.gpa, &.{ @intCast(code >> 8), @truncate(code) });
        try payload.appendSlice(self.gpa, why);
        try self.frame(0x8, payload.items);
    }

    /// One message split across a first frame and its continuations, which is
    /// what a browser sends for anything large and what a server assembling
    /// them has to get right.
    pub fn fragments(self: *Conversation, kind: Kind, pieces: []const []const u8) !void {
        std.debug.assert(pieces.len > 0);
        const opcode: u8 = switch (kind) {
            .text => 0x1,
            .binary => 0x2,
            else => unreachable, // a control frame cannot be fragmented
        };
        for (pieces, 0..) |piece, i| {
            const last = i == pieces.len - 1;
            try self.write(if (i == 0) opcode else 0x0, piece, last);
        }
    }

    /// Bytes straight onto the wire, masked by nobody and framed by nobody —
    /// for a test about what a **malformed** frame does.
    pub fn raw(self: *Conversation, bytes: []const u8) !void {
        try self.wire.appendSlice(self.gpa, bytes);
    }

    /// Run the handshake and the frames queued behind it, and decode what came
    /// back. The conversation can be reused: the queue is cleared, so the next
    /// `open` sends only what was queued after this one.
    pub fn open(self: *Conversation, app: *App, path: []const u8) !Talk {
        try app.resolveChains();

        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.gpa);
        try request.print(self.gpa, "GET {s} HTTP/1.1\r\nHost: t\r\n", .{path});
        try request.appendSlice(self.gpa, "Upgrade: websocket\r\nConnection: Upgrade\r\n");
        try request.print(
            self.gpa,
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {s}\r\n",
            .{key},
        );
        for (self.extra.items) |h| {
            try request.print(self.gpa, "{s}: {s}\r\n", .{ h.name, h.value });
        }
        try request.appendSlice(self.gpa, "\r\n");
        try request.appendSlice(self.gpa, self.wire.items);
        self.wire.clearRetainingCapacity();

        var in = std.Io.Reader.fixed(request.items);
        var out = std.Io.Writer.fixed(self.buffer);
        _ = app.handleRequest(
            self.arena.allocator(),
            &self.lifetime,
            &self.in_flight,
            &in,
            &out,
            .off,
            .off,
            self.peer,
        );
        self.lifetime.end();
        _ = self.arena.reset(.retain_capacity);

        return decode(self.arena.allocator(), out.buffered());
    }

    fn frame(self: *Conversation, opcode: u8, payload: []const u8) !void {
        try self.write(opcode, payload, true);
    }

    /// One frame, masked the way RFC 6455 §5.3 requires of a client.
    fn write(self: *Conversation, opcode: u8, payload: []const u8, fin: bool) !void {
        const g = self.gpa;
        try self.wire.append(g, (if (fin) @as(u8, 0x80) else 0) | opcode);

        if (payload.len < 126) {
            try self.wire.append(g, 0x80 | @as(u8, @intCast(payload.len)));
        } else if (payload.len <= std.math.maxInt(u16)) {
            try self.wire.append(g, 0x80 | 126);
            var be: [2]u8 = undefined;
            std.mem.writeInt(u16, &be, @intCast(payload.len), .big);
            try self.wire.appendSlice(g, &be);
        } else {
            try self.wire.append(g, 0x80 | 127);
            var be: [8]u8 = undefined;
            std.mem.writeInt(u64, &be, payload.len, .big);
            try self.wire.appendSlice(g, &be);
        }

        try self.wire.appendSlice(g, &mask);
        for (payload, 0..) |byte, i| try self.wire.append(g, byte ^ mask[i % 4]);
    }
};

/// Split a response into its head and the frames behind it.
///
/// Written here rather than borrowed from `websocket.zig` on purpose: a
/// decoder that shares code with the encoder it is checking agrees with it by
/// construction, which is the property ADR 0090 says is not the one worth
/// having.
fn decode(arena: std.mem.Allocator, response: []const u8) !Talk {
    const blank = std.mem.indexOf(u8, response, "\r\n\r\n") orelse
        return .{ .status = 0, .head = response, .messages = &.{} };
    const head = response[0 .. blank + 4];
    var rest = response[blank + 4 ..];

    var status: u16 = 0;
    if (std.mem.indexOfScalar(u8, head, ' ')) |sp| {
        status = std.fmt.parseInt(u16, head[sp + 1 ..][0..@min(3, head.len - sp - 1)], 10) catch 0;
    }
    // A refused handshake is an ordinary response with an ordinary body, and
    // reading that body as frames would produce nonsense rather than nothing.
    if (status != 101) return .{ .status = status, .head = head, .messages = &.{} };

    var messages: std.ArrayList(Message) = .empty;
    while (rest.len >= 2) {
        const opcode = rest[0] & 0x0F;
        const masked = rest[1] & 0x80 != 0;
        // A server never masks (RFC 6455 §5.1), and a test that let one
        // through would be reading payload out of a mask key.
        if (masked) return error.ServerMaskedAFrame;

        var length: u64 = rest[1] & 0x7F;
        var at: usize = 2;
        if (length == 126) {
            if (rest.len < 4) break;
            length = std.mem.readInt(u16, rest[2..4], .big);
            at = 4;
        } else if (length == 127) {
            if (rest.len < 10) break;
            length = std.mem.readInt(u64, rest[2..10], .big);
            at = 10;
        }
        if (rest.len < at + length) break;

        const kind: ?Kind = switch (opcode) {
            0x1 => .text,
            0x2 => .binary,
            0x8 => .close,
            0x9 => .ping,
            0xA => .pong,
            else => null, // a continuation, which this joins to nothing
        };
        if (kind) |k| {
            try messages.append(arena, .{ .kind = k, .bytes = rest[at..][0..@intCast(length)] });
        }
        rest = rest[at + @as(usize, @intCast(length)) ..];
    }

    return .{ .status = status, .head = head, .messages = try messages.toOwnedSlice(arena) };
}

// ---- tests ----

const testing = std.testing;

// ---- the WebSocket harness (ADR 0113) ----

const websocket_mod = @import("websocket.zig");

fn wsEcho(c: *@import("ctx.zig").Ctx) anyerror!void {
    return c.upgrade(wsEchoLoop, {});
}

fn wsEchoLoop(socket: *websocket_mod.Socket) anyerror!void {
    while (try socket.receive()) |message| {
        try socket.send(message.kind, message.data);
    }
}

fn wsSmall(c: *@import("ctx.zig").Ctx) anyerror!void {
    return c.upgradeWith(wsEchoLoop, {}, .{ .max_message = 8 });
}

test "a scripted conversation reaches the loop and comes back in order" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    try chat.text("one");
    try chat.text("two");
    try chat.binary(&.{ 1, 2, 3 });

    const talk = try chat.open(&app, "/ws");
    try testing.expect(talk.accepted());
    // The handshake every client checks, worked out from the key RFC 6455
    // §1.3 uses.
    try testing.expectEqualStrings(
        Conversation.accept_for_key,
        talk.header("Sec-WebSocket-Accept").?,
    );

    try testing.expectEqual(@as(usize, 3), talk.messages.len);
    try testing.expectEqualStrings("one", talk.at(0).?.bytes);
    try testing.expectEqual(Kind.text, talk.at(1).?.kind);
    try testing.expectEqualStrings("two", talk.at(1).?.bytes);
    try testing.expectEqual(Kind.binary, talk.at(2).?.kind);
}

test "a ping is answered with a pong carrying the same bytes" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    try chat.ping("are you there");

    // The handler's loop never sees a ping — `receive` answers it on the way
    // past — so this is a behaviour no test could reach before.
    const talk = try chat.open(&app, "/ws");
    const pong = talk.first(.pong).?;
    try testing.expectEqualStrings("are you there", pong.bytes);
}

test "a close from the client is answered and ends the loop" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    try chat.text("last thing");
    try chat.close(1000, "bye");
    // Anything after the close is not read, because the conversation is over.
    try chat.text("ignored");

    const talk = try chat.open(&app, "/ws");
    try testing.expectEqualStrings("last thing", talk.at(0).?.bytes);
    try testing.expectEqual(@as(u16, 1000), talk.closedWith().?);
}

test "a fragmented message arrives as one" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    try chat.fragments(.text, &.{ "one ", "two ", "three" });

    const talk = try chat.open(&app, "/ws");
    try testing.expectEqual(@as(usize, 1), talk.messages.len);
    try testing.expectEqualStrings("one two three", talk.at(0).?.bytes);
}

test "a message past the ceiling is refused before it is read" {
    // The loop ends in a failure on purpose, and App logs it — correctly, and
    // to the test runner's stderr, where it reads like a broken suite.
    const previous = testing.log_level;
    defer testing.log_level = previous;
    testing.log_level = .err;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsSmall);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    try chat.text("this is longer than eight bytes");

    const talk = try chat.open(&app, "/ws");
    try testing.expectEqual(@as(u16, 1009), talk.closedWith().?);
}

test "a frame a client did not mask is a protocol error, said rather than hung up on" {
    const previous = testing.log_level;
    defer testing.log_level = previous;
    testing.log_level = .err;

    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    // FIN + text, five bytes, no mask bit. RFC 6455 §5.1 requires a client to
    // mask, and `raw` is how a test says something no client library would.
    try chat.raw("\x81\x05Hello");

    const talk = try chat.open(&app, "/ws");
    try testing.expectEqual(@as(u16, 1002), talk.closedWith().?);
}

test "a handshake the route refuses is a status and no frames at all" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/ws", wsEcho);

    var chat: Conversation = try .init(testing.allocator, .{});
    defer chat.deinit();
    // A page nobody named, on a host that is not this one (ADR 0102).
    try chat.setHeader("Origin", "https://elsewhere.example.com");
    try chat.text("hello");

    const talk = try chat.open(&app, "/ws");
    try testing.expect(!talk.accepted());
    try testing.expectEqual(@as(u16, 403), talk.status);
    try testing.expectEqual(@as(usize, 0), talk.messages.len);
}

fn plain(c: *@import("ctx.zig").Ctx) anyerror!void {
    try c.setStaticHeader("X-Note", "hello");
    try c.sendText(201, "body text");
}

fn streamed(c: *@import("ctx.zig").Ctx) anyerror!void {
    var body = try c.stream(200, "text/plain");
    try body.writeAll("one ");
    try body.flush();
    try body.writeAll("two");
    try body.finish();
}

test "an ordinary answer is taken apart into status, headers and body" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/thing", plain);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/thing");
    try testing.expectEqual(@as(u16, 201), answer.status);
    try testing.expectEqualStrings("hello", answer.header("X-Note").?);
    try testing.expectEqualStrings("text/plain", answer.header("content-type").?);
    try testing.expect(answer.header("X-Absent") == null);
    try testing.expectEqualStrings("body text", answer.body);
    try testing.expect(answer.keep_alive);
    try testing.expect(!answer.chunked);
}

test "a chunked answer reassembles into what the handler wrote" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/stream", streamed);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    const answer = try client.get(&app, "/stream");
    try testing.expect(answer.chunked);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one two", try answer.text(&buf));
}

fn echoHeaders(c: *@import("ctx.zig").Ctx) anyerror!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    var it = c.headers();
    while (it.next()) |h| {
        try out.print(testing.allocator, "{s}={s};", .{ h.name.view(), h.value.view() });
    }
    try c.sendText(200, out.items);
}

test "a header can be sent for one request, or for every request" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/echo", echoHeaders);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    // Per request.
    const one = try client.sendRequest(&app, .{
        .path = "/echo",
        .headers = &.{.{ .name = "X-One", .value = "1" }},
    });
    try testing.expect(std.mem.indexOf(u8, one.body, "X-One=1;") != null);

    // Sticky, and gone from the next request only if it is taken off.
    try client.setHeader("Authorization", "Bearer first");
    try client.setHeader("Authorization", "Bearer second");
    const two = try client.get(&app, "/echo");
    try testing.expect(std.mem.indexOf(u8, two.body, "Authorization=Bearer second;") != null);
    // Set twice, sent once.
    try testing.expect(std.mem.indexOf(u8, two.body, "Bearer first") == null);
    try testing.expect(std.mem.indexOf(u8, two.body, "X-One") == null);

    // A `Host` of the caller's own replaces the default rather than joining
    // it, which two `Host` lines would make a 400 (ADR 0101).
    const three = try client.sendRequest(&app, .{
        .path = "/echo",
        .headers = &.{.{ .name = "Host", .value = "elsewhere" }},
    });
    try testing.expectEqual(@as(u16, 200), three.status);
    try testing.expect(std.mem.indexOf(u8, three.body, "Host=elsewhere;") != null);
    try testing.expect(std.mem.indexOf(u8, three.body, "Host=test;") == null);
}

fn signIn(c: *@import("ctx.zig").Ctx) anyerror!void {
    try c.setCookie(.{ .name = "session", .value = "abc123", .path = "/" });
    try c.sendText(200, "in");
}

fn signOut(c: *@import("ctx.zig").Ctx) anyerror!void {
    try c.clearCookie(.{ .name = "session" });
    try c.sendText(200, "out");
}

fn whoami(c: *@import("ctx.zig").Ctx) anyerror!void {
    const sent = c.header("Cookie") orelse return c.sendText(200, "nobody");
    try c.sendText(200, sent.view());
}

test "a client with a jar signs in once and stays signed in" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);
    try app.post("/sign-out", signOut);
    try app.get("/me", whoami);

    var client = try Client.init(testing.allocator, .{ .cookies = true });
    defer client.deinit();

    try testing.expectEqualStrings("nobody", (try client.get(&app, "/me")).body);

    _ = try client.post(&app, "/sign-in", "");
    try testing.expectEqualStrings("abc123", client.cookie("session").?);
    // What used to need copying the `Set-Cookie` out of one answer and pasting
    // it into the next request by hand, which is what `examples/forms` does.
    try testing.expectEqualStrings("session=abc123", (try client.get(&app, "/me")).body);

    // And a removal empties the jar rather than sending a cookie the server
    // has just told the client to drop.
    _ = try client.post(&app, "/sign-out", "");
    try testing.expect(client.cookie("session") == null);
    try testing.expectEqualStrings("nobody", (try client.get(&app, "/me")).body);
}

test "a client without a jar sends no cookie, which is what shipped" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.post("/sign-in", signIn);
    try app.get("/me", whoami);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    _ = try client.post(&app, "/sign-in", "");
    try testing.expect(client.cookie("session") == null);
    try testing.expectEqualStrings("nobody", (try client.get(&app, "/me")).body);
}

test "a client can be used for more than one request" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/thing", plain);

    var client = try Client.init(testing.allocator, .{});
    defer client.deinit();

    for (0..3) |_| {
        const answer = try client.get(&app, "/thing");
        try testing.expectEqual(@as(u16, 201), answer.status);
    }
}

/// A service function of the kind this repository is written for: no `Ctx`,
/// refusing four different ways, called by a handler and by a seed alike.
fn editComment(author_matches: bool, empty: bool) fail.Error!void {
    if (empty) return fail.unprocessable("a comment with nothing in it is not an edit", .{});
    if (!author_matches) return fail.conflict("editing somebody else's comment", .{});
}

test "a refusal outside a request keeps its status and its sentence" {
    // Before this, both were dropped: `current()` is null with no request in
    // flight, so four different refusals were four identical `error.Failed`s
    // and a test could only say "it failed" (ADR 0161).
    var refusals: Refusals = .{};
    refusals.begin();
    defer refusals.end();

    try testing.expect(refusals.caught() == null);

    try testing.expectError(error.Failed, editComment(false, false));
    const said = refusals.caught() orelse return error.NothingCaught;
    try testing.expectEqual(@as(u16, 409), said.status);
    try testing.expectEqualStrings("editing somebody else's comment", said.message);

    // The other way the same function refuses, which is the whole point: two
    // calls, two sentences, one error type.
    refusals.clear();
    try testing.expectError(error.Failed, editComment(true, true));
    const second = refusals.caught() orelse return error.NothingCaught;
    try testing.expectEqual(@as(u16, 422), second.status);
    try testing.expectEqualStrings("a comment with nothing in it is not an edit", second.message);

    // And a call that refuses nothing leaves nothing behind.
    refusals.clear();
    try editComment(true, false);
    try testing.expect(refusals.caught() == null);
}

test "the slot goes back to whatever held it, so one test cannot leak into the next" {
    var outer: fail.InFlight = .{};
    const before = bulkhead.setFallbackSlot(@ptrCast(&outer));
    defer _ = bulkhead.setFallbackSlot(before);

    {
        var refusals: Refusals = .{};
        refusals.begin();
        defer refusals.end();
        try testing.expectError(error.Failed, editComment(false, false));
        // The refusal went to the Refusals rather than to what was installed
        // before it.
        try testing.expect(!outer.failure.isSet());
    }

    try testing.expectEqual(@as(?*anyopaque, @ptrCast(&outer)), bulkhead.slot());
}


test "show calls a type's own rendering where {any} refuses to" {
    // Stands in for `Uuid`, which this module may not import — `http/` sees
    // `nilo_core` and no other tool module (ADR 0042). What is being held is
    // the property, not the type: a value that knows how to write itself
    // gets to, where `{any}` prints the bytes it is made of.
    const Key = struct {
        bytes: [4]u8,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            var text: [8]u8 = undefined;
            _ = std.fmt.bufPrint(&text, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                self.bytes[0], self.bytes[1], self.bytes[2], self.bytes[3],
            }) catch unreachable;
            try jw.write(&text);
        }
    };
    const Row = struct { key: Key, name: []const u8 };

    const row: Row = .{ .key = .{ .bytes = .{ 0x01, 0x8b, 0xcf, 0xe5 } }, .name = "wati" };

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{show(row)});

    // What a person can read: the key as its own text, and the name as a
    // string rather than as four byte values.
    try std.testing.expectEqualStrings("{\"key\":\"018bcfe5\",\"name\":\"wati\"}", w.buffered());

    // And the thing this exists to replace, for the contrast: `{any}` prints
    // both of them as the numbers they are made of.
    var noisy: [256]u8 = undefined;
    var n = std.Io.Writer.fixed(&noisy);
    try n.print("{any}", .{row});
    try std.testing.expect(std.mem.indexOf(u8, n.buffered(), "119, 97, 116, 105") != null);
}

test "show writes into whatever is formatting it, and allocates nothing" {
    const Small = struct { n: u32 };

    // No allocator anywhere, which is what lets this go inside a
    // `std.debug.print` while somebody is poking about.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.print("{f}", .{show(Small{ .n = 7 })});
    try std.testing.expectEqualStrings("{\"n\":7}", w.buffered());
}
