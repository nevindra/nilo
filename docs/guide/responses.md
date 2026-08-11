# Responses

Most handlers answer by returning a value — see
[Handlers](./handlers.md#what-a-handler-returns). This page is the layer
underneath: what a `*Ctx` can send, and the rules that apply to both.

## Sending from a `Ctx`

```zig
fn handler(c: *zfast.Ctx) !void { … }
```

| | |
|---|---|
| `c.sendText(200, "hi")` | `text/plain` |
| `c.sendJson(201, value)` | serialised and sent |
| `c.send(200, "text/csv", bytes)` | a content type of your own |
| `c.stream(200, "text/csv")` | a response written in pieces — [Streaming](./streaming.md) |
| `c.events()` | a stream of server-sent events |
| `c.upgrade()` | turn the connection into a [WebSocket](./websocket.md) |

## Headers

| | |
|---|---|
| `c.setHeader(name, value)` | copied into the request arena |
| `c.setStaticHeader(name, value)` | for text that already outlives the request (a literal), so nothing is copied |

**Set them before sending.** A response is flushed the moment it is sent, so
there is nothing left to change afterwards.

`Content-Type`, `Content-Length`, `Transfer-Encoding` and `Connection` are the
framework's to write, and setting them is refused — a response carrying two of
any of those is malformed. Pass the content type to `send` instead.

For a handler that returns a value, the same headers are set through
`Response(T).headers`, which is copied rather than borrowed:

```zig
return .{ .status = 201, .headers = .of(&.{
    .{ .name = "Location", .value = url },
}), .value = created };
```

Eight per response there, and a ninth is a compile error pointing you at
`c.setHeader`, which has no limit
([ADR 0019](../adr/0019-a-response-owns-its-headers.md)).

## One request, one response

A response is written and flushed in one go. There is no "start the response,
change your mind" — that state doesn't exist, so neither do the bugs where a
header set too late silently vanishes. If you need to decide as you go, that's
what [a stream](./streaming.md) is for, and even there the head goes out first
and is fixed once written.

Sending twice is an assertion failure rather than two responses on the wire. A
handler that fails *after* sending gets its connection closed, because a
half-sent response can't be taken back and the next request on that connection
would read bytes of unclear provenance. It is logged:

```
warning: handler GET /report failed after answering: WriteFailed
```

## Keep-alive

zfast decides. HTTP/1.1 keeps the connection open unless the client says
`Connection: close`; HTTP/1.0 closes unless it asks otherwise; a failed stream or
an unreadable body closes. `c.keepAlive()` reports what will happen. Nothing a
handler does has to think about it — a 404 is a normal thing to answer, not a
reason to hang up.

## Content types

| Returned | Sent as |
|---|---|
| `void` | no body |
| `Str`, `[]const u8` | `text/plain` |
| anything else | `application/json` |

For anything else, `c.send(status, content_type, bytes)`, or `c.stream(status,
content_type)` when the length isn't known yet.

Static files get their type from the file extension — see
[Static files](./static-files.md).
