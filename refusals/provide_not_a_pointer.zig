//! A service registered by value. The App keeps the pointer and copies
//! nothing, so a copy would be a service nobody else can see.

const zfast = @import("zfast");

const Db = struct { open: bool = false };

export fn refusal() void {
    var app: zfast.App = undefined;
    const db: Db = .{};
    app.provide(db) catch {};
}
