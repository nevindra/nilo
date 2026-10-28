//! A union with a discriminator inside a body struct, written without the line
//! that hands `std.json` nilo's reader. The same first-request 400 as when the
//! union is the whole body.

const nilo = @import("nilo_http");

const Shape = union(enum) {
    circle: struct { radius: u32 },
    square: struct { side: u32 },

    pub const nilo_json = .{ .tag = "kind" };
};

const NewDrawing = struct { shape: Shape };

fn draw(incoming: NewDrawing) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/draw", draw) catch {};
}
