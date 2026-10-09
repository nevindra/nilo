//! The address of a `u16` where a count is read at run time. The count is a
//! `u32`, and the sentence says so instead of leaving Zig's coercion error.

const nilo = @import("nilo_http");

var rate: u16 = 100;

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = &rate })) catch {};
}
