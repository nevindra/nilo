# Changelog

What changed between one tag and the next — not what changed between commits.
How each piece got built is in [`docs/history.md`](./docs/history.md); what is
coming is in [`docs/roadmap.md`](./docs/roadmap.md).

## 0.1.0

The first release. Needs Zig 0.16.

Install it pinned — `zig fetch --save git+https://github.com/nevindra/zfast?ref=v0.1.0`.
Without the `?ref=` you get whatever `main` is that day.

### What is in it

- **Handlers are ordinary functions.** What each argument means is worked out
  while compiling, by one rule: a pointer is a service, a value is request data.
  A test calls the function directly — no server, no fake request.
- **Routing** — path params, wildcards, groups, plugins. The most specific route
  wins and duplicates are refused
  ([ADR 0013](./docs/adr/0013-the-most-specific-route-wins-and-duplicates-are-refused.md)).
- **Requests** — path params, query strings and JSON bodies as structs of your
  own; bodies too big to hold, read as a stream.
- **HTML forms and file uploads**, url-encoded and multipart.
- **Responses** — a status in the type (`Status(201, T)`), typed redirects,
  response headers, and a `Ctx` layer underneath for full control.
- **Cookies, and sessions sealed into one** with `XChaCha20Poly1305` — no server
  store, no expiry sweep, nothing added to what an idle connection costs
  ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)).
- **Middleware** as an onion of `Ctx` functions, and resolved values declared by
  their type.
- **Static files** held in memory, gzipped once at startup, with ETags and range
  requests.
- **Streamed responses and server-sent events.**
- **WebSocket** — handshake, framing, masking, pings, closing handshake.
- **A generated OpenAPI document**, written from the signatures rather than from
  annotations ([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
- **Failure in zfast's own words.** Get a handler wrong and compilation stops
  with a sentence naming your route, your argument and the fix; `refusals/` is
  50 programs written wrong on purpose that keep it that way
  ([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
- **`zfast.spawn`** for work that is not a request, owned by the server so
  shutdown counts it ([ADR 0029](./docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)).

### What it holds itself to

One allocation per request and 8,767 bytes per idle connection, both hard
invariants held by tests rather than by intent
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)). Measured
numbers and the method behind them are in
[`docs/benchmarks.md`](./docs/benchmarks.md), with eight other servers through
the same harness in [`docs/comparison.md`](./docs/comparison.md).

### What is not in it

- **Templates**, and **field-level form errors**. Together these are the reason
  0.1.0 is for building an API rather than rendering pages: there is no template
  layer, and a `Form(T)` field that will not convert fails the whole request
  with a 400 instead of handing back the form with that one field marked.
- **Broadcasting to a WebSocket a handler does not hold.** The `chat` example
  echoes; two tabs do not see each other.
- **TLS**, and with it HTTP/2 and a gRPC server. This is a refusal rather than a
  gap — terminate in front
  ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).
- **A `recover` middleware.** Zig cannot recover from a panic, so there is
  nothing to build ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)).
- **Compressing a handler's response**, `sendfile`, `permessage-deflate`, and
  streamed multipart. Static files *are* compressed, once, at startup.

`zfast` is a working name and may change before 1.0.
