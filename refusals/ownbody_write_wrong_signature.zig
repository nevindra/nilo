//! A `nilo_write` that returns the bytes rather than writing them. The shape
//! is a writer so the body lands in the arena once, the way JSON does, and a
//! function handing back a slice is a different contract.

const nilo = @import("nilo_http");

const Invoice = struct {
    number: u32,
    pub const nilo_content_type = "application/xml";
    pub fn nilo_write(self: Invoice) []const u8 {
        _ = self;
        return "<invoice/>";
    }
};

fn showInvoice(id: u32) Invoice {
    return .{ .number = id };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/invoices/:id", showInvoice) catch {};
}
