//! A field an environment variable could never become. A variable holds one
//! piece of text, so a list of them is a shape this module has no rule for —
//! and inventing one (split on a comma? on a colon?) would be a convention
//! nobody could predict without reading the source.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
    tags: []const []const u8,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
