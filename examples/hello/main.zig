//! The smallest thing that serves. `zig build run-hello`, then
//! `curl localhost:8787/` and `curl localhost:8787/greet/wati`.

const std = @import("std");
const zfast = @import("zfast");

pub const std_options_debug_io = zfast.debug_io;

fn hello() []const u8 {
    return "hello from zfast\n";
}

/// `:name` in the pattern arrives as the argument of the same position.
/// A `Str` is text that belongs to the request; it goes back out as-is.
fn greet(name: zfast.Str) zfast.Str {
    return name;
}

pub fn main() !void {
    var app = zfast.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(zfast.logger.standard);

    try app.get("/", hello);
    try app.get("/greet/:name", greet);

    try app.listen(.{});
}
