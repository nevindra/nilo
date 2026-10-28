//! A metric named into nilo's own namespace, which makes two families under
//! one name if nilo ever prints it (ADR 079).

const nilo = @import("nilo_http");

const Shop = struct {
    nilo_orders_total: nilo.Counter(void) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
