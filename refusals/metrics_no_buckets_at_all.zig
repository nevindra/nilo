//! An empty bucket list, which leaves the histogram with nowhere to put a
//! request — so the page would carry counts and no timings at all.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.metrics(.{ .buckets = &.{} }) catch {};
}
