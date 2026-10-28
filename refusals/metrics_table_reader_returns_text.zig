//! A `nilo_metrics` reader that answers text (ADR 079).

const nilo = @import("nilo_http");

const Store = struct {
    pub const nilo_metrics = .{
        .{ "nilo_store_hits_total", .counter, "Hits.", hitsOf },
    };
    fn hitsOf(_: *const Store) []const u8 {
        return "many";
    }
};

export fn refusal() void {
    var service: Store = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
