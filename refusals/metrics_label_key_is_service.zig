//! A label key nilo writes itself, which would put `service` on a sample twice
//! (ADR 079).

const nilo = @import("nilo_http");

const Service = enum { web, worker };
const Shop = struct {
    orders_total: nilo.Counter(Service) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
