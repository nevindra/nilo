//! A `nilo_stop` that returns an error union.
//!
//! It runs from a `defer` on the way out of `listen()`. There is nobody left
//! to hand a failure to and nothing useful to do with one, so a service that
//! hits trouble putting something down logs it and carries on — which is what
//! every `deinit` in this repository already does (ADR 0151).

const nilo = @import("nilo_http");

const Mailer = struct {
    open: bool = false,

    pub fn nilo_stop(self: *Mailer) !void {
        self.open = false;
        return error.CouldNotClose;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    var mailer: Mailer = .{};
    app.provide(&mailer) catch {};
}
