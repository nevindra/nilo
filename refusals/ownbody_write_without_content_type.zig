//! Bytes with no label. The type writes its own body and never says what the
//! bytes are, and nilo will not guess a `Content-Type` for somebody else's
//! encoding.

const std = @import("std");
const nilo = @import("nilo_http");

const Invoice = struct {
    number: u32,
    pub fn nilo_write(self: Invoice, w: *std.Io.Writer) !void {
        try w.print("<invoice>{d}</invoice>", .{self.number});
    }
};

fn showInvoice(id: u32) Invoice {
    return .{ .number = id };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/invoices/:id", showInvoice) catch {};
}
