//! A rendered page held as a fixed array, on the assumption that a cache
//! entry can be any size. The length lives in 16 bits so four ways of a
//! bucket are one cache line, which puts a ceiling on one entry.

const cache = @import("nilo_cache");

const Page = struct {
    etag: u64,
    html: [128 * 1024]u8,
};

export fn refusal() void {
    _ = cache.Space("page", Page, .{});
}
