//! A Config read from a struct that is a container but cannot be asked for a
//! value. The near miss the other Refusal does not cover: `config_not_a_source`
//! hands over a `comptime_int`, which fails the container check first, so the
//! missing `get` is a second sentence needing a second program.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
};

const NotASource = struct {
    pairs: []const u8 = "",
};

export fn refusal() void {
    const read = config.from(Settings, NotASource{});
    _ = read;
}
