//! A union with a discriminator as the request body, written without the line
//! that hands `std.json` nilo's reader. It compiles on its own and would read
//! `{"kind":"circle","radius":2}` as an object of one key.

const nilo = @import("nilo_http");

const Shape = union(enum) {
    circle: struct { radius: u32 },
    square: struct { side: u32 },

    pub const nilo_json = .{ .tag = "kind" };
};

fn area(shape: Shape) u32 {
    _ = shape;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/area", area) catch {};
}
