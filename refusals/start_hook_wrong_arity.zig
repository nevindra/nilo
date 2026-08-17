//! A `nilo_start` that takes neither of the two shapes a start hook may have.
//!
//! Two are allowed — `(self, io)` for a service that only wants the loop, and
//! `(self, io, limits)` for one that bounds an outbound call (ADR 0065). A
//! fourth parameter is a hook nilo would have to guess how to call, and
//! guessing wrong means a service that never finishes being built.

const std = @import("std");
const nilo = @import("nilo_http");

const Mailer = struct {
    io: std.Io = undefined,

    pub fn nilo_start(self: *Mailer, io: std.Io, limits: nilo.Limits, extra: u32) !void {
        _ = limits;
        _ = extra;
        self.io = io;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    var mailer: Mailer = .{};
    app.provide(&mailer) catch {};
}
