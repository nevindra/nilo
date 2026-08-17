//! A loop that takes state the upgrade never passed. `upgrade` was given
//! `{}`, so the loop reads the socket and nothing else.

const nilo = @import("nilo_http");

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, {});
}

fn chatLoop(socket: *nilo.Socket, name: nilo.Str) !void {
    _ = name;
    while (try socket.receive()) |message| try socket.send(message.kind, message.data);
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
