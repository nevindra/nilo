//! A service that does not say which one it is, so its methods have no path.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const Greeter = struct {
    pub fn sayHello(in: Hello) Hello {
        return in;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
