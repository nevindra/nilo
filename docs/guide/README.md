# The nilo guide

**One page per thing you might want to do, in an order where each page builds on the ones before it.**

**Reference:** [every public name, one page a module](../reference/README.md) · **Design:** [why each part works the way it does, one page a topic](../design/README.md)

Read the pages in order the first time, since each one assumes the ones above it, and jump straight to what you need after that.

## Which page covers which module

**nilo is a toolkit of twelve modules, not one library.** Which module a feature lives in is decided by one question: does it need the event loop? ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md), [ADR 061](../adr/061-a-fitting-borrows-the-loop.md))

| Module | What it is | Pages |
|---|---|---|
| **`nilo_http`** | the server: routing, handlers, middleware, files, sockets | everything below except the ones named on the right |
| **`nilo_sql`** | Postgres and SQLite: your struct is the table | [Talking to a database](./sql/README.md), nine pages |
| **`nilo_s3`** | object storage: your bucket is a type | [Object storage](./s3.md) |
| **`nilo_fetch`** | calling somebody else's HTTP API from a handler | [Calling somebody else's API](./fetch.md) |
| **`nilo_job`** | work that runs later, again, or on a schedule: a queue in your database | [Work that runs later](./jobs.md) |
| **`nilo_config`** | settings read from the environment into a struct of yours | [Settings](./config.md) |
| **`nilo_pw`** | password hashing: argon2id, stored as PHC | [Sessions](./sessions.md#sign-in-and-password-checking) |
| **`nilo_cache`** | an expiring cache in this process, holding no pointers | [A cache in this process](./cache.md), and the Space that [Idempotency keys](./idempotency.md) keeps its answers in |
| **`nilo_jwt`** | checking somebody else's signed token: RS256, ES256 and a JWKS | [Checking somebody else's token](./jwt.md) |
| **`nilo_proto`** | protobuf messages as plain structs: OTLP, a gRPC method's message | [Protobuf messages](./proto.md) |
| **`nilo_id`** | UUIDs, v4 and v7 | [Identifiers](./id.md) |
| **`nilo_core`** | `Str`, the Scope and the clock the rest share | [the reference](../reference/core.md#scope) |

**There is no module called `nilo`.** The word names the project, and the server module is `nilo_http`. Every example here imports it under the shorter name, which is one line:

```zig
const nilo = @import("nilo_http");
```

## Start here

1. [Getting started](./getting-started.md): installing, the two lines of root wiring, and a server that answers.
2. [Handlers](./handlers.md): the rule that decides what every argument means, and what a return value turns into.
3. [Routing](./routing.md): patterns, route priority, groups and plugins.

## Handling a request

4. [Requests](./requests.md): path params, query structs, JSON bodies, and bodies too big to hold in memory.
5. [Forms](./forms.md): an HTML form as a struct of yours, file uploads, and binding that names the field that failed instead of rejecting the whole form.
6. [Responses](./responses.md): statuses, headers and redirects, and the `Ctx` layer underneath the typed one.
7. [Cookies](./cookies.md): reading them, setting them, and the signed-in user.
8. [Sessions](./sessions.md): a struct of yours sealed into one cookie, with nothing kept on the server, and checking the password that opens one.
9. [Streaming](./streaming.md): writing an answer whose length is not known yet, and server-sent events.
10. [WebSocket](./websocket.md): a handler that keeps a connection open for a while.
11. [gRPC](./grpc.md): a gRPC method as a route, on a listener of its own, in a build that asks for it.

## Building an application

12. [Middleware](./middleware.md): code that runs around every handler, and resolved values for the signed-in user.
13. [Services](./services.md): shared state across threads, locks, and the rule about blocking calls.
14. [Static files](./static-files.md): a directory held in memory, with ETags and range requests, and files too big to hold opened per request.
15. [Errors](./errors.md): failing a request from anywhere, what the client is told, and request ids that tie a failure to its log line.
16. [Settings](./config.md): `nilo_config` reads the environment into a struct of yours before anything opens, reports every bad setting at once, and shows a complete `main` that reads a `.env`.
17. [Background work](./background.md): work no request started, such as a summary written every minute or a cache warmed at startup. It runs in a fiber the server owns and stops at shutdown. For work that is a database row rather than a loop, see `nilo_job` below.
18. [Idempotency keys](./idempotency.md): the `Idempotency-Key` header as a typed argument. A retry gets the saved answer back, the order is placed once, and a key reused wrongly gets a 409 or 422.

## The other modules

**Each module has one page, except the database, which has a folder.** Every page covers what the module is for, a complete example, every option with its default, what it returns instead of a value, what it costs, and what it will not do.

19. [Talking to a database](./sql/README.md): `nilo_sql`. Your struct is the table, the query is a constant, and a misspelled column is a build error. Postgres and SQLite are written the same way. Nine pages, in order: [tables](./sql/tables.md), [reading](./sql/reading.md), [parents, children and aggregates](./sql/shapes.md), [writing](./sql/writing.md), [transactions](./sql/transactions.md), [raw SQL](./sql/raw.md), [SQLite](./sql/sqlite.md), [migrations](./sql/migrations.md) and [running a database](./sql/running.md).
20. [Calling somebody else's API](./fetch.md): `nilo_fetch`. One client for the whole program, a deadline on every call, a response body in the request's own memory, and an `Exchange` for a body too big to hold.
21. [Object storage](./s3.md): `nilo_s3`. A bucket is a type, a key is a string. Reading, writing, streaming an object through, and a presigned URL or POST form for a browser that talks to the bucket directly.
22. [Work that runs later](./jobs.md): `nilo_job`. A job is a struct, the queue is a table in the database you already have, `pushIn(&tx, …)` commits together with your rows, and a schedule must declare what an overlap and a missed tick mean or it does not compile.
23. [A cache in this process](./cache.md): `nilo_cache`. A typed keyspace over one fixed memory budget, no pointers allowed in a value, lookups that take no lock, and a `stats()` that explains why it is not hitting.
24. [Checking somebody else's token](./jwt.md): `nilo_jwt`. A JWT signed by an identity provider, verified in a safe order and read into a struct of yours; the signed-in user as a resolved value; and what a key rotation looks like.
25. [Protobuf messages](./proto.md): `nilo_proto`. A message is the struct you wrote with its field numbers declared beside it, read and written with no generator and no `.proto` file; strings checked, unknown fields skipped, and the decoder within a few percent of one written by hand.
26. [Identifiers](./id.md): `nilo_id`. A v7 for a key that sorts by creation time, what that order does and does not guarantee, and why the randomness is an argument.

## Shipping it

27. [Testing](./testing.md): handlers as ordinary functions, and the test client for the ones that write their own answer.
28. [OpenAPI](./openapi.md): an API document generated from the handler signatures.
29. [Metrics](./metrics.md): how many requests, at what statuses, how long. A Prometheus page in one call, and counters of your own on it.
30. [Tracing](./tracing.md): every request a span, sent to any OpenTelemetry receiver in one call; a trace that continues through `nilo_fetch` into the next service, and spans of your own.
31. [Deploying](./deploying.md): startup errors, panics, graceful shutdown, a health page the load balancer can trust, tuning, and what is not there yet.

## Other documentation

- [The reference](../reference/README.md): every public name, as a list.
- [The design pages](../design/README.md): one page a topic, with the rules in force and the decisions behind them.
- [`../adr/`](../adr/): why each decision went the way it did.
- [`../todo.md`](../todo.md): what's next.
- [`../decided.md`](../decided.md): what's refused, and why.
- [`../../CONTEXT.md`](../../CONTEXT.md): the project's vocabulary.
