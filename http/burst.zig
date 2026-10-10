//! The buffer a connection writes a burst of answers into, so the burst
//! leaves in writes of 32 KiB rather than a write for every answer
//! (ADR 285).
//!
//! **Why it exists.** A connection's write buffer is a page (`write_buffer`,
//! 4 KiB), because it is most of what an idle connection costs (ADR 062). An
//! HTTP/2 answer larger than the room left in it does not wait for the
//! connection's flush: `std.Io.Writer` drains the buffer and the body together
//! at once. So a burst of thirty-two 4 KB JSON answers left as about thirty
//! writes, and the client paid a read for each: on HttpArena's `json-h2c` nilo
//! sent 6.2 KB a TCP segment against the leader's 50.8 KB, and the load
//! generator spent 3.4 times its CPU a request reading nilo
//! (`bench/result/http.md`, "Why the board's HTTP/2 run sat below the rig's
//! projection").
//!
//! **What it does.** While a connection answers a burst it writes into this
//! buffer instead of its page, and the buffer goes to the connection's writer
//! when it is full and at the flush the connection makes before it waits. On
//! a plain socket a full buffer is one `writev` with what the page held ahead
//! of it; over TLS it is sealed into as few records and writes as the record
//! buffer allows.
//!
//! **What it costs, and when.** `size` bytes from the allocator's largest
//! slab class, taken by the first answer of `smallest` to `largest` bytes of
//! body that does not fit the room left in the page, and given back by the
//! flush (`h2conn.Conn.flushOut`). An idle connection never holds one, so
//! memory per idle connection does not move. A connection answering such a
//! burst holds 32 KiB while the burst is in it, and copies each answer once
//! more than it did.
//!
//! **Which answers take it.** Only those that were a write each. Answers
//! under `smallest` fill a page dozens at a time, so a page's write already
//! carries many (a unary gRPC call took 2.70 µs with the buffer against
//! 2.37 without). A body of `largest` or more is a frame's worth, written
//! from where it lies (`framing.Collected.borrow_from`); copying it here
//! first cost static files over TLS 11% at 1,024 connections.
//!
//! **Rejected, both measured** (`bench/result/http.md`, "A burst of HTTP/2
//! answers leaves in writes of 32 KiB"). Lending each body to a vectored
//! write at the flush instead of copying it: the body lives in its stream's
//! arena, so the stream could not be recycled until the flush, every request
//! in a burst made a stream and an arena of its own where one was reused, and
//! the server's CPU a request rose from 5.99 to 7.30 µs while the client's
//! fell. A larger `write_buffer`: 4.35 µs against this buffer's 4.59, but
//! every connection, HTTP/1.1 and idle ones included, would hold it for its
//! whole life, and past 32 KiB it is a mapping of its own, so every
//! connection opened would be an `mmap`. A burst buffer of 12 KiB: 6.05 µs,
//! no better than the page, since it is a write for every three answers.

const std = @import("std");

const Writer = std.Io.Writer;

pub const Burst = struct {
    /// The connection's writer, which everything ends up in.
    inner: *Writer,
    gpa: std.mem.Allocator,
    /// What the connection writes into while the burst lasts.
    interface: Writer,
    buffer: [buffer_len]u8 = undefined,

    /// What one `Burst` weighs: the allocator's largest slab class. One byte
    /// more and every burst would be a `mmap` and a `munmap`.
    pub const size = 32 * 1024;
    /// The bodies that take a burst's buffer: from `smallest` up to, and not
    /// including, `largest` bytes.
    pub const smallest = 1024;
    pub const largest = 16 * 1024;
    const buffer_len = size - @sizeOf(Header);
    const Header = struct { inner: *Writer, gpa: std.mem.Allocator, interface: Writer };

    comptime {
        std.debug.assert(@sizeOf(Burst) <= size);
    }

    const vtable: Writer.VTable = .{ .drain = drain, .flush = flush };

    pub fn create(gpa: std.mem.Allocator, inner: *Writer) error{OutOfMemory}!*Burst {
        const b = try gpa.create(Burst);
        b.* = .{ .inner = inner, .gpa = gpa, .interface = .{ .vtable = &vtable, .buffer = &.{} } };
        b.interface.buffer = &b.buffer;
        return b;
    }

    /// Give the buffer back. Anything written and not yet sent is dropped,
    /// which is right only once a flush has sent it or the peer has gone.
    pub fn destroy(b: *Burst) void {
        b.gpa.destroy(b);
    }

    /// Whether anything written is still to be sent.
    pub fn pending(b: *const Burst) bool {
        return b.interface.end != 0;
    }

    fn of(w: *Writer) *Burst {
        return @alignCast(@fieldParentPtr("interface", w));
    }

    /// Hand what is buffered to the connection's writer. Emptied whether or
    /// not it worked: a write that failed has a peer that is gone.
    fn send(b: *Burst) Writer.Error!void {
        defer b.interface.end = 0;
        if (b.interface.end != 0) try b.inner.writeAll(b.buffer[0..b.interface.end]);
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const b = of(w);
        try b.send();
        // The buffer is empty again: what fits is copied into it by the
        // caller, and what does not goes down now, behind what was just sent.
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |d| count += d.len;
        count += data[data.len - 1].len * splat;
        if (count <= w.buffer.len) return 0;
        return b.inner.writeSplat(data, splat);
    }

    fn flush(w: *Writer) Writer.Error!void {
        const b = of(w);
        try b.send();
        try b.inner.flush();
    }
};

// ---- tests ----

const testing = std.testing;

/// A socket's writer, to the extent a test needs one: a buffer of `cap`
/// bytes, and every drain counted as one write of what it was handed.
const Sink = struct {
    interface: Writer,
    got: std.ArrayList(u8) = .empty,
    writes: usize = 0,
    storage: [4096]u8 = undefined,

    fn init(s: *Sink, cap: usize) void {
        s.* = .{ .interface = .{ .vtable = &.{ .drain = sinkDrain }, .buffer = &.{} } };
        s.interface.buffer = s.storage[0..cap];
    }

    fn deinit(s: *Sink) void {
        s.got.deinit(testing.allocator);
    }

    fn sinkDrain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *Sink = @alignCast(@fieldParentPtr("interface", w));
        s.writes += 1;
        s.got.appendSlice(testing.allocator, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            s.got.appendSlice(testing.allocator, d) catch return error.WriteFailed;
            n += d.len;
        }
        for (0..splat) |_| {
            s.got.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }
};

test "a burst of answers larger than the page leaves a write for every 32 KiB, in order" {
    var sink: Sink = undefined;
    sink.init(4096);
    defer sink.deinit();
    const b = try Burst.create(testing.allocator, &sink.interface);
    defer b.destroy();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    var body: [3000]u8 = undefined;
    for (0..32) |i| {
        @memset(&body, @intCast('a' + i % 26));
        const head = [_]u8{ 'h', @intCast('0' + i % 10) };
        try b.interface.writeAll(&head);
        try b.interface.writeAll(&body);
        try expected.appendSlice(testing.allocator, &head);
        try expected.appendSlice(testing.allocator, &body);
    }
    try b.interface.flush();
    try testing.expectEqualStrings(expected.items, sink.got.items);
    // 96 KB through a 4 KiB page was a write for every answer or so. Here
    // it is one each time the next answer does not fit what is left of the
    // buffer, and one at the flush.
    const per_write = (Burst.buffer_len / (body.len + 2)) * (body.len + 2);
    try testing.expectEqual(expected.items.len / per_write + 1, sink.writes);
    try testing.expect(!b.pending());
}

test "a write larger than the burst's buffer goes down whole, behind what was buffered" {
    var sink: Sink = undefined;
    sink.init(512);
    defer sink.deinit();
    const b = try Burst.create(testing.allocator, &sink.interface);
    defer b.destroy();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    const big: [Burst.buffer_len + 5]u8 = @splat('z');
    var small: [700]u8 = undefined;
    for (0..40) |i| {
        @memset(&small, @intCast(i));
        const piece = small[0 .. 1 + (i * 97) % small.len];
        try b.interface.writeAll(piece);
        try expected.appendSlice(testing.allocator, piece);
        if (i % 7 == 0) {
            try b.interface.writeAll(&big);
            try expected.appendSlice(testing.allocator, &big);
        }
    }
    try b.interface.flush();
    try testing.expectEqualSlices(u8, expected.items, sink.got.items);
}

test "a splat written through the burst is repeated where it was written" {
    var sink: Sink = undefined;
    sink.init(64);
    defer sink.deinit();
    const b = try Burst.create(testing.allocator, &sink.interface);
    defer b.destroy();

    try b.interface.writeAll("<");
    try b.interface.splatByteAll('-', Burst.buffer_len + 10);
    try b.interface.writeAll(">");
    try b.interface.flush();
    try testing.expectEqual(@as(usize, Burst.buffer_len + 12), sink.got.items.len);
    try testing.expectEqual(@as(u8, '<'), sink.got.items[0]);
    for (sink.got.items[1 .. Burst.buffer_len + 11]) |c| try testing.expectEqual(@as(u8, '-'), c);
    try testing.expectEqual(@as(u8, '>'), sink.got.items[sink.got.items.len - 1]);
}

test "what the page held before the burst began goes out ahead of it" {
    var sink: Sink = undefined;
    sink.init(4096);
    defer sink.deinit();
    try sink.interface.writeAll("first ");
    const b = try Burst.create(testing.allocator, &sink.interface);
    defer b.destroy();
    const body: [5000]u8 = @splat('q');
    try b.interface.writeAll(&body);
    try b.interface.writeAll(" last");
    try b.interface.flush();
    try testing.expectEqualStrings("first ", sink.got.items[0..6]);
    try testing.expectEqualSlices(u8, &body, sink.got.items[6..5006]);
    try testing.expectEqualStrings(" last", sink.got.items[5006..]);
    try testing.expectEqual(@as(usize, 1), sink.writes);
}
