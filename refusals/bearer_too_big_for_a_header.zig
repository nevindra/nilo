//! A bearer token too big for the request head the server reads. Left to run,
//! the client would be refused before any handler ran, and it would look like
//! a sign-in that never works.

const nilo = @import("nilo_http");

const Signed = struct {
    user: u32,
    /// Eight kilobytes of it, which is past half of the default head.
    notes: [8192]u8,
};

fn me(b: nilo.Bearer(Signed)) u32 {
    _ = b;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
