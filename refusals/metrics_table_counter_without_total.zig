//! A `nilo_metrics` counter whose name does not end `_total` (ADR 079).

const nilo = @import("nilo_http");

const Store = struct {
    pub const nilo_metrics = .{
        .{ "nilo_store_hits", .counter, "Hits.", hitsOf },
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
