//! A `nilo_parse` left generic. nilo has to know what it takes before it can
//! promise the route compiles, and an `anytype` says the type has not decided
//! either (ADR 0142) — the same reason a handler may not be generic.

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(text: anytype) ?Sku {
        _ = text;
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
