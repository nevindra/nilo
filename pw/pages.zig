//! The memory one hash walks, asked for in the size of page it walks it in.
//!
//! A hash makes exactly one allocation — `bytesFor` is the number, 19,922,944
//! at the default Cost — and then reads and writes all of it in an order
//! nothing can predict, twice. Out of an ordinary allocator that is 4,864
//! pages of 4 KiB, and the first pass takes a fault on every one of them: 2.2
//! ms of kernel, measured on its own, before any hashing has happened. The
//! same walk out of ten 2 MiB pages takes ten.
//!
//! Asked for in 2 MiB pages it is ten of each, and the measurement is in
//! ADR 0049: **13.6 ms a hash becomes 11.0** — -19% uncontended, -8% at the
//! eight the Gate allows at once — for memory that is still handed back at the
//! end of the call rather than held. That is the whole of what this file does
//! — `mmap`, one `madvise`, and `munmap` — and it is opt-in because the
//! allocator is the caller's to name (ADR 0048).
//!
//! ```zig
//! const stored = try c.hashPassword(pw.huge_pages, form.password);
//! ```
//!
//! **A hash's memory holds what the password went through**, and this is the
//! shape that gives it back to the kernel rather than to the next caller of
//! the same allocator: `munmap` on the way out, zeroed pages on the way in.
//! Argon2 does not wipe its blocks, so out of a recycling allocator those
//! bytes are the next allocation's.
//!
//! **Linux only, and a hint rather than a demand.** `MADV_HUGEPAGE` is what
//! asks; whether it is granted is the kernel's
//! (`/sys/kernel/mm/transparent_hugepage/enabled`), and where it is not this
//! is `std.heap.page_allocator` with an extra syscall. Everywhere that is not
//! Linux it *is* `std.heap.page_allocator`, named so that a call site does not
//! have to ask what it is running on. The cost of asking is the one thing to
//! know about before turning it on: with `defrag` set to anything but
//! `defer`, a fault that has to compact memory to find a huge page waits for
//! it, and that wait lands on a sign-in.

const std = @import("std");
const builtin = @import("builtin");

/// 2 MiB — the huge page on x86-64 and aarch64 alike, and the alignment the
/// mapping is placed at so the kernel has whole ones to give.
pub const huge_page = 2 * 1024 * 1024;

/// An allocator for the one big allocation a hash makes: 2 MiB pages, out of
/// the operating system and back to it. See this file's header.
///
/// Anything smaller than a huge page goes to `std.heap.page_allocator`
/// unchanged, so a `verify` against a hash somebody made at 64 KiB is not 2
/// MiB of mapping — this is an allocator rather than a trapdoor.
pub const huge_pages: std.mem.Allocator = if (supported)
    .{ .ptr = undefined, .vtable = &vtable }
else
    std.heap.page_allocator;

const supported = builtin.os.tag == .linux;

/// Only `alloc` differs. Freeing, resizing and remapping a mapping made here
/// is what `std.heap.PageAllocator` already does — the advice is a property of
/// the pages, not of the bookkeeping.
const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.heap.PageAllocator.vtable.resize,
    .remap = std.heap.PageAllocator.vtable.remap,
    .free = std.heap.PageAllocator.vtable.free,
};

fn alloc(_: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (n < huge_page or alignment.toByteUnits() > huge_page)
        return std.heap.PageAllocator.map(n, alignment);

    // Placed on a huge page boundary rather than wherever the last mapping
    // ended: the kernel backs the aligned part of a mapping and leaves the
    // rest in 4 KiB pages, so an unaligned one gets most of the win and pays
    // for the whole of it.
    const ptr = std.heap.PageAllocator.map(n, comptime .fromByteUnits(huge_page)) orelse return null;
    const length = std.mem.alignForward(usize, n, std.heap.pageSize());
    std.posix.madvise(@alignCast(ptr), length, std.posix.MADV.HUGEPAGE) catch {
        // A kernel with transparent huge pages compiled out, or a mapping it
        // will not consider. The memory is good; it is only ordinary.
    };
    return ptr;
}

const testing = std.testing;

test "the one allocation a hash makes comes back aligned to a huge page" {
    if (!supported) return error.SkipZigTest;
    const argon2id = @import("argon2id.zig");

    const bytes = argon2id.bytesFor(.default);
    const buf = try huge_pages.alloc(u8, bytes);
    defer huge_pages.free(buf);

    try testing.expectEqual(@as(usize, 0), @intFromPtr(buf.ptr) % huge_page);
    // And it is memory rather than an address: the last byte is as writable
    // as the first.
    buf[0] = 1;
    buf[bytes - 1] = 2;
    try testing.expectEqual(@as(u8, 1), buf[0]);
}

test "anything smaller than a huge page is an ordinary page allocation" {
    // The property that keeps this an allocator: a `verify` against a stored
    // hash made at 64 KiB asks for 64 KiB, and 2 MiB of mapping for it would
    // be a surprise nobody asked for.
    const small = try huge_pages.alloc(u8, 64 * 1024);
    defer huge_pages.free(small);
    small[0] = 3;
    small[small.len - 1] = 4;
    try testing.expectEqual(@as(u8, 3), small[0]);
    try testing.expectEqual(@as(u8, 4), small[small.len - 1]);

    // Everything below a huge page keeps `std.heap.page_allocator`'s
    // granularity, which is a page rather than two megabytes.
    const tiny = try huge_pages.alloc(u8, 1);
    defer huge_pages.free(tiny);
    tiny[0] = 5;
    try testing.expectEqual(@as(u8, 5), tiny[0]);
}

test "a hash out of it is the same hash" {
    // The only thing that would make this worth having wrong: memory is
    // memory, and where it came from cannot show up in the answer.
    const argon2id = @import("argon2id.zig");
    const cost: argon2id.Cost = .{ .memory_kib = 8 * 1024, .passes = 1 };

    const from_pages = try argon2id.hashWith(cost, huge_pages, "hunter2", @splat(1));
    const from_gpa = try argon2id.hashWith(cost, testing.allocator, "hunter2", @splat(1));

    try testing.expectEqualStrings(from_gpa.text(), from_pages.text());
    try testing.expect(try argon2id.verifyWith(cost, huge_pages, from_pages.text(), "hunter2"));
}
