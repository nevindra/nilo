//! A `pub fn` of a service that neither reads nor answers a message: a helper
//! left public, which would have been served as a method.

const std = @import("std");
const nilo = @import("nilo_http");

const Hello = struct {
    pub const wire = .{ .name = 1 };
    name: []const u8 = "",
};

const Greeter = struct {
    pub const nilo_service = "hello.Greeter";

    pub fn sayHello(in: Hello) Hello {
        return in;
    }

    pub fn ping() u32 {
        return 1;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
