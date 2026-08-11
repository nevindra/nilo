# Changelog

## 0.1.0

The first release. Needs Zig 0.16.

### Handlers

- Typed handlers: an ordinary function that takes what it needs and returns
  data. Arguments are matched while compiling, by one rule — a pointer is a
  service, a value is request data. Getting it wrong is a compile error that
  names the route.
- Path params, converted to the type in the signature. Catch-all patterns.
- `Query(T)` — the query string read into a struct of yours, where a field's
  default is what "absent" means.
- A struct argument is the request body, parsed from JSON, with errors that name
  the field and say what was wrong with it.
- `Response(T)` for a status and headers of your own. Headers are held by value,
  up to eight; a ninth is a compile error.
- `Str` for text belonging to a request, with a debug-build trap that panics on a
  stale read rather than returning whatever the next request put there.
- `*Ctx` alongside any of it, for what the typed layer has no argument for.

### Routing

- `get` / `post` / `put` / `delete` / `patch` / `head` / `options` / `route`.
- The most specific route wins, whatever order they were registered in.
  Duplicates are refused rather than silently shadowed.
- `HEAD` answered by the `GET` route; an unregistered `OPTIONS` answered with
  `Allow`; a wrong method on a real path is a 405, not a 404.
- Groups — one prefix carrying routes, middleware and static files — and plugins,
  which are ordinary functions that take a group.

### Requests and responses

- Keep-alive, chunked bodies both ways, percent-decoding.
- `c.stream(status, content_type)` for a response written in pieces, and
  `c.events()` for server-sent events. Nothing is allocated per piece.
- `c.bodyStream()` for a body too big to hold, bounded by the buffer the handler
  passes in. Allocates nothing at all.
- `c.upgrade()` for WebSocket: handshake, framing, masking, fragment reassembly
  and the closing handshake are handled; the loop is the handler's.
- Range requests on static files, with `If-Range` honoured against the ETag. A
  `Range` that can't be understood is ignored and the whole file goes out.

### Building an application

- Services registered by type; a missing one stops `listen()` before the socket
  opens, naming the routes that needed it.
- Middleware as an onion of `Ctx` functions, with `use` and `useOn`. Logger and
  CORS built in.
- Resolved values: a type declares how it is worked out from the request, and a
  handler asks for it by writing it in its argument list. Worked out once per
  request, shared with `c.resolve` from middleware.
- Static files read into memory at startup, with ETags, 304s and an SPA fallback.
- `fail.notFound(…)` and friends, callable from anywhere with no `Ctx` in hand.
- `app.docs(.{ … })` for an OpenAPI 3.1 document read off the handler signatures.

### Running it

- `zfast.blocking`, `zfast.Mutex` and `zfast.sleep` for anything that would
  otherwise stop the OS thread every other request is sharing.
- Graceful shutdown on Ctrl-C, SIGTERM or `app.shutdown()`: stop accepting,
  finish what is in flight, `Connection: close` on the way out.
- Every startup failure is one line, in words, with the fix in it — and no stack
  trace through zfast's own files on top of it.
- `pub const panic = zfast.panic;` names the in-flight request in a crash.
- `zfast.testing.Client` for handlers that write their answer instead of
  returning it.

### Measured

- **1 allocation** per request on a routed GET returning JSON with CORS
  installed — the JSON body, and nothing else. Held there by a test.
- **~21 KB** per idle connection with the default buffers; ~17 KB at 2 KB each.
- The request path was profiled and optimised shape by shape before the release:
  the primary metric — a routed GET with a path param answering ~1KB of JSON —
  went **1684ns → 605ns**, and no shape measured got slower. Mostly a JSON writer
  generated from the response type (`std.json` was spending more on the payload
  than the rest of the request put together) and a request head walked once
  rather than once per line per delimiter. The full accounting, including the
  three ideas that were measured and dropped, is in
  [`docs/history.md`](./docs/history.md).
- No requests-per-second figures, on purpose: that needs a machine nobody else is
  using, and there isn't one yet.

### Not in this release

There are **no deadlines of any kind** — no read, header or write timeout. Put
zfast behind a reverse proxy that has them. Also absent: TLS, sessions,
templates, `sendfile`, `permessage-deflate`, and broadcasting to WebSockets a
handler doesn't hold. See [`docs/roadmap.md`](./docs/roadmap.md).
