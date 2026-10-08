//! A service name with a slash in it, which would split its methods' paths.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const Greeter = struct {
    pub const nilo_service = "hello/Greeter";

    pub fn sayHello(in: Hello) Hello {
        return in;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
