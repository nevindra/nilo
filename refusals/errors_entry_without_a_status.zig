//! An entry that names the error and forgets its status.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.errors(.{.{error.EmailTaken}}) catch {};
}
