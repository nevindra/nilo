//! A `FileBody` in the argument list — a file going the wrong way. What
//! arrives from a client is an `Upload`; what goes to one is the return type.

const zfast = @import("zfast");

fn store(incoming: zfast.FileBody) !void {
    _ = incoming;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/invoices", store) catch {};
}
