//! The key is minted under a header name, and a space in it would corrupt the request head.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    const Api = fetch.Target("api", .{ .retry = .{ .mint_key = "Bad Name" } });
    var client: fetch.Client = undefined;
    _ = Api.open(&client, .{ .base = "https://api.example.com" }) catch return;
}
