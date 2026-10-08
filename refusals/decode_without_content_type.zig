//! A type that reads its own body and never says under which label. nilo
//! reads it only when the request's media type is the type's own, so with
//! none there is nothing to compare against.

const std = @import("std");
const nilo = @import("nilo_http");

const Reading = struct {
    sensor: u16,

    pub fn nilo_decode(body: []const u8, arena: std.mem.Allocator) !Reading {
        _ = arena;
        return .{ .sensor = body[0] };
    }
};

fn record(r: Reading) u16 {
    return r.sensor;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/readings", record) catch {};
}
