//! Where a JSON answer is written before it is sent (ADR 278).
//!
//! `sendJson` used to write into `Writer.Allocating.initCapacity(arena, 512)`,
//! which doubles when it fills. In an arena that is not a cheap thing to do:
//! a node that cannot grow in place is replaced by one 1.5 times the size of
//! everything before it, so the nodes for a 9 KB answer climbed past 64 KiB,
//! the size where the allocator hands out pages directly, and the arena that
//! kept a few KiB across requests (`arena_keep`, and 4 KiB for an HTTP/2
//! stream) gave them back and asked again the next time. On the arena's
//! `json-h2c` profile that was an `mmap` and a `munmap` a request, and a
//! quarter of the server's samples (`bench/result/http.md`).
//!
//! **The answer is written into a buffer the thread keeps, and copied once
//! into the arena at exactly its length.** The arena then sees one
//! allocation of the size the answer is, whatever size that turned out to be,
//! and none of the intermediate ones. The copy is one `memcpy` of the answer,
//! which is what a doubling buffer pays too (each doubling that cannot grow in
//! place copies what is written) and is the cheapest part of either.
//!
//! **A threadlocal is right here for the reason `date.zig` gives**: nothing
//! between taking the buffer and handing it back suspends the fiber, because
//! a serialiser writes to memory and calls no one. A fiber that moved
//! threads *after* `render` returned holds bytes in the arena, which are its
//! own. The one way to break that is a `jsonStringify` that waits on I/O, and
//! `busy` is what keeps even that from corrupting a neighbour: a render that
//! finds the buffer taken writes straight into the arena, the way it did
//! before.
//!
//! An answer that outgrows the buffer (`scratch_len`, 32 KiB) is moved into
//! the arena at twice the size and written on there, so a large answer pays
//! what it always did and the buffer never has to be large. What the thread
//! holds is `scratch_len` bytes of address space and the pages an answer has
//! touched, a cost per thread and not per connection, so the hard axes of
//! ADR 017 do not move.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The first size of an answer written straight into the arena, which is
/// `ctx.json_hint` and the one case that does not use the thread's buffer.
const arena_first = 512;

/// What the thread keeps. Zero-initialised so it is `.tbss` and costs no bytes
/// in the binary, in Debug as much as in a release build (an `undefined` one is
/// filled with 0xaa there and lands in `.tdata`).
pub const scratch_len = 32 * 1024;
threadlocal var scratch: [scratch_len]u8 align(64) = @splat(0);
threadlocal var busy: bool = false;

pub const Error = error{ OutOfMemory, WriteFailed };

/// The bytes of `value` as JSON, in `arena`, at exactly their length.
/// Everything `json.write` writes, written by it.
pub fn render(arena: Allocator, value: anytype) Error![]const u8 {
    var buf: Buffer = try .begin(arena);
    defer buf.release();
    json_write(&buf.writer, value) catch |e| return buf.fail(e);
    return buf.finish();
}

/// Kept as a function of its own so a test can swap what is written without a
/// type, and so the file's one import of the serialiser is in one place.
fn json_write(w: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    return @import("json.zig").write(w, value);
}

/// A writer over the thread's buffer that moves into the arena when it fills.
pub const Buffer = struct {
    arena: Allocator,
    writer: std.Io.Writer,
    /// The writer's buffer is the thread's, not the arena's.
    in_scratch: bool,
    /// An allocation failed, which a writer can only report as `WriteFailed`.
    out_of_memory: bool = false,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = std.Io.Writer.noopFlush,
        .rebase = rebase,
    };

    pub fn begin(arena: Allocator) error{OutOfMemory}!Buffer {
        if (!busy) {
            busy = true;
            return .{
                .arena = arena,
                .in_scratch = true,
                .writer = .{ .buffer = &scratch, .vtable = &vtable },
            };
        }
        const first = try arena.alloc(u8, arena_first);
        return .{ .arena = arena, .in_scratch = false, .writer = .{ .buffer = first, .vtable = &vtable } };
    }

    /// Hands the thread's buffer back. Safe to call twice and after `finish`.
    pub fn release(self: *Buffer) void {
        if (self.in_scratch) {
            self.in_scratch = false;
            busy = false;
        }
    }

    pub fn fail(self: *Buffer, err: std.Io.Writer.Error) Error {
        return if (self.out_of_memory) error.OutOfMemory else err;
    }

    /// The answer, in the arena.
    pub fn finish(self: *Buffer) error{OutOfMemory}![]const u8 {
        const written = self.writer.buffered();
        if (!self.in_scratch) return written;
        const kept = try self.arena.alloc(u8, written.len);
        @memcpy(kept, written);
        return kept;
    }

    /// Room for `more` bytes past what is written: a bigger buffer in the
    /// arena, holding what has been written so far.
    fn grow(self: *Buffer, more: usize) error{OutOfMemory}!void {
        const w = &self.writer;
        const need = std.math.add(usize, w.end, more) catch return error.OutOfMemory;
        if (w.buffer.len >= need) return;
        // A buffer that already lives in the arena may be the arena's last
        // allocation and grow where it is.
        const target = @max(need, w.buffer.len * 2);
        if (!self.in_scratch) {
            if (self.arena.remap(w.buffer, target)) |bigger| {
                w.buffer = bigger;
                return;
            }
        }
        const bigger = try self.arena.alloc(u8, target);
        @memcpy(bigger[0..w.end], w.buffer[0..w.end]);
        if (self.in_scratch) {
            self.in_scratch = false;
            busy = false;
        } else {
            self.arena.free(w.buffer);
        }
        w.buffer = bigger;
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Buffer = @fieldParentPtr("writer", w);
        std.debug.assert(data.len != 0);
        var count: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| count += bytes.len;
        const pattern = data[data.len - 1];
        count += pattern.len * splat;
        self.grow(count) catch {
            self.out_of_memory = true;
            return error.WriteFailed;
        };
        for (data[0 .. data.len - 1]) |bytes| {
            @memcpy(w.buffer[w.end..][0..bytes.len], bytes);
            w.end += bytes.len;
        }
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(w.buffer[w.end..][0..splat], pattern[0]);
                w.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
                w.end += pattern.len;
            },
        }
        return count;
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        const self: *Buffer = @fieldParentPtr("writer", w);
        _ = preserve;
        self.grow(minimum_len) catch {
            self.out_of_memory = true;
            return error.WriteFailed;
        };
    }
};

const testing = std.testing;

fn plain(value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try json_write(&out.writer, value);
    return out.toOwnedSlice();
}

test "an answer is the bytes json.write makes, at exactly its length, whatever its size" {
    const Row = struct { id: u32, name: []const u8 };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Under the buffer, just over it, and several times over: the three
    // places the writer is in the thread's buffer, has just left it, and has
    // grown in the arena more than once.
    for ([_]usize{ 1, 40, 1_000, 5_000, 9_000 }) |n| {
        const rows = try testing.allocator.alloc(Row, n);
        defer testing.allocator.free(rows);
        for (rows, 0..) |*r, i| r.* = .{ .id = @intCast(i), .name = "a name that is a little long" };
        const want = try plain(rows);
        defer testing.allocator.free(want);
        const got = try render(arena.allocator(), rows);
        try testing.expectEqualStrings(want, got);
        try testing.expect(!busy);
    }
}

test "an answer larger than the thread's buffer is written on in the arena" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try testing.allocator.alloc(u8, scratch_len * 3);
    defer testing.allocator.free(text);
    @memset(text, 'x');
    const got = try render(arena.allocator(), .{ .text = text });
    try testing.expectEqual(scratch_len * 3 + "{\"text\":\"\"}".len, got.len);
    try testing.expect(std.mem.endsWith(u8, got, "xx\"}"));
}

test "a render started while another holds the buffer does not touch it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var outer: Buffer = try .begin(arena.allocator());
    defer outer.release();
    try outer.writer.writeAll("outer");
    try testing.expect(busy);
    const inner = try render(arena.allocator(), .{ .a = 1 });
    try testing.expectEqualStrings("{\"a\":1}", inner);
    try testing.expectEqualStrings("outer", outer.writer.buffered());
    try testing.expect(busy);
}

test "a failing allocator is an out-of-memory error and gives the buffer back" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const big = try testing.allocator.alloc(u8, scratch_len * 2);
    defer testing.allocator.free(big);
    @memset(big, 'y');
    try testing.expectError(error.OutOfMemory, render(failing.allocator(), .{ .text = big }));
    try testing.expect(!busy);
}
