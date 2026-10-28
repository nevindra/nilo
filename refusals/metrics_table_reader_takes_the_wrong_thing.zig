//! A `nilo_metrics` reader that takes a number rather than the service
//! (ADR 079).

const nilo = @import("nilo_http");

const Store = struct {
    pub const nilo_metrics = .{
        .{ "nilo_store_hits_total", .counter, "Hits.", hitsOf },
    };
    fn hitsOf(n: u32) u64 {
        return n;
    }
};

export fn refusal() void {
    var service: Store = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
