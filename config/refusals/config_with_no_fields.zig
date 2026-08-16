//! A Config with no fields. It compiles, it reads nothing, and it answers
//! successfully every time — which is worse than failing, because the
//! program goes on to serve with settings nobody supplied.

const config = @import("nilo_config");

const Empty = struct {};

export fn refusal() void {
    const read = config.from(Empty, config.Fixed{ .pairs = &.{} });
    _ = read;
}
