//! A group prefix without its leading slash.

const zfast = @import("zfast");

export fn refusal() void {
    var app: zfast.App = undefined;
    _ = app.group("api");
}
