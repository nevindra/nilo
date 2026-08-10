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
const str_mod = @import("str.zig");
const Str = str_mod.Str;

/// The ceiling on a request body read into the arena. A per-App limit
/// comes later; for now, one number that makes sense.
pub const max_body = 1024 * 1024;

pub const Ctx = struct {
    method: http1.Method,

    _arena: std.mem.Allocator,
    _lifetime: *const str_mod.Lifetime,
    _in: *std.Io.Reader,
    _out: *std.Io.Writer,
    _request: *const http1.Request,
    _path: []const u8,
    _query: []const u8,
    _headers: []const http1.HeaderIterator.Pair,
    _params: []const router.Param,
    _services: *const service_mod.Registry,
    _body: ?[]const u8 = null,
    _sent: bool = false,

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
    pub fn param(self: *const Ctx, name: []const u8) ?Str {
        for (self._params) |p| {
            if (std.mem.eql(u8, p.name, name)) return Str.fromRequest(p.value, self._lifetime);
        }
        return null;
    }

    /// A query param: `/search?word=zig` → `query("word")`.
    /// Note: percent-decoding is not in yet.
    pub fn query(self: *const Ctx, name: []const u8) ?Str {
        var pairs = std.mem.splitScalar(u8, self._query, '&');
        while (pairs.next()) |p| {
            const equals = std.mem.indexOfScalar(u8, p, '=') orelse p.len;
            if (std.mem.eql(u8, p[0..equals], name)) {
                const value = if (equals < p.len) p[equals + 1 ..] else "";
                return Str.fromRequest(value, self._lifetime);
            }
        }
        return null;
    }

    /// A request header, name matched case-insensitively.
    pub fn header(self: *const Ctx, name: []const u8) ?Str {
        for (self._headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return Str.fromRequest(h.value, self._lifetime);
        }
        return null;
    }

    /// The whole request body, read once into the request arena.
    pub fn body(self: *Ctx) !Str {
        if (self._body == null) {
            if (self._request.chunked) return error.ChunkedNotSupported;
            if (self._request.content_length > max_body) return error.BodyTooLarge;
            const b = try self._arena.alloc(u8, @intCast(self._request.content_length));
            try self._in.readSliceAll(b);
            self._body = b;
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

    pub fn send(self: *Ctx, status: u16, content_type: []const u8, response_body: []const u8) !void {
        std.debug.assert(!self._sent); // one request, one response
        self._sent = true;
        // A handler need not know this is a HEAD: it assembles a response
        // as usual, and what must not go out is filtered here.
        if (self.method == .HEAD) return http1.writeResponseHeadOnly(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body.len,
            self._request.keep_alive,
        );
        try http1.writeResponse(
            self._out,
            status,
            http1.statusPhrase(status),
            content_type,
            response_body,
            self._request.keep_alive,
        );
    }

    pub fn sendText(self: *Ctx, status: u16, text: []const u8) !void {
        try self.send(status, "text/plain", text);
    }

    /// Serialise `value` to JSON (through the request arena) and send it.
    pub fn sendJson(self: *Ctx, status: u16, value: anytype) !void {
        const b = try std.json.Stringify.valueAlloc(self._arena, value, .{});
        try self.send(status, "application/json", b);
    }
};
