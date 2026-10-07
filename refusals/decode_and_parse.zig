//! A type that parses itself from a path segment and decodes itself from a
//! body. Given to a handler by value it could be either.

const std = @import("std");
const nilo = @import("nilo_http");

const Reading = struct {
    sensor: u16,

    pub const nilo_content_type = "application/x-reading";

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Reading {
        _ = arena;
        return .{ .sensor = body[0] };
    }

    pub fn nilo_parse(text: []const u8) !Reading {
        return .{ .sensor = try std.fmt.parseInt(u16, text, 10) };
    }
};

fn record(r: Reading) u16 {
    return r.sensor;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/readings", record) catch {};
}
