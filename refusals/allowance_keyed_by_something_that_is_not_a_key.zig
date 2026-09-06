//! What a keyed allowance counts against is a function of the request, not a
//! value read once. Passing a string means every request in the process shares
//! one allowance, which is the opposite of what the feature is for — and the
//! mistake is easy to make, because the option beside it *is* a string.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.allowance.keyed("account", .{ .on_null = .reject })) catch {};
}
