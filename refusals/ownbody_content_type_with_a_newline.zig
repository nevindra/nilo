//! A content type carrying a line break. On the wire it would end the header
//! line and start another, which is how a response gets a header nobody set.

const std = @import("std");
const nilo = @import("nilo_http");

const Invoice = struct {
    number: u32,
    pub const nilo_content_type = "application/xml\r\nX-Injected: yes";
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
