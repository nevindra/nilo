//! A session too big for a browser to keep. Left to run, this is the worst
//! failure the design has: the cookie is dropped with no error and no
//! warning, so it looks like a session that simply never works.

const nilo = @import("nilo");

const Signed = struct {
    user: u32,
    /// Four kilobytes of it, which is past what a browser holds once the
    /// name and the attributes are counted.
    notes: [4096]u8,
};

fn me(s: nilo.Session(Signed)) u32 {
    _ = s;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
