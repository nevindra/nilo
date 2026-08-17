//! A layering with nothing in it, which would answer nothing for every
//! setting and report each of them as unset. The same refusal a Config with
//! no fields gets, and for the same reason.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
};

export fn refusal() void {
    const read = config.from(Settings, config.layered(.{}));
    _ = read;
}
