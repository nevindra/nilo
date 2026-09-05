//! An allowance wider than the counters in a slot. The whole table is one
//! `u64` per address, and a ceiling this high would leave too few bits for
//! the fingerprint that tells two addresses apart — so the refusal names the
//! way to ask for the same rate with a longer window.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 5000, .window_s = 60 })) catch {};
}
