//! `max_bytes` read as "no limit" rather than as the size of the buffer a
//! `get` reads into. At zero there is nothing for a value to come back in.

const cache = @import("nilo_cache");

export fn refusal() void {
    _ = cache.Space("page", []const u8, .{ .max_bytes = 0 });
}
