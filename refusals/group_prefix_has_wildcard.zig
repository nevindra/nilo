//! A catch-all in a group prefix. Refused because a `*` matches the whole
//! rest of the path, leaving nothing for the routes inside the group. A `:`
//! in a prefix is allowed — middleware scoping matches whole segments, and a
//! `:name` segment matches whatever is opposite it.

const nilo = @import("nilo");

export fn refusal() void {
    var app: nilo.App = undefined;
    _ = app.group("/files/*");
}
