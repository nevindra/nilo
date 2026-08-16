//! An allocator that counts, so the request path can be held to a budget.
//!
//! The point is a number that does not depend on the machine. Requests per
//! second on a shared VM says nothing (docs/roadmap.md), but "this request
//! path took N trips to the allocator" is the same everywhere and is a fair
//! proxy for the work being done per request.

const std = @import("std");

pub const Counting = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    bytes: usize = 0,

    pub fn allocator(self: *Counting) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *Counting) void {
        self.allocs = 0;
        self.resizes = 0;
        self.bytes = 0;
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        self.bytes += len;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *Counting = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ra);
    }
};
