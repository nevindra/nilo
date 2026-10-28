//! A histogram in the default unit (seconds) whose name does not say so
//! (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    checkout_time: nilo.Histogram(void, .{ .buckets = .{ 5_000, 50_000 } }) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
