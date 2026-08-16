//! A `FileBody` in the argument list — a file going the wrong way. What
//! arrives from a client is an `Upload`; what goes to one is the return type.

const nilo = @import("nilo_http");

fn store(incoming: nilo.FileBody) !void {
    _ = incoming;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/invoices", store) catch {};
}
