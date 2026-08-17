//! A loop written the way a handler is written. The request is over by the
//! time this runs — the whole point of handing the loop back is that the `Ctx`
//! and everything behind it has gone.

const nilo = @import("nilo_http");

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, {});
}

fn chatLoop(c: *nilo.Ctx) !void {
    _ = c;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
