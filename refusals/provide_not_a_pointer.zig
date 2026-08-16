//! A service registered by value. The App keeps the pointer and copies
//! nothing, so a copy would be a service nobody else can see.

const nilo = @import("nilo");

const Db = struct { open: bool = false };

export fn refusal() void {
    var app: nilo.App = undefined;
    const db: Db = .{};
    app.provide(db) catch {};
}
