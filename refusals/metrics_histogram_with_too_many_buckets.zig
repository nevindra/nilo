//! Seventeen boundaries, one past what a histogram holds (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_seconds: nilo.Histogram(void, .{ .buckets = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 } }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
