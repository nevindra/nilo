//! A server that listens with TLS, so the Engine's use of the library is
//! analysed against the dependent's module.
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
