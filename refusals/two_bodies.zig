//! A service asked for by value. `Store` is a service — it is meant to be
//! `*Store` — and by value it is a struct, so zfast reads it as a second
//! request body.

const zfast = @import("zfast");

const Store = struct { rows: u32 };
const NewOrder = struct { sku: zfast.Str };

fn placeOrder(store: Store, incoming: NewOrder) u32 {
    _ = incoming;
    return store.rows;
}

export fn refusal() void {
    var app: zfast.App = undefined;
    app.post("/orders", placeOrder) catch {};
}
