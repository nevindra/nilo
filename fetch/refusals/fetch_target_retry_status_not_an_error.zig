//! A 2xx in `statuses` would retry a success.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Api = fetch.Target("api", .{ .retry = .{ .statuses = &.{200} } });
    var client: fetch.Client = undefined;
    _ = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
