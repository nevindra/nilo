//! Boundaries that go backwards. Each bucket counts everything at or below
//! its own boundary, so the second one here can never hold anything the
//! first did not.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.metrics(.{ .buckets = &.{ 1_000, 100 } }) catch {};
}
