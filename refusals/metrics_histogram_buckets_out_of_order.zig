//! Boundaries that go backwards (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 50_000, 5_000 } }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
