//! Credentials and `*` together, which every browser rejects — and rejects
//! as a CORS error that says nothing about the real cause.

const zfast = @import("zfast");

export fn refusal() void {
    var app: zfast.App = undefined;
    app.use(zfast.cors.with(.{ .origin = "*", .credentials = true })) catch {};
}
