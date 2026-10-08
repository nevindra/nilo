//! A `nilo_decode` that takes no arena. The decoder is handed the body and
//! the request arena, both, so a type whose value has to allocate can.

const std = @import("std");
const nilo = @import("nilo_http");

const Reading = struct {
    sensor: u16,

    pub const nilo_content_type = "application/x-reading";

    pub fn nilo_decode(body: []const u8) !Reading {
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
