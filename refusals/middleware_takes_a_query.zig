//! A middleware covers many routes, so it cannot be given one route's query
//! string (ADR 008).

const nilo = @import("nilo_http");

const Page = struct { page: u32 = 1 };

fn paged(c: *nilo.Ctx, next: nilo.Next, q: nilo.Query(Page)) !void {
    _ = q;
    try next.run(c);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(paged) catch {};
}
