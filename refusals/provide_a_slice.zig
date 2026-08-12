//! A list of services registered as if it were one — `list.items` handed
//! straight to provide().

const zfast = @import("zfast");

const Db = struct { open: bool = false };

var pool: [4]Db = undefined;
var in_use: usize = 4;

export fn refusal() void {
    var app: zfast.App = undefined;
    app.provide(pool[0..in_use]) catch {};
}
