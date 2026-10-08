//! A service named by a number rather than text.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const Greeter = struct {
    pub const nilo_service = 7;

    pub fn sayHello(in: Hello) Hello {
        return in;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
