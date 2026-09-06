//! A `nilo_stop` that is a value rather than a function.
//!
//! The marker is read by name, so anything called `nilo_stop` is taken to be
//! the hook. A constant with that name is a service nilo would silently never
//! stop, which is the failure this whole hook exists to stop (ADR 0151).

const nilo = @import("nilo_http");

const Mailer = struct {
    open: bool = false,

    pub const nilo_stop = true;
};

export fn refusal() void {
    var app: nilo.App = undefined;
    var mailer: Mailer = .{};
    app.provide(&mailer) catch {};
}
