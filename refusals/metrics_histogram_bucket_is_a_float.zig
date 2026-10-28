//! A float boundary, which would need a float printer in the binary
//! (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 0.005, 0.05 } }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
