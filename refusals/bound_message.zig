//! `Bound(T)` around a protobuf message. A binding hands the handler each
//! JSON field that failed; a message read as protobuf has no such field.

const nilo = @import("nilo_http");

const Sum = struct {
    pub const wire = .{ .a = 1, .b = 2 };
    a: i32 = 0,
    b: i32 = 0,
};

fn add(in: nilo.Bound(Sum)) void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sum", add) catch {};
}
