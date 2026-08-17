//! A whole struct carried into the loop. The state travels in the connection
//! loop's frame, which is the frame an idle socket is holding, so it has a
//! ceiling — the request arena is where something this size goes, with a
//! pointer to it carried here instead.

const nilo = @import("nilo_http");

const Seat = struct {
    joined_at: i64,
    colour: [176]u8,
};

fn chat(c: *nilo.Ctx) !void {
    return c.upgrade(chatLoop, Seat{ .joined_at = 0, .colour = @splat(0) });
}

fn chatLoop(socket: *nilo.Socket, seat: Seat) !void {
    _ = seat;
    _ = socket;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/ws", chat) catch {};
}
