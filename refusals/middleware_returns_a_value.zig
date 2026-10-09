//! A middleware produces no value; a value for the handler is a resolved
//! value (ADR 008, ADR 015).

const nilo = @import("nilo_http");

const Keys = struct { n: u32 = 0 };

fn givesBack(c: *nilo.Ctx, next: nilo.Next, keys: *Keys) !u32 {
    try next.run(c);
    return keys.n;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(givesBack) catch {};
}
