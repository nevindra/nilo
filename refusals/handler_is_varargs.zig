//! A C function with varargs handed to a route.

const zfast = @import("zfast");

extern fn printf(format: [*:0]const u8, ...) c_int;

export fn refusal() void {
    var app: zfast.App = undefined;
    app.get("/", printf) catch {};
}
