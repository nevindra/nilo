//! A Config read from something that cannot be asked for a value. The
//! source is a shape checked while compiling rather than an interface, so
//! the thing that goes wrong is a missing `get` — and saying so is worth
//! more than a page of errors from inside `fill`.

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
};

export fn refusal() void {
    const read = config.from(Settings, 42);
    _ = read;
}
