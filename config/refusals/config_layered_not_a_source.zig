//! A layering with something in it that cannot be asked for a value. The
//! position is in the message because the tuple is written in one line and
//! "one of these is not a source" would leave the reader counting.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
};

export fn refusal() void {
    const read = config.from(Settings, config.layered(.{
        config.Fixed{ .pairs = &.{.{ "PORT", "9000" }} },
        42,
    }));
    _ = read;
}
