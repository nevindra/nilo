//! Three enums of sixteen values make 4096 series a field, past the 256 a
//! metric holds (ADR 079).

const nilo = @import("nilo_http");

const Sixteen = enum { a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p };
const Label = struct { x: Sixteen, y: Sixteen, z: Sixteen };
const Shop = struct {
    orders_total: nilo.Counter(Label) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
