//! Ctx — one request in flight, and all the control over it. This is
//! zfast's real API (ADR 0003): the typed layer above it turns into calls
//! to this while compiling.
//!
//! Every piece of text coming out of Ctx is a `Str`: it lives as long as
//! the request, and is copied deliberately with `.keep()` if it needs to
//! live longer (ADR 0004). Fields prefixed with `_` belong to zfast's
//! internals — the request arena behind them is never touched directly by
//! users.

const std = @import("std");
const body_mod = @import("body.zig");
const http1 = @import("http1.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const static_mod = @import("static.zig");
const stream_mod = @import("stream.zig");
const str_mod = @import("str.zig");
const websocket = @import("websocket.zig");
const percent = @import("percent.zig");
const fail = @import("fail.zig");
const Str = str_mod.Str;

/// The ceiling on a request body read into the arena. A per-App limit
/// comes later; for now, one number that makes sense.
pub const max_body = 1024 * 1024;

/// The size `sendJson` reserves before serialising. Not a limit — a
/// bigger response simply grows past it.
pub const json_hint = 512;

/// One resolved value, kept for the rest of the request that asked for it.
///
/// Keyed by type name rather than by anything cleverer for the same reason
/// the service registry is (ADR 0006): the list is two entries long in
/// practice, and `@typeName` is normally the very same literal, so finding
/// one is a pointer compare.
const Resolved = struct {
    type_name: []const u8,
    value: *anyopaque,
};

pub const Ctx = struct {
    method: http1.Method,

    _arena: std.mem.Allocator,
    _lifetime: *const str_mod.Lifetime,
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _request: *const http1.Request,
    _path: []const u8,
    /// The query string as it arrived, still encoded. `_query_params` is
    /// the decoded form and is what `query()` reads.
    _query: []const u8,
    _query_params: []const router.Param = &.{},
    /// The whole request head, request line included. Headers are read out
    /// of it on demand rather than collected up front — most handlers ask
    /// for none, and the ones that ask, ask for two.
    _head: []const u8,
    _params: []const router.Param,
    _services: *const service_mod.Registry,
    /// Set by App when the path names a file in a static set, so the
    /// terminal handler does not have to look it up a second time.
    _static_file: ?*const static_mod.File = null,
    /// The methods that do answer this path, when the one asked for does
    /// not. Set by App only on the way to a 405, which is the one answer
    /// that has to list them.
    _allowed: router.MethodSet = .initEmpty(),
    /// Set while the server is stopping, so a response can say so. Null
    /// when App is driven directly by a test, where nothing is stopping.
    _stopping: ?*const std.atomic.Value(bool) = null,
    _body: ?[]const u8 = null,
    /// Set when the handler asked to read the body in pieces, and how far it
    /// got. App reads it to discard whatever is left (ADR 0020).
    _incoming: ?body_mod.Progress = null,
    /// Set when reading the body went wrong in a way that leaves the
    /// connection at an unknown byte. App reads it and does not reuse the
    /// connection.
    _stream_desynced: bool = false,
    _sent: bool = false,
    /// Set between `stream()` and the stream's `finish()`, which clears it.
    /// App reads it to find a body nobody ended (ADR 0020).
    _stream: ?stream_mod.Open = null,
    /// Set when the response cannot share its connection with another
    /// request whatever the client asked for — an unframed HTTP/1.0 stream,
    /// where the end of the body *is* the end of the connection.
    _force_close: bool = false,
    /// The status actually sent, once something has been. 0 until then.
    _status: u16 = 0,
    _extra_headers: std.ArrayList(http1.Header) = .empty,
    /// Resolved values already worked out for this request (ADR 0016).
    /// Stays empty — and costs nothing — on a request that asks for none.
    _resolved: std.ArrayList(Resolved) = .empty,

    /// The service of type `P` (a pointer type), for handlers that hold a
    /// `*Ctx` and so do not go through argument matching. Null if it was
    /// never registered — in the typed layer that case is already filtered
    /// out by `listen()`.
    pub fn service(self: *const Ctx, comptime P: type) ?P {
        return self._services.get(P);
    }

    /// The resolved value of type `V` for this request — worked out now if
    /// nobody has asked yet, and handed back as-is if they have (ADR 0016).
    ///
    /// A handler gets these by writing the type in its argument list and
    /// never calls this. What it is here for is middleware, which has no
    /// argument list to write in:
    ///
    /// ```zig
    /// fn requireAdmin(c: *zfast.Ctx, next: zfast.Next) !void {
    ///     const user = try c.resolve(CurrentUser);
    ///     if (!user.is_admin) return zfast.fail.forbidden("admins only", .{});
    ///     try next.run(c);
    /// }
    /// ```
    ///
    /// The handler behind that middleware can then take a `CurrentUser` of
    /// its own without authenticating a second time.
    pub fn resolve(self: *Ctx, comptime V: type) !V {
        // Imported here rather than at the top of the file: resolve.zig
        // needs Ctx, and asking for it from inside the function body keeps
        // the two out of each other's way.
        return @import("resolve.zig").value(V, self);
    }

    /// The resolved value of type `V` if this request has already worked one
    /// out. zfast's own; users go through `resolve`.
    pub fn cachedResolved(self: *const Ctx, comptime V: type) ?V {
        const wanted = @typeName(V);
        for (self._resolved.items) |entry| {
            if (entry.type_name.ptr != wanted.ptr and !std.mem.eql(u8, entry.type_name, wanted))
                continue;
            return @as(*const V, @ptrCast(@alignCast(entry.value))).*;
        }
        return null;
    }

    /// Remember a resolved value for the rest of this request. zfast's own.
    ///
    /// The value is copied into the request arena, so it dies with the
    /// request exactly as every `Str` inside it does.
    pub fn cacheResolved(self: *Ctx, comptime V: type, resolved: V) !void {
        const box = try self._arena.create(V);
        box.* = resolved;
        // Two is the shape this has in practice — a user, and something
        // worked out from the user — so the list is sized for that once
        // rather than grown twice.
        if (self._resolved.capacity == 0) {
            try self._resolved.ensureTotalCapacity(self._arena, 2);
        }
        try self._resolved.append(self._arena, .{
            .type_name = @typeName(V),
            .value = @ptrCast(box),
        });
    }

    // ---- the request side ----

    pub fn path(self: *const Ctx) Str {
        return Str.fromRequest(self._path, self._lifetime);
    }

    /// A path param from the route pattern: `/users/:id` → `param("id")`.
    /// Percent-decoded, so `/users/wati%20sari` gives `wati sari`.
    pub fn param(self: *const Ctx, name: []const u8) ?Str {
        for (self._params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
    }

    /// A query param, percent-decoded: `/search?q=hello%20world` →
    /// `query("q")` is `hello world`. A `+` counts as a space, the way an
    /// HTML form encodes one.
    pub fn query(self: *const Ctx, name: []const u8) ?Str {
        for (self._query_params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
    }

    /// A request header, name matched case-insensitively.
    ///
    /// Read straight out of the head each time rather than from a list
    /// built in advance. A list would mean an allocation on every request
    /// including the many that never look at a header at all, to save a
    /// scan of a few hundred bytes on the few that look twice.
    pub fn header(self: *const Ctx, name: []const u8) ?Str {
        var headers = http1.HeaderIterator.from(self._head);
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return Str.fromRequest(h.value, self._lifetime);
        }
        return null;
    }

    /// The whole request body, read once into the request arena. Chunked
    /// and Content-Length look the same from here — the handler asks for
    /// the body, not for the way it arrived.
    pub fn body(self: *Ctx) !Str {
        if (self._body == null) {
            if (self._request.chunked) {
                self._body = http1.readChunkedBody(self._in, self._arena, max_body) catch |err| {
                    // The chunk sizes and the stream have come apart, so
                    // where this body ends is now a guess. Reading on and
                    // hoping to land on the next request is exactly how a
                    // smuggled request gets through — even when the bytes
                    // happen to line up, which they sometimes will.
                    self._stream_desynced = true;
                    return err;
                };
            } else {
                if (self._request.content_length > max_body) return error.BodyTooLarge;
                const b = try self._arena.alloc(u8, @intCast(self._request.content_length));
                try self._in.readSliceAll(b);
                self._body = b;
            }
        }
        return Str.fromRequest(self._body.?, self._lifetime);
    }

    /// The request body, read in pieces rather than all at once — for the
    /// ones too big to hold (ADR 0020).
    ///
    /// ```zig
    /// var incoming = try c.bodyStream();
    /// var buf: [64 * 1024]u8 = undefined;
    /// while (try incoming.read(&buf)) |part| try file.writeAll(part);
    /// ```
    ///
    /// Memory is the buffer you pass in and nothing else: this allocates
    /// not one byte, where `body()` reads the whole thing into the request
    /// arena and refuses past a megabyte. Content-Length and chunked look
    /// the same from here, as they do to `body()`.
    ///
    /// A body left half-read is fine — App discards the rest so the
    /// connection is clean for the next request.
    pub fn bodyStream(self: *Ctx) !body_mod.Body {
        return self.bodyStreamWith(.{});
    }

    /// `bodyStream`, with a different ceiling on how much body to accept.
    pub fn bodyStreamWith(self: *Ctx, options: body_mod.Options) !body_mod.Body {
        // Asking twice would hand out two readers into one stream, and the
        // second would get whatever the first left.
        std.debug.assert(self._body == null and self._incoming == null);

        // A Content-Length says up front how big it is, so a body over the
        // limit is refused before a byte of it is read. A chunked one has to
        // be counted as it arrives.
        if (!self._request.chunked and self._request.content_length > options.max_bytes) {
            return error.BodyTooLarge;
        }

        self._incoming = .start(self._request, options.max_bytes);
        return .init(self._in, &self._incoming.?);
    }

    /// Parse the request body as JSON into `T`. The result lives in the
    /// request arena — `keep` the fields you need for longer.
    ///
    /// `Str` fields get stamped with the request lifetime, so using one
    /// after the request has finished trips the debug trap just like any
    /// other Str (ADR 0004).
    pub fn json(self: *Ctx, comptime T: type) !T {
        const b = (try self.body()).view();
        var value = std.json.parseFromSliceLeaky(T, self._arena, b, .{}) catch |err|
            return describeBadBody(T, self._arena, b, err);
        str_mod.stamp(&value, self._lifetime);
        return value;
    }

    /// Whether this connection is offered for another request.
    ///
    /// Checked when the response is written rather than when the request
    /// was read, because a stop can land in between — a handler that was
    /// halfway through when Ctrl-C was pressed still finishes, and the
    /// answer it sends has to admit that the socket is about to go. A
    /// client told `keep-alive` by a process that is leaving spends its
    /// next request finding out otherwise.
    pub fn keepAlive(self: *const Ctx) bool {
        if (self._force_close) return false;
        if (!self._request.keep_alive) return false;
        const stopping = self._stopping orelse return true;
        return !stopping.load(.acquire);
    }

    // ---- the response side ----

    /// Add a response header. Set it before sending — a response is
    /// flushed the moment it is sent, so there is nothing left to change
    /// afterwards (ADR 0009).
    ///
    /// `name` and `value` are copied into the request arena, so passing a
    /// value you built on the stack is safe. Setting a header the
    /// framework writes itself — Content-Type, Content-Length, Connection
    /// — is refused: a response carrying two of those is malformed, and in
    /// the case of Content-Length it is a request-smuggling bug.
    /// Content-Type is chosen through `send` instead.
    pub fn setHeader(self: *Ctx, name: []const u8, value: []const u8) !void {
        return self.putHeader(.{
            .name = try self._arena.dupe(u8, name),
            .value = try self._arena.dupe(u8, value),
        });
    }

    /// `setHeader` for text that already outlives the request — a literal,
    /// or something a Service owns — so nothing is copied.
    ///
    /// This is what the built-in middleware use: CORS's header values are
    /// compile-time constants and a static file's ETag belongs to the file,
    /// so copying either into the request arena is work with no purpose.
    ///
    /// Hand it something built on the stack and the response goes out with
    /// whatever those bytes have become. When in doubt, `setHeader`.
    pub fn setStaticHeader(self: *Ctx, name: []const u8, value: []const u8) !void {
        return self.putHeader(.{ .name = name, .value = value });
    }

    fn putHeader(self: *Ctx, entry: http1.Header) !void {
        if (http1.isReservedHeader(entry.name)) return error.ReservedHeader;
        for (self._extra_headers.items) |*h| {
            if (std.ascii.eqlIgnoreCase(h.name, entry.name)) {
                h.* = entry; // last one wins, rather than sending both
                return;
            }
        }
        // Room for a few in one go: CORS alone sets two or three, and
        // growing one at a time would mean an allocation for each.
        if (self._extra_headers.capacity == 0) {
            try self._extra_headers.ensureTotalCapacity(self._arena, 4);
        }
        try self._extra_headers.append(self._arena, entry);
    }

    pub fn send(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        std.debug.assert(!self._sent); // one request, one response
        self._sent = true;
        self._status = status;
        // A handler need not know this is a HEAD: it assembles a response
        // as usual, and what must not go out is filtered here.
        if (self.method == .HEAD) return http1.writeResponseHeadOnly(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body.len,
            self.keepAlive(),
            self._extra_headers.items,
        );
        try http1.writeResponse(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body,
            self.keepAlive(),
            self._extra_headers.items,
        );
    }

    pub fn sendText(self: *Ctx, status: u16, text: []const u8) !void {
        try self.send(status, "text/plain", text);
    }

    /// Serialise `value` to JSON (through the request arena) and send it.
    ///
    /// The buffer starts at `json_hint` rather than at nothing, so a
    /// response of ordinary size is assembled in one allocation instead of
    /// a handful of doublings. Overshooting costs nothing: the arena is
    /// emptied when the request ends either way.
    pub fn sendJson(self: *Ctx, status: u16, value: anytype) !void {
        var out: std.Io.Writer.Allocating = try .initCapacity(self._arena, json_hint);
        try std.json.Stringify.value(value, .{}, &out.writer);
        try self.send(status, "application/json", out.written());
    }

    // ---- answering in pieces ----

    /// Start a response whose length is not known yet, and get back
    /// something to write the pieces into (ADR 0020).
    ///
    /// ```zig
    /// var body = try c.stream(200, "text/csv");
    /// for (rows) |row| try body.print("{s},{d}\n", .{ row.name, row.total });
    /// try body.finish();
    /// ```
    ///
    /// The head goes out immediately, so every `setHeader` has to be called
    /// before this. `finish()` is required: it writes the marker saying
    /// where the body ends.
    pub fn stream(self: *Ctx, status: u16, content_type: []const u8) !stream_mod.Stream {
        return self.streamWith(status, content_type, .{});
    }

    /// `stream`, with the buffer size turned up or down.
    pub fn streamWith(
        self: *Ctx,
        status: u16,
        content_type: []const u8,
        options: stream_mod.Options,
    ) !stream_mod.Stream {
        std.debug.assert(!self._sent); // one request, one response

        // HTTP/1.0 has no chunked framing, so the end of the body can only
        // be the end of the connection — which means this connection cannot
        // carry another request whatever either side asked for.
        const chunked = self._request.minor_version == 1;
        if (!chunked) self._force_close = true;

        self._sent = true;
        self._status = status;
        self._stream = .{ .chunked = chunked, .drop = self.method == .HEAD };

        try http1.writeStreamHead(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            chunked,
            self.keepAlive(),
            self._extra_headers.items,
        );

        // The one allocation a stream makes, made once. Everything written
        // afterwards goes through this buffer and allocates nothing.
        const buffer = try self._arena.alloc(u8, options.buffer);
        return .init(buffer, self._out, self._stopping, &self._stream);
    }

    /// Start a stream of server-sent events — a `text/event-stream` a
    /// browser reads with `new EventSource(url)`.
    ///
    /// ```zig
    /// var events = try c.events();
    /// while (events.live()) try events.send(.{ .name = "tick", .data = "." });
    /// try events.close();
    /// ```
    ///
    /// The two headers past the content type are what keep an event stream
    /// working through the things between the handler and the browser:
    /// `Cache-Control: no-cache` so nothing stores it, and
    /// `X-Accel-Buffering: no` so an nginx in front does not hold the events
    /// back waiting for a buffer to fill.
    /// Turn this request into a WebSocket connection (ADR 0022).
    ///
    /// ```zig
    /// fn echo(c: *zfast.Ctx) !void {
    ///     var socket = try c.upgrade();
    ///     var buf: [4096]u8 = undefined;
    ///     while (try socket.receive(&buf)) |message| {
    ///         try socket.send(message.kind, message.data);
    ///     }
    /// }
    /// ```
    ///
    /// A request that is not asking to be upgraded is refused with a 400
    /// saying which part is missing, rather than left to fail as framing
    /// nobody can read.
    ///
    /// After this the connection is no longer HTTP and cannot carry another
    /// request, which zfast arranges — the handler only has to return.
    pub fn upgrade(self: *Ctx) !websocket.Socket {
        return self.upgradeWith(.{});
    }

    /// `upgrade`, agreeing to a sub-protocol.
    pub fn upgradeWith(self: *Ctx, options: websocket.Options) !websocket.Socket {
        std.debug.assert(!self._sent); // one request, one response

        if (self.method != .GET) {
            return fail.badRequest("a WebSocket handshake has to be a GET, not a {s}", .{@tagName(self.method)});
        }
        if (!websocket.isUpgrade(self._head)) {
            return fail.badRequest(
                "this endpoint is a WebSocket; the request needs Upgrade: websocket and Connection: Upgrade",
                .{},
            );
        }
        const version = self.header("Sec-WebSocket-Version") orelse
            return fail.badRequest("the handshake is missing Sec-WebSocket-Version", .{});
        // 13 is the only version there has ever been in the published RFC.
        if (!std.mem.eql(u8, version.view(), "13")) {
            return fail.badRequest(
                "this server speaks WebSocket version 13, and the request asked for \"{s}\"",
                .{version.view()},
            );
        }
        const key = self.header("Sec-WebSocket-Key") orelse
            return fail.badRequest("the handshake is missing Sec-WebSocket-Key", .{});

        // From here the answer is written, so nothing above may fail.
        self._sent = true;
        self._status = 101;
        // The connection stops being HTTP at the blank line below, so it can
        // never carry another request.
        self._force_close = true;

        const answer = websocket.accept(key.view());
        try websocket.writeAcceptance(self._out, &answer, options.protocol);

        return .{ ._in = self._in, ._out = self._out, ._stopping = self._stopping };
    }

    pub fn events(self: *Ctx) !stream_mod.Events {
        try self.setStaticHeader("Cache-Control", "no-cache");
        try self.setStaticHeader("X-Accel-Buffering", "no");
        return .{ .stream = try self.stream(200, stream_mod.Events.content_type) };
    }
};

// ---- saying what is wrong with a request body ----
//
// A query param that does not fit gets `?page has to be a whole number, not
// "soon"`. A body field that does not fit used to get `Bad Request`, and
// nothing else — same framework, same request, two completely different
// standards. What follows closes that gap.
//
// std.json reports `error.UnknownField` without saying which field, and
// that name is the whole of what the person holding the curl command needs.
// So on the failure path — and only there — the body is read a second time
// as a plain `std.json.Value` and compared against `T` field by field.
// Paying for a second parse to explain a request that was already going to
// be refused is a trade worth making; a body that parses never comes here.

/// Turn a failed body parse into a 400 that names what is wrong with it,
/// falling back to `err` when nothing here can do better.
///
/// Only the top level is described. A field inside a nested object that
/// does not fit still becomes a plain 400 — naming it would mean walking
/// two shapes at once, for the least common of these mistakes.
fn describeBadBody(
    comptime T: type,
    arena: std.mem.Allocator,
    body: []const u8,
    err: anyerror,
) anyerror {
    // Anything but a struct is somebody using `Ctx.json` directly for a
    // list or a number, where there are no field names to talk about.
    if (@typeInfo(T) != .@"struct") return err;

    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return fail.badRequest(
        "the request body is empty. This endpoint expects a JSON object with: {s}",
        .{comptime fieldList(T)},
    );

    // Read again with no shape to satisfy. If even this fails, the text is
    // not JSON at all, and where it stopped making sense is the useful part.
    var scanner = std.json.Scanner.initCompleteInput(arena, body);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);

    const dynamic = std.json.parseFromTokenSourceLeaky(
        std.json.Value,
        arena,
        &scanner,
        .{},
    ) catch return fail.badRequest(
        "the request body is not valid JSON — it stops making sense at line {d}, column {d}",
        .{ diagnostics.getLine(), diagnostics.getColumn() },
    );

    if (dynamic != .object) return fail.badRequest(
        "the request body has to be a JSON object with: {s} — this is {s}",
        .{ comptime fieldList(T), kindOf(dynamic) },
    );
    const object = dynamic.object;

    // Something the body carries that the endpoint has no room for. Almost
    // always a typo, which is why the known names go out with it.
    //
    // Asked before "what is missing", because a typo is both at once —
    // `{"nme":"wati"}` has an unknown `nme` and is missing `name` — and of
    // those two true sentences, the one quoting what was actually typed is
    // the one that ends the search.
    var it = object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!hasField(T, name)) return fail.badRequest(
            "the request body has a field \"{s}\" this endpoint does not know. It takes: {s}",
            .{ name, comptime fieldList(T) },
        );
    }

    // Something the endpoint needs that the body does not carry. A field
    // with a default is what "absent" is allowed to mean, so it is exempt —
    // the same rule a query struct follows.
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (f.default_value_ptr == null and !object.contains(f.name)) return fail.badRequest(
            "the request body is missing \"{s}\" ({s})",
            .{ f.name, comptime expectedOf(f.type) },
        );
    }

    // Everything is present and nothing is spare, so a value is the wrong
    // shape for the field it landed in.
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (object.get(f.name)) |given| {
            if (!fits(f.type, given)) return fail.badRequest(
                "\"{s}\" has to be {s}, not {s}",
                .{ f.name, comptime expectedOf(f.type), kindOf(given) },
            );
        }
    }

    return err;
}

/// What a JSON value is, in the words an error message wants.
fn kindOf(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "true or false",
        .integer, .float, .number_string => "a number",
        .string => "text",
        .array => "a list",
        .object => "an object",
    };
}

/// What a field will accept, in those same words.
fn expectedOf(comptime T: type) []const u8 {
    comptime {
        if (T == Str) return "text";
        return switch (@typeInfo(T)) {
            .optional => |o| expectedOf(o.child) ++ " or null",
            .bool => "true or false",
            .int, .comptime_int => "a whole number",
            .float, .comptime_float => "a number",
            .@"enum" => |e| blk: {
                var out: []const u8 = "one of ";
                for (e.fields, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f.name;
                break :blk out;
            },
            .@"struct" => "an object",
            .pointer => |p| if (p.size == .slice and p.child == u8) "text" else "a list",
            else => "something this endpoint understands",
        };
    }
}

/// The field names of `T`, for saying what the endpoint does take.
fn fieldList(comptime T: type) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
            out = out ++ (if (i == 0) "" else ", ") ++ f.name;
            if (f.default_value_ptr != null) out = out ++ " (optional)";
        }
        return out;
    }
}

fn hasField(comptime T: type, name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return true;
    }
    return false;
}

/// Whether a JSON value could have become a `T`. Loose on purpose: it is
/// only ever asked about a parse std.json has already refused, so its job is
/// to find the field that explains the refusal, not to re-decide it.
fn fits(comptime T: type, value: std.json.Value) bool {
    if (T == Str) return value == .string;
    return switch (@typeInfo(T)) {
        .optional => |o| value == .null or fits(o.child, value),
        .bool => value == .bool,
        .int, .float => value == .integer or value == .float or value == .number_string,
        // A string that is not one of the names is the whole reason an enum
        // field fails, so the tag has to be checked and not just the kind.
        .@"enum" => value == .string and std.meta.stringToEnum(T, value.string) != null,
        .@"struct" => value == .object,
        .pointer => |p| if (p.size == .slice and p.child == u8) value == .string else value == .array,
        else => true,
    };
}

/// Split a query string into decoded name/value pairs, in the request
/// arena. Called once per request that has one; a request without a `?`
/// never gets here and pays nothing.
///
/// Splitting happens before decoding, so a `%26` inside a value stays an
/// `&` of data instead of becoming a pair separator.
pub fn parseQuery(arena: std.mem.Allocator, raw: []const u8) ![]const router.Param {
    if (raw.len == 0) return &.{};

    var list: std.ArrayList(router.Param) = .empty;
    var pairs = std.mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue; // "a=1&&b=2" and a trailing "&"
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        try list.append(arena, .{
            .name = try percent.decode(arena, pair[0..equals], true),
            .value = if (equals < pair.len)
                try percent.decode(arena, pair[equals + 1 ..], true)
            else
                "",
        });
    }
    return list.items;
}

/// Decode the path params a match produced, in place in the match's own
/// array. Only a value that actually carries an escape allocates.
pub fn decodeParams(arena: std.mem.Allocator, params: []router.Param) !void {
    for (params) |*p| p.value = try percent.decode(arena, p.value, false);
}

const testing = std.testing;

test "query pairs are split first, then decoded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const params = try parseQuery(arena.allocator(), "q=hello%20world&tag=a%26b&plus=a+b&bare&empty=");
    try testing.expectEqual(@as(usize, 5), params.len);
    try testing.expectEqualStrings("hello world", params[0].value);
    // Encoded as %26, so it is one value containing an ampersand — not the
    // separator between two pairs.
    try testing.expectEqualStrings("a&b", params[1].value);
    try testing.expectEqualStrings("a b", params[2].value);
    try testing.expectEqualStrings("", params[3].value);
    try testing.expectEqualStrings("", params[4].value);
}

test "an empty query string parses to nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try parseQuery(arena.allocator(), "")).len);
}
