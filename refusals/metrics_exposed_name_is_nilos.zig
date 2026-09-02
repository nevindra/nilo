//! A metric of the application's own, named the way nilo names its own. Two
//! `# TYPE` lines under one family make the whole page unparseable, so the
//! application would lose every metric it had rather than that one.

const nilo = @import("nilo_http");
const std = @import("std");

var hits: std.atomic.Value(u64) = .init(0);

export fn refusal() void {
    var app: nilo.App = undefined;
    app.expose("nilo_requests_total", .counter, &hits) catch {};
}
