//! A keyed allowance wider than the counters in its slot.

const nilo = @import("nilo_http");

fn who(_: *nilo.Ctx) ?[]const u8 {
    return null;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.keyed(who, .{ .per_window = 20_000_000, .window_s = 3600, .on_null = .skip })) catch {};
}
