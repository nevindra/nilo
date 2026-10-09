//! A struct by value is the request body on a handler, and a middleware has
//! no one body to read: it is refused with the fix written out (ADR 008).

const nilo = @import("nilo_http");

const Login = struct { name: []const u8 };

fn needsBody(c: *nilo.Ctx, next: nilo.Next, login: Login) !void {
    _ = login;
    try next.run(c);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(needsBody) catch {};
}
