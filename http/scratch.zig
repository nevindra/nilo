//! Message buffers that belong to the thread rather than to the connection.
//!
//! A WebSocket's receive buffer used to be a local in the handler:
//!
//! ```zig
//! var buf: [4096]u8 = undefined;
//! while (try socket.receive(&buf)) |message| { … }   // what it used to be
//! while (try socket.receive()) |message| { … }       // what it is now
//! ```
//!
//! The first reads well and cost 4,096 bytes **per open socket, for as long as it
//! stayed open**. A suspended fiber holds its stack at the high-water mark it
//! ever reached ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)),
//! and the handler's frame is live for the whole life of the connection — so
//! nothing gives those pages back, not even the `madvise` that gives the
//! connection's own two buffers back, because they are above the stack pointer
//! rather than below it. Measured: a socket that had received one 60 KiB
//! message held 74,809 bytes per idle connection against 13,375 for one that
//! had not, and the difference was the buffer.
//!
//! So the buffer stops belonging to the socket. **It is checked out when a
//! message starts arriving and given back when the connection goes quiet** —
//! at the same 200ms peek that hands the read and write buffers to the kernel.
//! What a process holds is therefore one buffer per message *in flight*, not
//! one per connection, and those are different numbers by three orders of
//! magnitude on the workload WebSockets are for: ten thousand chat tabs with
//! four people typing is four buffers.
//!
//! A busy socket never reaches the peek and so never gives its buffer back,
//! which is the right way round: the check-out is not on the message path at
//! all, and an echo server at 1.7M messages a second does one per socket for
//! the life of the socket rather than one per message.
//!
//! The other half of the same finding is where the *loop* runs, which is
//! [ADR 0071](../docs/adr/0071-where-a-connection-waits-is-what-it-costs.md):
//! taking the buffer off the handler's frame is worth nothing if the frame
//! itself is what a parked socket is holding.
//!
//! ## Why a thread-local free list and not an allocator
//!
//! Every buffer is the same size and page-aligned, so there is nothing to
//! choose between two of them and no size class to look up: taking one is
//! popping a pointer, giving it back is pushing one, and neither touches a
//! lock or an atomic. The list head is `threadlocal`, so two executors never
//! see each other's. A fiber that migrates between executors gives its buffer
//! to whichever list it lands on, which is correct because the buffers are
//! interchangeable.
//!
//! Page-aligned because the size *is* the alignment worth having: a buffer
//! that starts on a page can have its pages handed back whole, and one that
//! straddles cannot.
//!
//! The list is capped. Without a cap, one burst of ten thousand concurrent
//! messages would leave ten thousand buffers on the free lists forever, which
//! is the per-connection cost this exists to remove, moved somewhere harder to
//! see. Past the cap a buffer is returned to the allocator.

const std = @import("std");
const builtin = @import("builtin");

/// How many **bytes** of spare buffer one executor keeps.
///
/// A count and not a size was the first attempt and it was wrong in the way
/// that matters: eight spares is 128 KiB at the default ceiling and 8 MB at a
/// 64 KiB one, on a sixteen-thread machine, and a spare buffer that was ever
/// written to stays resident. Measured, that put 4,096 bytes per connection
/// back on the 64 KiB row — the cost this whole exercise exists to remove,
/// moved somewhere harder to see.
///
/// A byte budget says the same thing at every ceiling: **64 KiB a thread, so
/// 1 MB on a sixteen-thread machine, flat, whatever `max_message` is.** Four
/// spares at the default, one at 64 KiB, and a server whose messages are
/// bigger than that calls the allocator on a burst rather than holding the
/// burst's high-water mark for ever.
const keep_bytes = 64 * 1024;

/// The free list is threaded through the buffers themselves, so a spare buffer
/// costs no bookkeeping anywhere else.
const Node = struct {
    next: ?*Node,
};

threadlocal var head: ?*Node = null;
/// Bytes on this thread's list, against `keep_bytes`.
threadlocal var spare: usize = 0;
/// Every buffer on this thread's list is this long. A server does not change
/// `max_message` while it runs, but a test in the same process might, and a
/// list of buffers that are the wrong size is a silent overflow.
threadlocal var sized: usize = 0;

/// `std.heap.page_allocator` and not the App's, deliberately: every buffer is
/// a whole number of pages and page-aligned, which is the one shape a general
/// allocator has nothing to add to and the one that lets a page be handed back
/// to the kernel whole. It also keeps the free list out of the App's lifetime —
/// a thread's spares outlive any one App, which is what a `threadlocal` is.
const pages = std.heap.page_allocator;

/// A buffer of at least `size` bytes, page-aligned. The caller gives it back
/// with `give` or leaks it.
pub fn take(size: usize) error{OutOfMemory}![]align(std.heap.page_size_min) u8 {
    const want = std.mem.alignForward(usize, size, std.heap.page_size_min);
    if (sized == want) {
        if (head) |node| {
            head = node.next;
            spare -= want;
            const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(node));
            return ptr[0..want];
        }
    }
    return pages.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), want);
}

/// Give one back. Cheap enough to do on every quiet transition.
pub fn give(buf: []align(std.heap.page_size_min) u8) void {
    // A different length than this thread is holding means the list is stale —
    // drop what is there rather than mixing two of them.
    if (sized != buf.len) {
        drain();
        sized = buf.len;
    }
    if (spare + buf.len > keep_bytes or buf.len < @sizeOf(Node)) {
        pages.free(buf);
        return;
    }
    const node: *Node = @ptrCast(@alignCast(buf.ptr));
    node.* = .{ .next = head };
    head = node;
    spare += buf.len;
}

fn drain() void {
    while (head) |node| {
        head = node.next;
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(node));
        pages.free(ptr[0..sized]);
    }
    spare = 0;
}

test "a buffer given back is the next one taken" {
    defer drain();

    const first = try take(4096);
    give(first);
    const again = try take(4096);
    try std.testing.expectEqual(first.ptr, again.ptr);
    give(again);
}

test "the list stops at the byte budget rather than growing with the burst" {
    defer drain();

    var held: [(keep_bytes / 4096) + 4][]align(std.heap.page_size_min) u8 = undefined;
    for (&held) |*place| place.* = try take(4096);
    for (held) |buf| give(buf);

    try std.testing.expectEqual(@as(usize, keep_bytes), spare);
}

test "the budget is bytes, so a bigger ceiling keeps fewer of them" {
    defer drain();

    // Two buffers of half the budget each fit; a third does not.
    var held: [3][]align(std.heap.page_size_min) u8 = undefined;
    for (&held) |*place| place.* = try take(keep_bytes / 2);
    for (held) |buf| give(buf);

    try std.testing.expectEqual(@as(usize, keep_bytes), spare);
}

test "a different size empties the list rather than handing back the wrong length" {
    defer drain();

    // In pages rather than in bytes, because `take` rounds up to
    // `page_size_min` and that is **16 KiB on Apple silicon** against 4 KiB
    // on x86-64 Linux. Written as 4096 and 8192 this asked for two sizes
    // that are the same size there — so it did not fail because the list is
    // broken, it failed because it was never testing two sizes at all.
    const one_page = std.heap.page_size_min;
    const two_pages = 2 * one_page;

    const small = try take(one_page);
    give(small);
    try std.testing.expectEqual(one_page, spare);

    const big = try take(two_pages);
    give(big);
    try std.testing.expectEqual(two_pages, spare);
    try std.testing.expectEqual(two_pages, sized);

    const back = try take(two_pages);
    try std.testing.expectEqual(two_pages, back.len);
    give(back);
}

test "a size that is not a whole number of pages is rounded up to one" {
    defer drain();

    const buf = try take(100);
    defer give(buf);
    try std.testing.expectEqual(std.heap.page_size_min, buf.len);
}
