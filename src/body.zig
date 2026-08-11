//! Reading a request body in pieces, for the ones too big to hold (ADR 0020).
//!
//! ```zig
//! fn upload(c: *zfast.Ctx, store: *Store) !Receipt {
//!     var incoming = try c.bodyStream();
//!     var buf: [64 * 1024]u8 = undefined;
//!     while (try incoming.read(&buf)) |part| try store.append(part);
//!     return .{ .bytes = incoming.seen };
//! }
//! ```
//!
//! `c.body()` reads the whole thing into the request arena and refuses past
//! a megabyte, which is right for a JSON body and wrong for a file. This is
//! the other one: memory is bounded by the buffer the handler passes in, and
//! **nothing is allocated at all** — not even the one buffer a response
//! stream takes, because a body reader has somewhere to put bytes already.
//!
//! Content-Length and chunked look the same from here, the same way they do
//! to `Ctx.body`. The handler asks for the body, not for the way it arrived.

const std = @import("std");

const http1 = @import("http1.zig");

pub const Options = struct {
    /// The most a body may be. A `Content-Length` past this is refused
    /// before a byte is read; a chunked body is counted as it arrives and
    /// stopped when it crosses.
    ///
    /// There has to be a number. A chunked body announces no size, so
    /// "however much they send" is a client's decision about the server's
    /// memory and time — and the default is a file upload's worth rather
    /// than an invitation.
    max_bytes: u64 = 64 * 1024 * 1024,
};

pub const Error = error{
    /// More body than `Options.max_bytes` allows.
    BodyTooLarge,
    /// The chunk sizes and the stream have come apart. Where this body ends
    /// is now a guess, so the connection cannot be reused.
    BadChunk,
    ReadFailed,
    EndOfStream,
    WriteFailed,
};

/// How far through a body the reader has got. Lives on the `Ctx` rather than
/// on the `Body`, because the `Body` is on the handler's stack and App has to
/// finish what the handler left when it has returned.
pub const Progress = struct {
    state: State,
    seen: u64 = 0,
    max_bytes: u64,
    /// What the request said the body would be, or null for a chunked one.
    /// Kept separately from `state`, so asking after the body has been read
    /// still answers — the first version worked it out from what was left,
    /// and went null the moment there was nothing left.
    announced: ?u64,

    pub const State = union(enum) {
        /// Bytes still to come in a Content-Length body.
        sized: u64,
        /// Bytes still to come in the chunk being read.
        chunk: u64,
        /// Between chunks: the next thing on the wire is a size line.
        between,
        /// The body is over and the connection is at the next request.
        done,
        /// Something went wrong in a way that leaves the connection at an
        /// unknown byte. Nothing may be read from it again.
        broken,
    };

    pub fn start(request: *const http1.Request, max_bytes: u64) Progress {
        return .{
            .state = if (request.chunked)
                .between
            else if (request.content_length == 0)
                .done
            else
                .{ .sized = request.content_length },
            .max_bytes = max_bytes,
            .announced = if (request.chunked) null else request.content_length,
        };
    }

    pub fn finished(self: Progress) bool {
        return self.state == .done;
    }
};

/// A request body, arriving in pieces.
pub const Body = struct {
    /// The body as a `std.Io.Reader`, for handing to something in the
    /// standard library. Unbuffered on purpose: a body reader is asked for
    /// runs of bytes, never for a line or a peek, and an unbuffered one
    /// allocates nothing.
    reader: std.Io.Reader,

    /// The connection.
    _in: *std.Io.Reader,
    /// The `Ctx`'s record of how far this has got.
    _progress: *Progress,

    /// The next piece of the body, or null once there is none.
    ///
    /// The slice is `buf`, so it is the caller's memory and lives exactly as
    /// long as the caller decides. Nothing here is copied twice.
    pub fn read(self: *Body, buf: []u8) Error!?[]u8 {
        var out: std.Io.Writer = .fixed(buf);
        const n = self.reader.stream(&out, .limited(buf.len)) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return self.explain(e),
        };
        return buf[0..n];
    }

    /// Pump the whole body into `w`, returning how many bytes that was.
    /// The shortest way to put an upload somewhere.
    pub fn writeTo(self: *Body, w: *std.Io.Writer) Error!u64 {
        var total: u64 = 0;
        while (true) {
            const n = self.reader.stream(w, .unlimited) catch |err| switch (err) {
                error.EndOfStream => return total,
                else => |e| return self.explain(e),
            };
            total += n;
        }
    }

    /// Read and throw away the rest, so the connection is clean. App calls
    /// this for a handler that read part of a body and stopped.
    pub fn discardRest(self: *Body) Error!void {
        while (true) {
            _ = self.reader.discard(.unlimited) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return self.explain(e),
            };
        }
    }

    /// How many bytes of body have been read so far.
    pub fn seen(self: *const Body) u64 {
        return self._progress.seen;
    }

    /// How long the body is, when it said so up front. Null for a chunked
    /// one, which is the whole reason chunked exists.
    ///
    /// Answers the same before, during and after reading.
    pub fn size(self: *const Body) ?u64 {
        return self._progress.announced;
    }

    /// Turn the one error the `Reader` interface can carry back into the one
    /// that actually happened. `stream` may only fail with `ReadFailed`, so
    /// what went wrong is recorded on the way past and read back here.
    fn explain(self: *Body, err: anyerror) Error {
        if (self._progress.state == .broken) {
            return if (self._progress.seen > self._progress.max_bytes)
                error.BodyTooLarge
            else
                error.BadChunk;
        }
        return switch (err) {
            error.ReadFailed => error.ReadFailed,
            error.WriteFailed => error.WriteFailed,
            else => error.ReadFailed,
        };
    }

    /// zfast's own: `Ctx.bodyStream` builds one of these.
    pub fn init(in: *std.Io.Reader, progress: *Progress) Body {
        return .{
            .reader = .{
                .vtable = &.{ .stream = streamFn, .discard = discardFn },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            ._in = in,
            ._progress = progress,
        };
    }

    /// How many bytes may be taken straight from the connection right now,
    /// advancing past chunk framing as needed. Zero means the body is over.
    fn runLength(self: *Body) error{ReadFailed}!u64 {
        const p = self._progress;
        while (true) switch (p.state) {
            .sized => |left| return left,
            .chunk => |left| {
                if (left > 0) return left;
                // The CRLF after a chunk's data. Anything else and the sizes
                // and the stream have drifted apart, which is how a smuggled
                // request gets through.
                http1.endOfChunk(self._in) catch return self.breakOff();
                p.state = .between;
            },
            .between => {
                const size_of_chunk = http1.readChunkSize(self._in) catch return self.breakOff();
                if (size_of_chunk == 0) {
                    http1.skipTrailers(self._in) catch return self.breakOff();
                    p.state = .done;
                    return 0;
                }
                if (p.seen + size_of_chunk > p.max_bytes) {
                    p.seen += size_of_chunk;
                    return self.breakOff();
                }
                p.state = .{ .chunk = size_of_chunk };
            },
            .done => return 0,
            .broken => return error.ReadFailed,
        };
    }

    fn breakOff(self: *Body) error{ReadFailed} {
        self._progress.state = .broken;
        return error.ReadFailed;
    }

    fn advance(self: *Body, n: u64) void {
        const p = self._progress;
        p.seen += n;
        switch (p.state) {
            .sized => |*left| {
                left.* -= n;
                if (left.* == 0) p.state = .done;
            },
            .chunk => |*left| left.* -= n,
            else => {},
        }
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Body = @alignCast(@fieldParentPtr("reader", r));
        const run = try self.runLength();
        if (run == 0) return error.EndOfStream;
        const n = try self._in.stream(w, limit.min(.limited64(run)));
        self.advance(n);
        return n;
    }

    fn discardFn(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
        const self: *Body = @alignCast(@fieldParentPtr("reader", r));
        const run = try self.runLength();
        if (run == 0) return error.EndOfStream;
        const n = try self._in.discard(limit.min(.limited64(run)));
        self.advance(n);
        return n;
    }
};

// ---- tests ----

const testing = std.testing;

const Case = struct {
    in: std.Io.Reader,
    progress: Progress,

    fn init(self: *Case, wire: []const u8, request: http1.Request, max_bytes: u64) void {
        self.in = .fixed(wire);
        self.progress = .start(&request, max_bytes);
    }

    fn body(self: *Case) Body {
        return .init(&self.in, &self.progress);
    }
};

fn sized(len: u64) http1.Request {
    return .{ .content_length = len };
}

const chunked_request = http1.Request{ .chunked = true };

test "a Content-Length body arrives in pieces and stops at the right byte" {
    var case: Case = undefined;
    case.init("hello world!next", sized(12), 1024);
    var incoming = case.body();

    try testing.expectEqual(@as(?u64, 12), incoming.size());

    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectEqualStrings(" worl", (try incoming.read(&buf)).?);
    try testing.expectEqualStrings("d!", (try incoming.read(&buf)).?);
    try testing.expectEqual(@as(?[]u8, null), try incoming.read(&buf));
    try testing.expectEqual(@as(u64, 12), incoming.seen());

    // The connection is left at the next request, not one byte off.
    try testing.expect(case.progress.finished());
    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "a chunked body is de-framed, and its size is not known up front" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\nnext", chunked_request, 1024);
    var incoming = case.body();

    try testing.expectEqual(@as(?u64, null), incoming.size());

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const total = try incoming.writeTo(&out.writer);

    try testing.expectEqualStrings("hello, world", out.written());
    try testing.expectEqual(@as(u64, 12), total);

    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "a read can land in the middle of a chunk" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n", chunked_request, 1024);
    var incoming = case.body();

    // Four bytes at a time through chunks of five and seven: the framing is
    // not something the handler's buffer size has to line up with.
    var buf: [4]u8 = undefined;
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    while (try incoming.read(&buf)) |part| try seen.appendSlice(testing.allocator, part);

    try testing.expectEqualStrings("hello, world", seen.items);
}

test "an empty body is over before it starts" {
    var case: Case = undefined;
    case.init("", sized(0), 1024);
    var incoming = case.body();

    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(?[]u8, null), try incoming.read(&buf));
    try testing.expectEqual(@as(u64, 0), incoming.seen());
}

test "a chunked body past the limit is refused rather than swallowed" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n", chunked_request, 8);
    var incoming = case.body();

    var buf: [16]u8 = undefined;
    // The first chunk fits under the limit; the second is what crosses it,
    // and it is refused before its bytes are read.
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectError(error.BodyTooLarge, incoming.read(&buf));
    try testing.expectEqual(Progress.State.broken, case.progress.state);
}

test "chunk sizes that have come apart from the stream stop the reader" {
    var case: Case = undefined;
    // The chunk says five bytes and there is no CRLF where one has to be.
    case.init("5\r\nhelloXX\r\n0\r\n\r\n", chunked_request, 1024);
    var incoming = case.body();

    var buf: [5]u8 = undefined;
    try testing.expectEqualStrings("hello", (try incoming.read(&buf)).?);
    try testing.expectError(error.BadChunk, incoming.read(&buf));
    try testing.expectEqual(Progress.State.broken, case.progress.state);
}

test "the rest of a body nobody wanted is discarded, and the connection survives" {
    var case: Case = undefined;
    case.init("5\r\nhello\r\n7\r\n, world\r\n0\r\n\r\nnext", chunked_request, 1024);
    var incoming = case.body();

    var buf: [3]u8 = undefined;
    _ = try incoming.read(&buf);
    try incoming.discardRest();

    try testing.expect(case.progress.finished());
    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "reading nothing and then discarding is the same as never asking" {
    var case: Case = undefined;
    case.init("hello worldnext", sized(11), 1024);
    var incoming = case.body();
    try incoming.discardRest();

    var rest: [4]u8 = undefined;
    try case.in.readSliceAll(&rest);
    try testing.expectEqualStrings("next", &rest);
}

test "the announced size is still there after the body has been read" {
    var case: Case = undefined;
    case.init("hello world!", sized(12), 1024);
    var incoming = case.body();

    var buf: [16]u8 = undefined;
    while (try incoming.read(&buf)) |_| {}

    // Worked out from what was left, this went null the moment the body
    // ended — which is exactly when a handler wants to report on it.
    try testing.expectEqual(@as(?u64, 12), incoming.size());
    try testing.expectEqual(@as(u64, 12), incoming.seen());
}
