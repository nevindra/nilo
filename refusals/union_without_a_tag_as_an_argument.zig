//! A union as the request body, with nothing in the bytes to say which variant.

const nilo = @import("nilo_http");

const Shape = union(enum) {
    circle: struct { radius: u32 },
    square: struct { side: u32 },
};

fn area(shape: Shape) u32 {
    _ = shape;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/area", area) catch {};
}
