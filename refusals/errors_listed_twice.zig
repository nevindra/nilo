//! The same error given two statuses. Which one a client gets would depend on
//! the order of the lines, so nilo refuses to pick.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.errors(.{
        .{ error.EmailTaken, 409 },
        .{ error.EmailTaken, 422 },
    }) catch {};
}
