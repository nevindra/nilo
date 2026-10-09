//! Doubling zero is zero: every wait would be none and a service's bad minute would be met with an instant retry from every caller.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Api = fetch.Target("api", .{ .retry = .{ .backoff = .{ .exponential = .{ .from_ms = 0, .to_ms = 100 } } } });
    var client: fetch.Client = undefined;
    _ = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
