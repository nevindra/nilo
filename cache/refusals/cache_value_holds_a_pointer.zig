//! Caching a row straight out of the database, with the name still a slice
//! into whatever buffer read it. A cache entry outlives the call that wrote
//! it, so that slice is an address belonging to a request that has ended.

const cache = @import("nilo_cache");

const Cart = struct {
    owner: u64,
    name: []const u8,
};

export fn refusal() void {
    _ = cache.Space("cart", Cart, .{});
}
