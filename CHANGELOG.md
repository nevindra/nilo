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
- **Bindings that name the field that broke.** `Bound(Form(T))`, `Bound(T)` and
  `Bound(Query(T))` hand the handler every field that would not bind, by name,
  with the text that arrived — a 422 listing them is one line, and a page
  showing the form again with one box marked is a few more
  ([ADR 0036](./docs/adr/0036-a-binding-hands-its-failures-to-the-handler.md)).
- **Responses** — a status in the type (`Status(201, T)`), typed redirects,
  response headers, and a `Ctx` layer underneath for full control.
- **Cookies, and sessions sealed into one** with `XChaCha20Poly1305` — no server
  store, no expiry sweep, nothing added to what an idle connection costs
  ([ADR 0035](./docs/adr/0035-a-session-is-sealed-into-the-cookie.md)).
- **Middleware** as an onion of `Ctx` functions, and resolved values declared by
  their type. A group prefix may carry a param — `app.group("/orgs/:org")` —
  and middleware scoped to it matches whole segments.
- **Request ids and JSON log lines.**
  `logger.with(.{ .format = .json, .request_id = true })` writes one JSON object
  per line and puts an `X-Request-Id` on every response, adopting the proxy's id
  when it sent a usable one. `c.requestId()` reaches the same id from a handler.
- **Static files** held in memory, gzipped once at startup, with ETags and range
  requests.
- **Streamed responses and server-sent events.**
- **WebSocket** — handshake, framing, masking, pings, closing handshake.
- **A generated OpenAPI document**, written from the signatures rather than from
  annotations ([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
- **Failure in zfast's own words.** Get a handler wrong and compilation stops
  with a sentence naming your route, your argument and the fix; `refusals/` is
  54 programs written wrong on purpose that keep it that way
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

- **Templates** — a refusal rather than a backlog item. zfast is for building
  APIs and services; rendering pages is not what it is for, and the reasoning is
  in [the roadmap](./docs/roadmap.md#not-coming).
- **Broadcasting to a WebSocket a handler does not hold.** The `chat` example
  echoes; two tabs do not see each other.
- **Counters.** Requests carry an id and lines can be JSON, but how many
  requests, at what statuses, and how long is not collected anywhere.
- **TLS**, and with it HTTP/2 and a gRPC server. This is a refusal rather than a
  gap — terminate in front
  ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).
- **A `recover` middleware.** Zig cannot recover from a panic, so there is
  nothing to build ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)).
- **Compressing a handler's response**, `sendfile`, `permessage-deflate`, and
  streamed multipart. Static files *are* compressed, once, at startup.

`zfast` is a working name and may change before 1.0.
