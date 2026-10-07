//! Two functions whose names differ only in the first letter's case, which
//! are one method once it is upper-cased.

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

    pub fn SayHello(in: Hello) Hello {
        return in;
    }
};

export fn refusal() void {
    var app: nilo.App = undefined;
    app.rpc(Greeter) catch {};
}
