//! A `nilo_stop` that takes the service by value.
//!
//! A stop hook puts something down, and a copy has nothing anybody else can
//! see. Zig makes this easy to write by accident: `self: Mailer` compiles and
//! does nothing (ADR 0151).

const nilo = @import("nilo_http");

const Mailer = struct {
    open: bool = false,

    pub fn nilo_stop(self: Mailer) void {
        _ = self;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    var mailer: Mailer = .{};
    app.provide(&mailer) catch {};
}
