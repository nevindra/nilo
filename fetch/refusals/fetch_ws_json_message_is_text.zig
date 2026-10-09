//! A message already encoded as JSON, handed to `WebSocket.sendJson`.
//! `std.json` would write it out as one JSON *string*, quotes and escapes
//! and all, and the far end would answer a feed's subscription with an
//! error about a message that looked right in the editor. A message already
//! encoded goes through `sendText` (ADR 281).

const fetch = @import("nilo_fetch");

export fn refusal() void {
    var ws: fetch.WebSocket = .idle;
    ws.sendJson("{\"op\":\"subscribe\"}") catch {};
}
