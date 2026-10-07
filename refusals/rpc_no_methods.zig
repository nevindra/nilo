//! A service with a name and nothing to serve.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const Greeter = struct {
    pub const nilo_service = "hello.Greeter";
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
