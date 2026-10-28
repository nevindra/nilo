//! A counter named for what it counts but not marked `_total`, which
//! Prometheus tooling reads to know it only climbs (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    orders: nilo.Counter(void) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
