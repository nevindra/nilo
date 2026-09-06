//! A `nilo_parse` that takes something other than the text. What arrives from
//! a request is bytes, and it is `[]const u8` rather than a `nilo.Str`
//! because a tool module has no Str to name (ADR 0042, ADR 0142).

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(code: u32) ?Sku {
        _ = code;
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
