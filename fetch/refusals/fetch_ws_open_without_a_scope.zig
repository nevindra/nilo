//! A WebSocket opened with something that is not a Scope (ADR 281).
//!
//! Opening a socket is a call like any other `nilo_fetch` makes: it spends
//! the route's deadline, forwards its request id and writes into the memory
//! its answer lives in, and all three are the Scope's. An allocator owns
//! memory and says nothing about how long what is in it lives.

const fetch = @import("nilo_fetch");

export fn refusal() void {
    var client: fetch.Client = undefined;
    var ws: fetch.WebSocket = .idle;
    var gpa: @import("std").mem.Allocator = undefined;
    ws.open(&client, &gpa, "wss://feed.example.com/stream", .{}) catch {};
}
