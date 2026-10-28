//! A `nilo_metrics` row with no help sentence (ADR 079).

const nilo = @import("nilo_http");

const Store = struct {
    pub const nilo_metrics = .{
        .{ "nilo_store_hits_total", .counter, hitsOf },
    };
    fn hitsOf(_: *const Store) u64 {
        return 0;
    }
};

export fn refusal() void {
    var service: Store = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
