//! A table whose size is not a power of two. The index is a hash taken modulo
//! the number of buckets and the buckets are four slots wide, so a size that
//! does not divide leaves slots nothing can ever reach.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.with(.{ .per_window = 100, .window_s = 60, .slots = 5000 })) catch {};
}
