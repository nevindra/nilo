//! A type saying it parses itself with something that cannot be called.
//! `nilo_parse` is the function nilo hands the request text to (ADR 0142), so
//! a constant under that name says the type can do something it cannot.

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub const nilo_parse = 3;
};

fn showSku(sku: Sku) u32 {
    return sku.letters[0];
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/skus/:sku", showSku) catch {};
}
