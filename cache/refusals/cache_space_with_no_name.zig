//! One Space in the program, so its name felt like paperwork. The name is
//! what keeps one Space's keys out of another's, and what a collision
//! between two of them is reported by.

const cache = @import("nilo_cache");

export fn refusal() void {
    _ = cache.Space("", u64, .{});
}
