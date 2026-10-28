//! A label that is an enum with a `_` in it, so its set of series is not the
//! set of its names (ADR 079).

const nilo = @import("nilo_http");

const Status = enum(u8) { paid, refused, _ };
const Shop = struct {
    orders_total: nilo.Counter(Status) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
