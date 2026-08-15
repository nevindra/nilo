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
`.headers`, which is copied rather than borrowed:

```zig
// The status is part of the signature — `!Status(201, User)` — so the API
// description names it. `Response(T)` is the same thing with the status as
// a runtime field, for when it depends on what the handler found.
return .{ .headers = .of(&.{
    .{ .name = "Location", .value = url },
}), .value = created };
```

Eight per response there, and a ninth is a compile error pointing you at
`c.setHeader`, which has no limit
([ADR 0019](../adr/0019-a-response-owns-its-headers.md)).

## Redirects

`Redirect(status)` carries its status in the type, so the API description
names it and says the answer carries a `Location`:

```zig
fn shortLink(db: *Db, code: zfast.Str) !zfast.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

Which one to use is the only difficulty, and it is worth getting right:

| | |
|---|---|
| **301** | moved for good |
| **302** | found — temporary |
| **303** | see other. **What a form POST answers with**, because it turns the follow-up into a GET, so the reload button re-reads the page instead of posting the form again |
| **307** | temporary, and the method is kept |
| **308** | permanent, and the method is kept |

Anything else is a compile error — a `Location` on a status that does not carry
one means nothing to a client.

A redirect can carry headers, which is how a sign-in answers:

```zig
return .with("/", .of(&.{.{ .name = "Set-Cookie", .value = session }}));
```

`c.redirect(status, location)` is the same response from a `*Ctx`, for a status
only known while the request is running.

There is no body. Browsers follow the header and never look
([ADR 0032](../adr/0032-a-redirect-puts-its-status-in-the-type.md)).

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
| `void` | no body, and no `Content-Type` either |
| `Str`, `[]const u8` | `text/plain` |
| anything else | `application/json` |

A failure — from a `fail.*` function, from an error, from zfast refusing a
request — is always `application/json`. See [Errors](./errors.md).

For anything else, `c.send(status, content_type, bytes)`, or `c.stream(status,
content_type)` when the length isn't known yet.

Static files get their type from the file extension — see
[Static files](./static-files.md).
