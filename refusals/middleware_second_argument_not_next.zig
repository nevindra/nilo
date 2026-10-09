//! A middleware's second argument is the `Next` (ADR 008).

const nilo = @import("nilo_http");

const Keys = struct { n: u32 = 0 };

fn noNext(c: *nilo.Ctx, keys: *Keys) !void {
    _ = c;
    _ = keys;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(noNext) catch {};
}
