//! The smallest program that names the server and nothing else.
const nilo = @import("nilo_http");

fn health() []const u8 {
    return "ok";
}

pub fn main() !void {
    var app: nilo.App = .init(@import("std").heap.page_allocator);
    defer app.deinit();
    try app.get("/health", health);
    try app.listen(.{});
}
