# nilo documentation

**Start here: every topic in nilo, with its guide page, its reference page and its design page side by side.**

**Guide:** [the guide](./guide/README.md) · **Reference:** [the reference](./reference/README.md) · **Design:** [design, one page per topic](./design/README.md)

## How the documentation is organised

Each topic is written up to three times, for three different questions:

| Layer | Answers | One page per | Where |
|---|---|---|---|
| **Guide** | How do I do this? Worked examples, in reading order. | task | [`docs/guide/`](./guide/README.md), also published as the website |
| **Reference** | What exactly is this name, and what does it take? | module | [`docs/reference/`](./reference/README.md) |
| **Design** | Why does it work this way, and what was rejected? | topic | [`docs/design/`](./design/README.md) |

Behind the design pages are the ADRs in [`docs/adr/`](./adr/), one decision each with the alternative it rejected. A design page lists every ADR of its topic, so read the design page first and an ADR when you need the evidence. The words the project uses, and the ones it avoids, are in [`CONTEXT.md`](../CONTEXT.md).

## How to read a page

Every page in the three folders starts the same way:

- **Line 1** is the title.
- **Line 3** is one bold sentence saying what the page is about.
- **Line 5** links the same topic in the other two layers.

Headings name what a section covers, in the words you would search for. Reference headings are the symbol itself (`Db`, `Bucket`, `c.url`), and [every heading of the reference](./reference/README.md#every-heading) is listed on one page. A guide section's first sentence, in bold, is the thing to know about it.

**For an agent**, the fastest way in is the outline, then a search:

```sh
head -5 docs/guide/*.md docs/guide/sql/*.md      # what each page is, and where its other layers are
grep -n '^#' docs/reference/sql.md                # a page's outline, with line numbers
grep -rn '`db.page`' docs/                        # every place a symbol is written
```

Prose is one paragraph per line, so a phrase is never split across two lines, and `zig build docs-check` keeps all of the above true.

## Topics

In the order the guide teaches them. Each row is one guide page and the reference and design pages that go with it.

### Start here

| Topic | Module | Reference | Design |
|---|---|---|---|
| [Getting started](./guide/getting-started.md) | `nilo_http` | [`App`](./reference/app.md#app), [`listen` options](./reference/app.md#listen-options), [root wiring](./reference/README.md#declarations-in-the-root-file) | [nilo's design principles](./design/principles.md) |
| [Handlers](./guide/handlers.md) | `nilo_http` | [handler arguments](./reference/handlers.md#handler-arguments), [handler returns](./reference/handlers.md#handler-returns), [`Str`](./reference/core.md#str) | [Typed handlers](./design/typed-handlers.md) |
| [Routing](./guide/routing.md) | `nilo_http` | [`App`](./reference/app.md#app), [`Group`](./reference/app.md#group) | [Routing](./design/routing.md) |

### Handling a request

| Topic | Module | Reference | Design |
|---|---|---|---|
| [Requests](./guide/requests.md) | `nilo_http` | [handler arguments](./reference/handlers.md#handler-arguments), [reading a request from `Ctx`](./reference/ctx.md#reading), [`Body`](./reference/streaming.md#body) | [Request input](./design/request-input.md) |
| [Forms](./guide/forms.md) | `nilo_http` | [`Form(T)`](./reference/handlers.md#handler-arguments), [`Bound(W)`](./reference/handlers.md#boundw), [`Upload`](./reference/ctx.md#upload), [`c.form`](./reference/ctx.md#reading) | [Request input](./design/request-input.md) |
| [Responses](./guide/responses.md) | `nilo_http` | [`Ctx`: answering](./reference/ctx.md#answering), [handler returns](./reference/handlers.md#handler-returns), [JSON shapes](./reference/handlers.md#json-shapes), [`compress` options](./reference/app.md#compress-options) | [Responses](./design/responses.md), [JSON](./design/json.md) |
| [Cookies](./guide/cookies.md) | `nilo_http` | [`c.cookie`, `c.setCookie`, `c.clearCookie`](./reference/ctx.md#answering), [the `Cookie` options](./reference/ctx.md#cookie) | [Cookies and sessions](./design/cookies-sessions.md) |
| [Sessions](./guide/sessions.md) | `nilo_http`, `nilo_pw` | [`Session(T)`](./reference/ctx.md#sessiont), [`session_secret` and the other `listen` options](./reference/app.md#listen-options), [password calls on `Ctx`](./reference/ctx.md#reading), [`nilo_pw`](./reference/pw.md) | [Cookies and sessions](./design/cookies-sessions.md) |
| [Streaming](./guide/streaming.md) | `nilo_http` | [`Stream`](./reference/streaming.md#stream), [`Events`](./reference/streaming.md#events), [`Room`](./reference/streaming.md#room), [`Rooms`](./reference/streaming.md#rooms) | [Responses](./design/responses.md) |
| [WebSocket](./guide/websocket.md) | `nilo_http` | [`c.upgrade`](./reference/ctx.md#answering), [`Socket`](./reference/streaming.md#socket), [`Room`](./reference/streaming.md#room), [`Rooms`](./reference/streaming.md#rooms) | [WebSockets](./design/websocket.md) |
| [gRPC](./guide/grpc.md) | `nilo_http` | [`listen` options (`also`, `tls`)](./reference/app.md#listen-options) | none; the decision is [ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md) |

### Building an application

| Topic | Module | Reference | Design |
|---|---|---|---|
| [Middleware and resolved values](./guide/middleware.md) | `nilo_http` | [`app.use`, `app.useOn`](./reference/app.md#app), [`with`, `without`](./reference/app.md#group), [built-in middleware](./reference/middleware.md#built-in-middleware), [`nilo.secure`](./reference/middleware.md#nilosecure) | [Middleware](./design/middleware.md), [CORS and the proxy](./design/cors-proxy.md), [Rate limiting](./design/rate-limiting.md) |
| [Services](./guide/services.md) | `nilo_http` | [`app.provide`](./reference/app.md#app), [`nilo.blocking` and `nilo.Mutex`](./reference/app.md#concurrency) | [Lifecycle](./design/lifecycle.md), [Memory](./design/memory.md) |
| [Static files](./guide/static-files.md) | `nilo_http` | [`app.static`, `app.embedded`](./reference/app.md#app), [static options](./reference/app.md#static-options) | [Static files](./design/static-files.md) |
| [Errors](./guide/errors.md) | `nilo_http` | [`fail` functions](./reference/ctx.md#failing), [`app.failures`](./reference/app.md#app), [`c.requestId`](./reference/ctx.md#reading) | [Errors](./design/errors.md) |
| [Settings](./guide/config.md) | `nilo_config` | [`nilo_config`](./reference/config.md#nilo_config), [a `.env`](./reference/config.md#a-env) | [Layering](./design/layering.md) (config is one of its single-ADR topics) |
| [Background work](./guide/background.md) | `nilo_http` | [`app.spawn`, `app.before`, `app.start`](./reference/app.md#app), [`nilo.spawn`](./reference/app.md#concurrency), [`nilo.spawn` and `app.spawn`](./reference/core.md#nilospawn-and-appspawn) | [The engine](./design/engine.md) |
| [Idempotency keys](./guide/idempotency.md) | `nilo_http` | [`Idempotent(Replays, options)`](./reference/handlers.md#idempotentreplays-options) | [Idempotency](./design/idempotency.md) |

### The other modules

| Topic | Module | Reference | Design |
|---|---|---|---|
| [Talking to a database](./guide/sql/README.md) | `nilo_sql` | [`nilo_sql`](./reference/sql.md#nilo_sql), [`Db`](./reference/sql.md#db) | [The query builder](./design/sql-query.md), [The SQL runtime](./design/sql-runtime.md) |
| [A table is a struct](./guide/sql/tables.md) | `nilo_sql` | [A Row](./reference/sql.md#a-row), [Types](./reference/sql.md#types) | [SQL column types](./design/sql-types.md) |
| [Reading](./guide/sql/reading.md) | `nilo_sql` | [Queries](./reference/sql.md#queries), [Conditions](./reference/sql.md#conditions), [Streaming](./reference/sql.md#streaming) | [The query builder](./design/sql-query.md) |
| [Parents, children and aggregates](./guide/sql/shapes.md) | `nilo_sql` | [A parent, children, a group](./reference/sql.md#a-parent-children-a-group) | [The query builder](./design/sql-query.md) |
| [Writing](./guide/sql/writing.md) | `nilo_sql` | [Queries](./reference/sql.md#queries), [A batch](./reference/sql.md#a-batch), [Upserts](./reference/sql.md#upserts), [Options](./reference/sql.md#options) | [The query builder](./design/sql-query.md) |
| [Transactions](./guide/sql/transactions.md) | `nilo_sql` | [`Tx`](./reference/sql.md#tx), [locked reads](./reference/sql.md#lock-holding-the-rows-a-read-matched), [savepoints](./reference/sql.md#savepoints) | [The SQL runtime](./design/sql-runtime.md) |
| [Raw SQL](./guide/sql/raw.md) | `nilo_sql` | [raw queries](./reference/sql.md#queries), [a Row that owns no table](./reference/sql.md#projection-a-row-with-no-table) | [Raw statements](./design/sql-raw.md) |
| [SQLite](./guide/sql/sqlite.md) | `nilo_sql` | [SQLite](./reference/sql.md#sqlite) | [The SQL runtime](./design/sql-runtime.md), [SQL column types](./design/sql-types.md) |
| [Migrations](./guide/sql/migrations.md) | `nilo_sql` | [migrations](./reference/sql.md#migrations), [the schema](./reference/sql.md#the-schema), [the commands](./reference/sql.md#the-commands) | [Migrations](./design/sql-migrations.md) |
| [Running a database: checks, logging and errors](./guide/sql/running.md) | `nilo_sql` | [`Db`](./reference/sql.md#db), [errors](./reference/sql.md#errors) | [The SQL runtime](./design/sql-runtime.md) |
| [Calling somebody else's API](./guide/fetch.md) | `nilo_fetch` | [`nilo_fetch`](./reference/fetch.md#nilo_fetch), [`fetch.Target`](./reference/fetch.md#fetchtarget), [`fetch.Exchange`](./reference/fetch.md#fetchexchange), [`fetch.testing`](./reference/fetch.md#fetchtesting) | [Outbound calls](./design/fetch.md) |
| [Object storage](./guide/s3.md) | `nilo_s3` | [`nilo_s3`](./reference/s3.md#nilo_s3) | [Object storage](./design/s3.md) |
| [Work that runs later, again, or on a schedule](./guide/jobs.md) | `nilo_job` | [`nilo_job`](./reference/job.md#nilo_job) | [Jobs](./design/job.md) |
| [A cache in this process](./guide/cache.md) | `nilo_cache` | [`nilo_cache`](./reference/cache.md#nilo_cache), [`Cached(Pages, options)`](./reference/handlers.md#cachedpages-options) | [The in-process cache](./design/cache.md) |
| [Checking somebody else's token](./guide/jwt.md) | `nilo_jwt` | [`nilo_jwt`](./reference/jwt.md#nilo_jwt), [`jwt.Keyring`](./reference/jwt.md#jwtkeyring), [`jwt.Verifier`](./reference/jwt.md#jwtverifierclaims-client), [`Verified(V)`](./reference/handlers.md#verifiedv) | [JWT verification](./design/jwt.md) |
| [Protobuf messages](./guide/proto.md) | `nilo_proto` | [`nilo_proto`](./reference/proto.md#nilo_proto), [`proto.decode`](./reference/proto.md#protodecode-and-protomerge), [`proto.encode`](./reference/proto.md#protoencode), [the `wire` table](./reference/proto.md#the-wire-table) | [Protobuf](./design/proto.md) |
| [Identifiers](./guide/id.md) | `nilo_id` | [`nilo_id`](./reference/id.md#nilo_id) | [The clock, entropy, and a UUID](./design/id-clock-entropy.md) |

### Shipping it

| Topic | Module | Reference | Design |
|---|---|---|---|
| [Testing](./guide/testing.md) | `nilo_http` | [`nilo.testing.Client`](./reference/testing.md#testingclient), [`Wired`](./reference/testing.md#testingwired), [`testing.Live`](./reference/testing.md#testinglive), [`testing.tmpDir`](./reference/testing.md#testingtmpdir) | [Testing](./design/testing.md) |
| [OpenAPI](./guide/openapi.md) | `nilo_http` | [OpenAPI options](./reference/app.md#openapi-options), [the document without a server](./reference/app.md#the-document-without-a-server), [handler returns](./reference/handlers.md#handler-returns) | [OpenAPI](./design/openapi.md) |
| [Metrics](./guide/metrics.md) | `nilo_http` | [`app.metrics`, `app.expose`](./reference/app.md#app), [`metrics` options](./reference/app.md#metrics-options) | none; the decision is [ADR 079](./adr/079-the-route-table-is-the-registry.md) |
| [Tracing](./guide/tracing.md) | `nilo_http` | [`app.trace`](./reference/app.md#app), [trace options](./reference/app.md#trace-options), [`c.span` and `c.traceId`](./reference/ctx.md#tracing) | none; the decision is [ADR 247](./adr/247-a-request-is-a-span-and-the-trace-leaves-as-otlp.md) |
| [Deploying](./guide/deploying.md) | `nilo_http` | [`listen` options](./reference/app.md#listen-options), [`App`](./reference/app.md#app) | [Lifecycle](./design/lifecycle.md), [Deadlines](./design/deadlines.md), [Memory](./design/memory.md), [TLS](./design/tls.md), [The engine](./design/engine.md), [CORS and the proxy in front](./design/cors-proxy.md) |

### Design topics with no guide page of their own

These are covered inside the guide pages named on the right, or matter only when changing nilo itself.

| Topic | Design | Where the guide covers it |
|---|---|---|
| Principles: the four costs every change is measured against | [nilo's design principles](./design/principles.md) | [Getting started](./guide/getting-started.md) |
| Which module a file goes in, and what it may import | [Layering](./design/layering.md) | [the guide's module table](./guide/README.md) |
| Memory per request and per connection | [Memory](./design/memory.md) | [Deploying](./guide/deploying.md), [Services](./guide/services.md) |
| Accepting and serving connections | [The engine](./design/engine.md) | [Deploying](./guide/deploying.md) |
| Parsing HTTP/1.1 | [The HTTP/1.1 wire protocol](./design/http1-protocol.md) | [Requests](./guide/requests.md) |
| Writing an answer in HTTP/1.1 or HTTP/2 | [Framing](./design/framing.md) | [Requests](./guide/requests.md) |
| TLS | [TLS](./design/tls.md) | [Deploying](./guide/deploying.md) |
| Timeouts on network waits | [Deadlines](./design/deadlines.md) | [Deploying](./guide/deploying.md) |
| Startup, services and shutdown | [Lifecycle](./design/lifecycle.md) | [Services](./guide/services.md), [Deploying](./guide/deploying.md) |
| CORS and the proxy in front | [CORS and the proxy in front](./design/cors-proxy.md) | [Middleware](./guide/middleware.md), [Deploying](./guide/deploying.md) |
| Rate limiting | [Rate limiting](./design/rate-limiting.md) | [Middleware](./guide/middleware.md) |
| JSON field names and shapes | [JSON](./design/json.md) | [Responses](./guide/responses.md) |
| The clock, randomness and UUIDs | [The clock, entropy, and a UUID](./design/id-clock-entropy.md) | [Identifiers](./guide/id.md) |
| How the documentation is checked | [Documentation tooling](./design/docs-tooling.md) | none |

## Everything else in `docs/`

| File | What it holds |
|---|---|
| [`../CHANGELOG.md`](../CHANGELOG.md) | what changed in each release, and under `## Unreleased` what will |
| [`roadmap.md`](./roadmap.md) | where the framework is heading: a few directions, each larger than one change |
| [`todo.md`](./todo.md) | every concrete item still open: defects, decisions, callers awaited, questions, measurements and upstream fixes |
| [`decided.md`](./decided.md) | questions already answered, gaps kept on purpose, and features refused with the reason |
| [`history.md`](./history.md) | lessons learned while building nilo: numbers measured, premises that turned out false |
| [`risks.md`](./risks.md) | risks that are not bugs, and what guards against each |
| [`comparison.md`](./comparison.md) | nilo measured against other frameworks |
| [`releasing.md`](./releasing.md) | how a release is cut |
| `input_from_*.md` | notes from porting real applications to nilo, and what each asked of it |
