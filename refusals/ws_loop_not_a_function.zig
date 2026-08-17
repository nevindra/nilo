//! An upgrade handed a value where the loop goes. The socket has to be read
//! by something, and 7 will not read it.

const nilo = @import("nilo_http");

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(7, {});
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
