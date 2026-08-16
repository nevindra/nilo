# The zfast guide

One page per thing you might want to do. Read them in order the first time —
each one assumes the ones above it — and jump straight in afterwards.

## Start here

1. [Getting started](./getting-started.md) — install, the two lines of root
   wiring, and a server that answers.
2. [Handlers](./handlers.md) — the one rule that decides what every argument
   means, and what a return value turns into.
3. [Routing](./routing.md) — patterns, why order doesn't matter, groups and
   plugins.

## Handling a request

4. [Requests](./requests.md) — path params, query structs, JSON bodies, and
   bodies too big to hold.
5. [Forms](./forms.md) — an HTML form as a struct of yours, file uploads, and
   the binding that names the field that broke instead of refusing the lot.
6. [Responses](./responses.md) — statuses, headers and redirects, and the `Ctx`
   layer underneath the typed one.
7. [Cookies](./cookies.md) — reading them, setting them, and the signed-in
   user.
8. [Sessions](./sessions.md) — a struct of yours, sealed into one cookie, with
   nothing kept on the server.
9. [Streaming](./streaming.md) — writing an answer whose length nobody knows
   yet, and server-sent events.
10. [WebSocket](./websocket.md) — a handler that doesn't return for a while.

## Building an application

11. [Middleware](./middleware.md) — the onion, and resolved values for the
    signed-in user.
12. [Services](./services.md) — shared state across threads, locks, and the rule
    about blocking calls.
13. [Static files](./static-files.md) — a directory held in memory, with ETags
    and range requests.
14. [Errors](./errors.md) — failing a request from anywhere, what a client is
    told, and request ids for tying a failure to its log line.

## Shipping it

15. [Testing](./testing.md) — handlers as ordinary functions, and the test
    client for the ones that write their answer.
16. [OpenAPI](./openapi.md) — an API document written from the signatures.
17. [Deploying](./deploying.md) — startup errors, panics, graceful shutdown,
    tuning, and what isn't here yet.

## Also

- [The reference](../reference.md) — the whole surface as a list.
- [`../adr/`](../adr/) — why each decision went the way it did.
- [`../roadmap.md`](../roadmap.md) — what's next, and what's refused.
- [`../../CONTEXT.md`](../../CONTEXT.md) — the project's vocabulary.
