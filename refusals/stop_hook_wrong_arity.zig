//! A `nilo_stop` that takes something besides the service it is stopping.
//!
//! There is one shape and no second one. A stop hook runs from a `defer` on
//! the way out of `listen()`, where the loop is the one it was started on and
//! there is nothing else left to hand it (ADR 0151).

const std = @import("std");
const nilo = @import("nilo_http");

const Mailer = struct {
    open: bool = false,

    pub fn nilo_stop(self: *Mailer, io: std.Io) void {
        _ = io;
        self.open = false;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    var mailer: Mailer = .{};
    app.provide(&mailer) catch {};
}
