# The nilo guide

One page per thing you might want to do. Read them in order the first time —
each one assumes the ones above it — and jump straight in afterwards.

## Which module a page is about

nilo is a toolkit of eight modules rather than one library, and which one a page
belongs to is decided by a single question — does it need the event loop?
([ADR 0041](../adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](../adr/0042-the-bottom-layer-holds-more-than-one-module.md),
[ADR 0070](../adr/0070-a-fitting-borrows-the-loop.md))

| Module | What it is | Pages |
|---|---|---|
| **`nilo_http`** | the server: routing, handlers, middleware, files, sockets | everything below except the ones named on the right |
| **`nilo_sql`** | Postgres: your struct is the table | [Talking to Postgres](./sql.md) |
| **`nilo_s3`** | object storage: your bucket is a type | [the reference](../reference.md#nilo_s3) |
| **`nilo_fetch`** | calling somebody else's HTTP API from a handler | [the reference](../reference.md#nilo_fetch) |
| **`nilo_config`** | settings out of the environment, into a struct of yours | [the reference](../reference.md#nilo_config) |
| **`nilo_pw`** | password hashing: argon2id, stored as PHC | [Sessions](./sessions.md) |
| **`nilo_id`** | UUIDs, v4 and v7 | [the reference](../reference.md#nilo_id) |
| **`nilo_core`** | `Str`, the Scope and the clock the rest share | [the reference](../reference.md#scope) |

There is **no module called `nilo`** — the word names the project, and the
server is `nilo_http`. Every example here writes the alias back, which is all it
costs:

```zig
const nilo = @import("nilo_http");
```

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
   nothing kept on the server, and checking the password that opens one.
9. [Streaming](./streaming.md) — writing an answer whose length nobody knows
   yet, and server-sent events.
10. [WebSocket](./websocket.md) — a handler that doesn't return for a while.

## Building an application

11. [Middleware](./middleware.md) — the onion, and resolved values for the
    signed-in user.
12. [Services](./services.md) — shared state across threads, locks, and the rule
    about blocking calls.
13. [Static files](./static-files.md) — a directory held in memory, with ETags
    and range requests, and a file too big to hold opened per request.
14. [Errors](./errors.md) — failing a request from anywhere, what a client is
    told, and request ids for tying a failure to its log line.
15. [Talking to Postgres](./sql.md) — `nilo_sql`: your struct is the table, the
    query is a constant, and a misspelled column is a build error. It takes a
    Scope rather than a `Ctx`, so the same query runs with no server in the
    process.

## Shipping it

16. [Testing](./testing.md) — handlers as ordinary functions, and the test
    client for the ones that write their answer.
17. [OpenAPI](./openapi.md) — an API document written from the signatures.
18. [Deploying](./deploying.md) — startup errors, panics, graceful shutdown,
    tuning, and what isn't here yet.

## Also

- [The reference](../reference.md) — the whole surface as a list.
- [`../adr/`](../adr/) — why each decision went the way it did.
- [`../roadmap.md`](../roadmap.md) — what's next, and what's refused.
- [`../../CONTEXT.md`](../../CONTEXT.md) — the project's vocabulary.
