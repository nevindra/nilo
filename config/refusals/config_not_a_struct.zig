//! A Config that is not a struct. Settings are named, so there is nothing
//! for a `u32` to be read into — the name a value would arrive under is the
//! field name, and a `u32` has none.

const config = @import("nilo_config");

export fn refusal() void {
    const read = config.from(u32, config.Fixed{ .pairs = &.{} });
    _ = read;
}
