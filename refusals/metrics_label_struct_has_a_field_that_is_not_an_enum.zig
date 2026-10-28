//! A struct label with a number in it, which has no closed set of values
//! (ADR 079).

const nilo = @import("nilo_http");

const Status = enum { paid, refused };
const Label = struct { status: Status, shard: u32 };
const Shop = struct {
    orders_total: nilo.Counter(Label) = .{},
};

export fn refusal() void {
    var service: Shop = undefined;
    var app: nilo.App = undefined;
    app.provide(&service) catch {};
}
