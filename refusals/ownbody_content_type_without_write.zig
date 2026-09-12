//! A content type with nothing written under it. The type says its answer is
//! XML and has no `nilo_write`, so there are no bytes for the label to label.

const nilo = @import("nilo_http");

const Invoice = struct {
    number: u32,
    pub const nilo_content_type = "application/xml";
};

fn showInvoice(id: u32) Invoice {
    return .{ .number = id };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/invoices/:id", showInvoice) catch {};
}
