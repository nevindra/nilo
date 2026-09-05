//! A prefix longer than the address it masks. An IPv6 address is 128 bits,
//! and asking to key on 192 of them is a number somebody meant differently.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 100, .window_s = 60, .ipv6_prefix = 192 })) catch {};
}
