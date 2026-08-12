//! A param in a group prefix. Refused because middleware on a group is
//! scoped by comparing the front of the request path against the prefix.

const zfast = @import("zfast");

export fn refusal() void {
    var app: zfast.App = undefined;
    _ = app.group("/orgs/:org");
}
