//! The same mistake one level down, where it is much harder to see: `Cart`
//! itself looks flat, and the pointer is inside the struct of a field.
//! The Refusal has to name the whole path or it is no help at all.

const cache = @import("nilo_cache");

const Line = struct { sku: u32, label: []const u8 };
const Cart = struct { owner: u64, first: Line };

export fn refusal() void {
    _ = cache.Space("cart", Cart, .{});
}
