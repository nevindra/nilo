//! A `nilo_parse` that cannot say no. Text that is not one of these has to
//! come back as null, because that is the whole of what nilo reads — an error
//! set of the type's own would have to be turned into a 400 by somebody, and
//! that somebody would be guessing at what each error meant (ADR 0142).

const nilo = @import("nilo_http");

const Sku = struct {
    letters: [3]u8,

    pub fn nilo_parse(text: []const u8) Sku {
        _ = text;
        return .{ .letters = "AAA".* };
    }
};

fn showSku(sku: Sku) u32 {
    return sku.letters[0];
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/skus/:sku", showSku) catch {};
}
