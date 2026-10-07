//! A service that is not a struct: a number has no functions to serve.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(u32) catch {};
}
