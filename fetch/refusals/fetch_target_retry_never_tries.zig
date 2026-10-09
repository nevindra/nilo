//! A `.retry` with `times = 0` declares a retry that never retries, which is a Target with no `.retry` and a line that reads as a policy.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Api = fetch.Target("api", .{ .retry = .{ .times = 0 } });
    var client: fetch.Client = undefined;
    _ = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
