//! An empty content type. The declaration is there, so the intent to write
//! the body by hand is clear, and the label the bytes would go out under is
//! nothing.

const std = @import("std");
const nilo = @import("nilo_http");

const Invoice = struct {
    number: u32,
    pub const nilo_content_type = "";
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
