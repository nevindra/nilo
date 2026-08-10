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
const http1 = @import("http1.zig");
const router = @import("router.zig");
const service_mod = @import("service.zig");
const static_mod = @import("static.zig");
const str_mod = @import("str.zig");
const percent = @import("percent.zig");
const Str = str_mod.Str;

/// The ceiling on a request body read into the arena. A per-App limit
/// comes later; for now, one number that makes sense.
pub const max_body = 1024 * 1024;

/// The size `sendJson` reserves before serialising. Not a limit — a
/// bigger response simply grows past it.
pub const json_hint = 512;

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
    _body: ?[]const u8 = null,
    /// Set when reading the body went wrong in a way that leaves the
    /// connection at an unknown byte. App reads it and does not reuse the
    /// connection.
    _stream_desynced: bool = false,
    _sent: bool = false,
    /// The status actually sent, once something has been. 0 until then.
    _status: u16 = 0,
    _extra_headers: std.ArrayList(http1.Header) = .empty,

    /// The service of type `P` (a pointer type), for handlers that hold a
    /// `*Ctx` and so do not go through argument matching. Null if it was
    /// never registered — in the typed layer that case is already filtered
    /// out by `listen()`.
    pub fn service(self: *const Ctx, comptime P: type) ?P {
        return self._services.get(P);
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

    /// Parse the request body as JSON into `T`. The result lives in the
    /// request arena — `keep` the fields you need for longer.
    ///
    /// `Str` fields get stamped with the request lifetime, so using one
    /// after the request has finished trips the debug trap just like any
    /// other Str (ADR 0004).
    pub fn json(self: *Ctx, comptime T: type) !T {
        const b = (try self.body()).view();
        var value = try std.json.parseFromSliceLeaky(T, self._arena, b, .{});
        str_mod.stamp(&value, self._lifetime);
        return value;
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
            self._request.keep_alive,
            self._extra_headers.items,
        );
        try http1.writeResponse(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body,
            self._request.keep_alive,
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
};

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
