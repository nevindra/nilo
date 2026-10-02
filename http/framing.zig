//! The framing an answer leaves in: what `Ctx` hands a response to, so that
//! nothing above this file writes the bytes of one protocol (ADR 253).
//!
//! `Ctx` decides what the answer is, a status, a type, the headers a route
//! set and a body that is whole, streamed or a file, and whether the
//! connection can carry another request. How that is put on the wire is the
//! framing's: a status line, `Connection`, chunks and `settle` for HTTP/1.1;
//! frames and trailers for HTTP/2.
//!
//! **A tagged union with two arms, not a `Ctx` generic over its transport.**
//! A generic `Ctx` would compile every handler once per framing and spend the
//! size axis on it (ADR 017); the union costs one compare of a tag a write,
//! which the branch predictor never misses on a connection that only ever
//! has one arm. **The HTTP/2 arm exists only in a build that asked for gRPC**:
//! without `-Dgrpc` its type is `noreturn`, the tag is known while compiling,
//! and the union is the HTTP/1.1 arm and nothing else, so the default build
//! pays not even the compare.
//!
//! **The HTTP/2 arm collects the answer whole.** A call's answer is framed by
//! the connection's fiber, never by the call's (ADR 220), so this arm keeps
//! what `Ctx` hands it in the request arena for that fiber to frame. A stream,
//! a file and an interim answer are not collected yet, and say so: they need
//! a pipe from the call's fiber to the connection's with the client's window
//! in between, which is the roadmap's second direction.
//!
//! A WebSocket and an event stream handed to the connection loop stay HTTP/1.1
//! only: both take the connection's reader and writer for their whole life,
//! which `wire` gives them, and a multiplexed connection has none to give.

const std = @import("std");
const http1 = @import("http1.zig");
const grpc_built = @import("nilo_build").grpc;

pub const Header = http1.Header;

pub const Framing = union(enum) {
    http1: Http1,
    http2: if (grpc_built) *Collected else noreturn,

    /// A whole answer, written and settled. `head_only` is a HEAD: the head a
    /// GET would get, its `Content-Length` the length of `body`, and no body.
    /// `keep` is whether the connection carries another request after this.
    pub fn whole(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        body: []const u8,
        head_only: bool,
        keep: bool,
        extra: []const Header,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.whole(status, content_type, body, head_only, keep, extra),
            .http2 => |c| if (comptime !grpc_built) unreachable else return c.whole(status, content_type, body, head_only, extra),
        }
    }

    /// The head of an answer of `len` bytes and none of them: a HEAD of a
    /// file, which has a length and no slice to take it from.
    pub fn head(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.head(status, content_type, len, keep, extra),
            .http2 => |c| if (comptime !grpc_built) unreachable else return c.head(status, content_type, extra),
        }
    }

    /// How a stream of `length` bytes, or of a length nobody knows, is told
    /// apart from the next answer. Asked before the head is written, because
    /// `Ctx` keeps the answer on its `Open` record.
    pub fn streamShape(self: *const Framing, length: ?u64) StreamShape {
        return switch (self.*) {
            .http1 => |h| h.streamShape(length),
            // Asked for, and never used: `streamHead`, which comes next,
            // refuses. A shape is still an answer, so nothing here has to be
            // optional.
            .http2 => if (comptime !grpc_built) unreachable else .{ .chunked = false, .ends_connection = false },
        };
    }

    pub fn streamHead(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        shape: StreamShape,
        length: ?u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        switch (self.*) {
            .http1 => |*h| return h.streamHead(status, content_type, shape, length, keep, extra),
            .http2 => if (comptime !grpc_built) unreachable else return error.NotCollected,
        }
    }

    /// One piece of a streamed body: what the stream's buffer held, then
    /// `data` with its last slice written `splat` times, the shape of a
    /// `std.Io.Writer` drain.
    pub fn piece(self: *Framing, chunked: bool, buffered: []const u8, data: []const []const u8, splat: usize) !void {
        switch (self.*) {
            .http1 => |*h| return h.piece(chunked, buffered, data, splat),
            .http2 => if (comptime !grpc_built) unreachable else return error.NotCollected,
        }
    }

    /// Put what has been written on the wire.
    pub fn flush(self: *Framing) !void {
        switch (self.*) {
            .http1 => |*h| return h.out.flush(),
            .http2 => if (comptime !grpc_built) unreachable else return,
        }
    }

    /// End a streamed body, with the marker that ends it when it has one.
    pub fn end(self: *Framing, marked: bool) !void {
        switch (self.*) {
            .http1 => |*h| return h.end(marked),
            .http2 => if (comptime !grpc_built) unreachable else return,
        }
    }

    /// The head, then `len` bytes of the file `reader` is at. What it returns
    /// is what was sent, which is short only when the file was cut under the
    /// transfer.
    pub fn file(
        self: *Framing,
        status: u16,
        content_type: []const u8,
        reader: *std.Io.File.Reader,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !u64 {
        switch (self.*) {
            .http1 => |*h| return h.file(status, content_type, reader, len, keep, extra),
            .http2 => if (comptime !grpc_built) unreachable else return error.NotCollected,
        }
    }

    /// `100 Continue`, for a client that asked to be told before it sends its
    /// body (RFC 9110 §10.1.1). Nothing on HTTP/2, whose body has arrived by
    /// the time a call is collected.
    pub fn interimContinue(self: *Framing) !void {
        switch (self.*) {
            .http1 => |*h| return h.interimContinue(),
            .http2 => if (comptime !grpc_built) unreachable else return,
        }
    }

    /// The connection itself, for a WebSocket or an event stream that takes
    /// it over for the rest of its life. Null on a framing that has no
    /// connection of one request's own to give.
    pub fn wire(self: *const Framing) ?Http1 {
        return switch (self.*) {
            .http1 => |h| h,
            .http2 => if (comptime !grpc_built) unreachable else null,
        };
    }
};

/// How a streamed body ends.
pub const StreamShape = struct {
    /// Each piece carries its own length and a last, empty one ends the body.
    chunked: bool,
    /// Nothing marks the end but the connection closing, so it cannot carry
    /// another request: HTTP/1.0 with no length given.
    ends_connection: bool,
};

/// HTTP/1.1, and HTTP/1.0 where it differs: the bytes `http1.zig` writes.
pub const Http1 = struct {
    /// The connection's reader, read here only to know whether the next
    /// request is already in (`settle`).
    in: *std.Io.Reader,
    out: *std.Io.Writer,
    minor_version: u1,

    fn connection(self: *const Http1, keep: bool) http1.Connection {
        return .of(keep, self.minor_version);
    }

    fn whole(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        body: []const u8,
        head_only: bool,
        keep: bool,
        extra: []const Header,
    ) !void {
        if (head_only) {
            try http1.writeResponseHeadOnly(self.out, status, http1.statusPhrase(status), content_type, body.len, self.connection(keep), extra);
        } else {
            try http1.writeResponse(self.out, status, http1.statusPhrase(status), content_type, body, self.connection(keep), extra);
        }
        // On the wire now, unless the client has pipelined the next request
        // behind this one, in which case it goes out with that one's answer
        // (ADR 201).
        try http1.settle(self.out, self.in);
    }

    fn head(self: *Http1, status: u16, content_type: []const u8, len: u64, keep: bool, extra: []const Header) !void {
        try http1.writeResponseHeadOnly(self.out, status, http1.statusPhrase(status), content_type, len, self.connection(keep), extra);
        try http1.settle(self.out, self.in);
    }

    /// A length already says where the body stops, so there is nothing for
    /// chunked framing to add and a head must not carry both. Otherwise
    /// HTTP/1.1 gets chunks; HTTP/1.0 has neither, so the end of the body can
    /// only be the end of the connection.
    fn streamShape(self: Http1, length: ?u64) StreamShape {
        const chunked = length == null and self.minor_version == 1;
        return .{ .chunked = chunked, .ends_connection = !chunked and length == null };
    }

    fn streamHead(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        shape: StreamShape,
        length: ?u64,
        keep: bool,
        extra: []const Header,
    ) !void {
        try http1.writeStreamHead(self.out, status, http1.statusPhrase(status), content_type, shape.chunked, length, self.connection(keep), extra);
    }

    fn piece(self: *Http1, chunked: bool, buffered: []const u8, data: []const []const u8, splat: usize) !void {
        var total = buffered.len;
        for (data[0 .. data.len - 1]) |slice| total += slice.len;
        const pattern = data[data.len - 1];
        total += pattern.len * splat;

        if (chunked) try http1.writeChunkHeader(self.out, total);
        if (buffered.len > 0) try self.out.writeAll(buffered);
        for (data[0 .. data.len - 1]) |slice| try self.out.writeAll(slice);
        for (0..splat) |_| try self.out.writeAll(pattern);
        if (chunked) try http1.endChunk(self.out);
    }

    fn end(self: *Http1, marked: bool) !void {
        if (marked) try http1.writeLastChunk(self.out);
        try self.out.flush();
    }

    fn file(
        self: *Http1,
        status: u16,
        content_type: []const u8,
        reader: *std.Io.File.Reader,
        len: u64,
        keep: bool,
        extra: []const Header,
    ) !u64 {
        // Left in the write buffer on purpose: `sendFileAll` sends what is
        // already buffered ahead of the file's first bytes, so the head and
        // the start of the body leave together (ADR 009).
        try http1.writeFileHead(self.out, status, http1.statusPhrase(status), content_type, len, self.connection(keep), extra);

        // A loop rather than one call, because a `std.Io.Limit` is a `usize`
        // and the length of a file is not: on a 32-bit build `limited64`
        // clamps, and without this a four-gigabyte download would look like
        // a truncated file. On a 64-bit build it goes round once.
        // `sendFileAll` is short only at the end of the file, so nothing sent
        // means there is no more file.
        var sent: u64 = 0;
        while (sent < len) {
            const n = try self.out.sendFileAll(reader, .limited64(len - sent));
            if (n == 0) break;
            sent += n;
        }
        try self.out.flush();
        return sent;
    }

    fn interimContinue(self: *Http1) !void {
        // An HTTP/1.0 client cannot be sent an interim response (RFC 9110
        // §15.2).
        if (self.minor_version == 0) return;
        try self.out.writeAll("HTTP/1.1 100 Continue\r\n\r\n");
        try self.out.flush();
    }
};

/// An answer kept for the connection's fiber to frame (ADR 220): what a
/// route handed `Ctx`, copied into the request arena because the slices it
/// came in, a handler's buffer and the headers inline in `Ctx`, are gone by
/// the time that fiber reads it.
pub const Collected = struct {
    arena: std.mem.Allocator,
    status: u16 = 0,
    content_type: []const u8 = "",
    headers: []const Header = &.{},
    body: []const u8 = "",

    fn whole(self: *Collected, status: u16, content_type: []const u8, body: []const u8, head_only: bool, extra: []const Header) !void {
        try self.head(status, content_type, extra);
        if (!head_only and !http1.bodyless(status)) self.body = try self.arena.dupe(u8, body);
    }

    fn head(self: *Collected, status: u16, content_type: []const u8, extra: []const Header) !void {
        self.status = status;
        self.content_type = try self.arena.dupe(u8, content_type);
        const headers = try self.arena.alloc(Header, extra.len);
        for (extra, headers) |from, *to| to.* = .{
            .name = try self.arena.dupe(u8, from.name),
            .value = try self.arena.dupe(u8, from.value),
        };
        self.headers = headers;
    }
};

// ---- tests ----

const testing = std.testing;

fn wired(out: *std.Io.Writer, in: *std.Io.Reader, minor_version: u1) Framing {
    return .{ .http1 = .{ .in = in, .out = out, .minor_version = minor_version } };
}

test "a whole answer on HTTP/1.1 is the bytes http1 writes, and a closing one says so" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.whole(200, "text/plain", "hi", false, false, &.{});
    const written = out.buffered();
    try testing.expect(std.mem.startsWith(u8, written, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(std.mem.indexOf(u8, written, "Connection: close\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, written, "\r\n\r\nhi"));
}

test "a HEAD on HTTP/1.1 carries the length of the body it does not send" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.whole(200, "text/plain", "hello", true, true, &.{});
    const written = out.buffered();
    try testing.expect(std.mem.indexOf(u8, written, "Content-Length: 5\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n"));
}

test "a stream on HTTP/1.0 with no length ends with the connection, and one with a length does not" {
    var buf: [8]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    const old = wired(&out, &in, 0);
    try testing.expectEqual(StreamShape{ .chunked = false, .ends_connection = true }, old.streamShape(null));
    try testing.expectEqual(StreamShape{ .chunked = false, .ends_connection = false }, old.streamShape(10));
    const new = wired(&out, &in, 1);
    try testing.expectEqual(StreamShape{ .chunked = true, .ends_connection = false }, new.streamShape(null));
}

test "a chunked piece is framed by its whole length, the splat included" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var framing = wired(&out, &in, 1);
    try framing.piece(true, "ab", &.{ "c", "-" }, 3);
    try framing.end(true);
    try testing.expectEqualStrings("6\r\nabc---\r\n0\r\n\r\n", out.buffered());
}

test "an HTTP/1.0 client is never sent a 100 Continue" {
    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    var in: std.Io.Reader = .fixed("");
    var old = wired(&out, &in, 0);
    try old.interimContinue();
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
    var new = wired(&out, &in, 1);
    try new.interimContinue();
    try testing.expectEqualStrings("HTTP/1.1 100 Continue\r\n\r\n", out.buffered());
}

test "an answer collected for HTTP/2 outlives the buffers it was handed in" {
    if (comptime !grpc_built) return error.SkipZigTest;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var collected: Collected = .{ .arena = arena_state.allocator() };
    var framing: Framing = .{ .http2 = &collected };

    var body = "message".*;
    var name = "grpc-status".*;
    var value = "0".*;
    try framing.whole(200, "application/grpc", &body, false, true, &.{.{ .name = &name, .value = &value }});
    @memset(&body, 'x');
    @memset(&name, 'x');
    @memset(&value, 'x');

    try testing.expectEqual(@as(u16, 200), collected.status);
    try testing.expectEqualStrings("message", collected.body);
    try testing.expectEqualStrings("grpc-status", collected.headers[0].name);
    try testing.expectEqualStrings("0", collected.headers[0].value);
    try testing.expect(framing.wire() == null);
    try testing.expectError(error.NotCollected, framing.streamHead(200, "text/plain", .{ .chunked = false, .ends_connection = false }, null, true, &.{}));
}
