//! Two structs by value on a route that still has a `:id` going spare. The
//! message used to offer one fix — make one of them a `*Service` — and that
//! sent somebody with a `Uuid` argument to write `*Uuid`. A type that parses
//! itself is the third answer, and this is the route where it is the right
//! one (ADR 0142).

const nilo = @import("nilo_http");

const Sku = struct { letters: [3]u8 };
const NewOrder = struct { quantity: u32 };

fn placeOrder(sku: Sku, incoming: NewOrder) u32 {
    _ = sku;
    return incoming.quantity;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/orders/:sku", placeOrder) catch {};
}
