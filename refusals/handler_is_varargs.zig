//! A C function with varargs handed to a route.

const nilo = @import("nilo_http");

extern fn printf(format: [*:0]const u8, ...) c_int;

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/", printf) catch {};
}
