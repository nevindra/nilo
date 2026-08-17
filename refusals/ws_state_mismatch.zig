//! The state passed and the state the loop declares are different types, so
//! the loop would read the bytes of one as the other.

const nilo = @import("nilo_http");

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, @as(u32, 7));
}

fn chatLoop(socket: *nilo.Socket, name: nilo.Str) !void {
    _ = name;
    _ = socket;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
