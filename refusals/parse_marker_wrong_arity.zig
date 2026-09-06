//! A `nilo_parse` that wants more than the text. A path param is one segment
//! and nilo has nothing else to hand over — no Scope, no allocator, no route
//! (ADR 0142). A type that needs any of those is doing work a handler does.

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(text: []const u8, strict: bool) ?Sku {
        _ = text;
        _ = strict;
        return null;
    }
};

fn showSku(sku: Sku) u32 {
    return sku.letters[0];
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/skus/:sku", showSku) catch {};
}
