//! A middleware's first argument is the `*Ctx` and its second the `Next`;
//! services and resolved values come after them (ADR 008).

const nilo = @import("nilo_http");

const Keys = struct { n: u32 = 0 };

fn wrongOrder(keys: *Keys, c: *nilo.Ctx, next: nilo.Next) !void {
    _ = keys;
    try next.run(c);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(wrongOrder) catch {};
}
