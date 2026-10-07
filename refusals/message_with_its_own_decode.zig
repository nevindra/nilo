//! A protobuf message that also reads its own bytes: two answers to how one
//! body is read, and nothing at the route to say which wins.

const std = @import("std");
const nilo = @import("nilo_http");

const Sum = struct {
    pub const wire = .{ .a = 1 };
    a: i32 = 0,

    pub const nilo_content_type = "application/x-sum";

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Sum {
        _ = arena;
        return .{ .a = body[0] };
    }
};

fn add(in: Sum) void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sum", add) catch {};
}
