//! A session holding a slice. There is no row on the server for it to point
//! into, and nothing bounds how long it gets — so the cookie's size would
//! depend on the data, and a browser drops an oversized cookie in silence.

const nilo = @import("nilo");

const Signed = struct {
    user: u32,
    name: []const u8,
};

fn me(s: nilo.Session(Signed)) u32 {
    _ = s;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
