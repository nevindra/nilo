//! The smallest thing that serves. `zig build run-hello`, then
//! `curl localhost:8787/` and `curl localhost:8787/greet/wati`.

const std = @import("std");
const nilo = @import("nilo_http");

// The two lines every nilo root file wants. `listen()` says so at startup
// if either is missing.
pub const std_options = nilo.std_options; // keeps the Engine's debug chatter out of your logs
pub const std_options_debug_io = nilo.debug_io; // keeps `std.log` from blocking the event loop

fn hello() []const u8 {
    return "hello from nilo\n";
}

/// `:name` in the pattern arrives as the argument of the same position.
/// A `Str` is text that belongs to the request; it goes back out as-is.
fn greet(name: nilo.Str) nilo.Str {
    return name;
}

pub fn main() !void {
    var app = nilo.App.init(std.heap.smp_allocator);
    defer app.deinit();

    try app.use(nilo.logger.standard);

    try app.get("/", hello);
    try app.get("/greet/:name", greet);

    try app.listen(.{});
}
