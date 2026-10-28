//! A histogram that names no boundaries, so counts nothing (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{} }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
