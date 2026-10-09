//! A typed middleware is wrapped from the function itself, so it cannot be
//! a pointer held in a variable (ADR 008).

const nilo = @import("nilo_http");

const Keys = struct { n: u32 = 0 };

fn requireKey(c: *nilo.Ctx, next: nilo.Next, keys: *Keys) anyerror!void {
    _ = keys;
    try next.run(c);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    var held: *const fn (*nilo.Ctx, nilo.Next, *Keys) anyerror!void = &requireKey;
    _ = &held;
    app.use(held) catch {};
}
