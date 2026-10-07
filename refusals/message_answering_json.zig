//! A route that reads a protobuf message and answers a plain struct. The
//! answer goes back in the request's spelling, and a plain struct has no
//! protobuf spelling.

const nilo = @import("nilo_http");

const Sum = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

const Total = struct { total: i32 };

fn add(in: Sum) Total {
    return .{ .total = in.a + in.b };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sum", add) catch {};
}
