//! A `nilo_help` entry spelled differently from the field it describes
//! (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    orders_total: nilo.Counter(void) = .{},

    pub const nilo_help = .{ .order_total = "Orders." };
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
