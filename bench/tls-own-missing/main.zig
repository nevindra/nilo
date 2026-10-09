//! The same server, whose build asked for its own TLS library and never
//! wrote the import. See `build.zig` here.
const nilo = @import("nilo_http");

fn health() []const u8 {
    return "ok";
}

pub fn main() !void {
    var app: nilo.App = .init(@import("std").heap.page_allocator);
    defer app.deinit();
    try app.get("/health", health);
    try app.listen(.{ .tls = .{ .cert = "cert.pem", .key = "key.pem" } });
}
