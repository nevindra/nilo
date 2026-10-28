//! A first boundary of zero, which no observation is below (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 0, 5_000 } }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
