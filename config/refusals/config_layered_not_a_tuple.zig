//! A layering built out of one source instead of a tuple of them — the
//! braces forgotten. The `inline for` inside `Layered` would otherwise fail
//! about a struct field, which says nothing about the call that was written.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
};

export fn refusal() void {
    const only = config.Fixed{ .pairs = &.{.{ "PORT", "9000" }} };
    const read = config.from(Settings, config.layered(only));
    _ = read;
}
