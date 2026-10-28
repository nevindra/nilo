//! An error given a 200. An answer to a failed request is a 4xx or a 5xx,
//! and a 200 here would be an error that a client reads as success.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.errors(.{.{ error.EmailTaken, 200 }}) catch {};
}
