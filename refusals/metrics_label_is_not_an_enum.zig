//! A label that is a string, which would be a series per value a request
//! could carry (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    orders_total: nilo.Counter([]const u8) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
