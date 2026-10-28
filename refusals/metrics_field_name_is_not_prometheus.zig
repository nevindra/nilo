//! A metric whose field name Prometheus would reject, and with it the whole
//! page (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    @"orders placed_total": nilo.Counter(void) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
