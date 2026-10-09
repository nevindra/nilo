//! A first nilo server: two routes, one of them typed, and a test.
//!
//! ```
//! zig build dev      # rebuilt and restarted on every save
//! zig build test
//! curl localhost:8787/greet/wati
//! ```

const std = @import("std");
const nilo = @import("nilo_http");

// The lines every nilo root file wants. `listen()` says so at startup if the
// first two are missing.
pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

fn hello() []const u8 {
    return "hello from nilo\n";
}

/// `name` is the `:name` in the pattern, matched by position.
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

test "a greeting answers with the name in the path" {
    var wired = try nilo.testing.Wired.init(std.testing.allocator, .{});
    defer wired.deinit();
    try wired.app.get("/greet/:name", greet);

    const answer = try wired.get("/greet/wati");
    try std.testing.expectEqual(200, answer.status);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("wati", try answer.text(&buf));
}
