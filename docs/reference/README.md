# Reference

**Every public name in nilo, one page per module and seven pages for the HTTP server.**

**Guide:** [the guide](../guide/README.md) · **Design:** [design, one page per topic](../design/README.md)

Read the guide to learn what something is for, and this reference for its exact signature and options. To find a name, search the [list of every heading](#every-heading) at the bottom of this page.

## Modules

Twelve modules ship, and a project links only the ones it imports ([ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md)).

| Module | What it is | Page |
|---|---|---|
| `nilo_http` | the HTTP server, covered by the seven pages listed first below | [`app.md`](./app.md) first |
| `nilo_sql` | Postgres and [SQLite](./sql.md#sqlite) | [`sql.md`](./sql.md) |
| `nilo_s3` | object storage: S3, MinIO, R2, or anything that speaks the same API | [`s3.md`](./s3.md) |
| `nilo_id` | UUIDs | [`id.md`](./id.md) |
| `nilo_config` | settings read from the environment | [`config.md`](./config.md) |
| `nilo_pw` | password hashing | [`pw.md`](./pw.md) |
| `nilo_cache` | an expiring cache in this process | [`cache.md`](./cache.md) |
| `nilo_jwt` | verifying a token someone else signed | [`jwt.md`](./jwt.md) |
| `nilo_proto` | protobuf messages read and written as plain structs | [`proto.md`](./proto.md) |
| `nilo_fetch` | calling another service's HTTP API | [`fetch.md`](./fetch.md) |
| `nilo_job` | work that runs later, again, or on a schedule, queued in your database | [`job.md`](./job.md) |
| `nilo_core` | `Str`, the [Scope](./core.md#scope) and [percent coding](./core.md#nilo_corepercent), shared by the other modules | [`core.md`](./core.md) |

```zig
const nilo = @import("nilo_http");    // the alias everybody writes
const sql = @import("nilo_sql");      // only if you talk to Postgres or SQLite
const s3 = @import("nilo_s3");        // only if you store objects
const id = @import("nilo_id");        // only if you make identifiers
const config = @import("nilo_config");// only if you read settings
const pw = @import("nilo_pw");        // only if you hash passwords or mint a token
const cache = @import("nilo_cache");  // only if you cache something
const jwt = @import("nilo_jwt");      // only if you verify somebody else's tokens
const proto = @import("nilo_proto");  // only if you speak protobuf
const job = @import("nilo_job");      // only if some work runs later, or on a schedule
```

**There is no module called `nilo`.** The word names the project: it is the `nilo: ` prefix on every Refusal, and the start of the `nilo_table`, `nilo_resolve` and `nilo_start` markers you put in your own structs. No module re-exports the others, because an umbrella module would make every project pay for the bytes of every module.

`nilo_http` re-exports what it needs from `nilo_core`, so `nilo.Str` and `nilo.Run` are the same declarations `nilo_core` holds. A program with no server imports `nilo_core` directly and links no router and no event loop.

## Declarations in the root file

These go at the top level of the file that holds `main`:

```zig
pub const std_options = nilo.std_options;         // engine chatter → warnings
pub const std_options_debug_io = nilo.debug_io;   // std.log off the event loop
pub const panic = nilo.panic;                     // optional: name the request in a crash
```

## Every heading

Every heading of every page, in page order. Find a name here, then read it on its page. `zig build docs-index` writes this list from the pages, and `zig build docs-check` refuses it when it is out of step.

**[The App](./app.md)**: The App is the server: where services, middleware and routes are registered, and what `listen()` takes to run it.

- [`App`](./app.md#app)
  - [Services and startup](./app.md#services-and-startup)
  - [Middleware](./app.md#middleware)
  - [Routes](./app.md#routes)
  - [Static files](./app.md#static-files)
  - [Documents, health, metrics, tracing and compression](./app.md#documents-health-metrics-tracing-and-compression)
  - [Running](./app.md#running)
  - [Which calls fail](./app.md#which-calls-fail)
  - [`Group`](./app.md#group)
  - [`listen` options](./app.md#listen-options)
  - [`metrics` options](./app.md#metrics-options)
  - [`compress` options](./app.md#compress-options)
  - [`trace` options](./app.md#trace-options)
- [Concurrency](./app.md#concurrency)
- [Static options](./app.md#static-options)
- [OpenAPI options](./app.md#openapi-options)
  - [The document without a server](./app.md#the-document-without-a-server)

**[Handlers](./handlers.md)**: What a handler's arguments mean, what it may return, and how its JSON is shaped.

- [Handler arguments](./handlers.md#handler-arguments)
  - [Types that parse themselves](./handlers.md#types-that-parse-themselves)
  - [`Within(min, max)`](./handlers.md#withinmin-max)
  - [`Text`, `Email` and `Url`](./handlers.md#text-email-and-url)
  - [`nilo_check`](./handlers.md#nilo_check)
  - [`Form(T)`](./handlers.md#formt)
  - [`FromHeader(name, T)`](./handlers.md#fromheadername-t)
  - [`Authorization(scheme)`](./handlers.md#authorizationscheme)
  - [`Verified(V)`](./handlers.md#verifiedv)
  - [`Idempotent(Replays, options)`](./handlers.md#idempotentreplays-options)
  - [`Cached(Pages, options)`](./handlers.md#cachedpages-options)
  - [A query field that is a list](./handlers.md#a-query-field-that-is-a-list)
  - [`Bound(W)`](./handlers.md#boundw)
  - [A body in another format](./handlers.md#a-body-in-another-format)
- [Handler returns](./handlers.md#handler-returns)
  - [A `*Ctx` handler that returns `void`](./handlers.md#a-ctx-handler-that-returns-void)
  - [A `?` inside a wrapper](./handlers.md#a--inside-a-wrapper)
  - [`Redirect(code)`](./handlers.md#redirectcode)
  - [`FileBody`](./handlers.md#filebody)
  - [`Bytes`](./handlers.md#bytes)
  - [`Versioned(T)`](./handlers.md#versionedt)
  - [A type that writes its own answer](./handlers.md#a-type-that-writes-its-own-answer)
- [JSON shapes](./handlers.md#json-shapes)
  - [A struct that renames its fields](./handlers.md#a-struct-that-renames-its-fields)
    - [Renaming one field](./handlers.md#renaming-one-field)
    - [Renamed types are for output only](./handlers.md#renamed-types-are-for-output-only)
    - [Leaf types](./handlers.md#leaf-types)
    - [Skipping the keys a body struct does not know](./handlers.md#skipping-the-keys-a-body-struct-does-not-know)
    - [Answering JSON of the wrong shape with a 422](./handlers.md#answering-json-of-the-wrong-shape-with-a-422)
    - [The marker is not inherited](./handlers.md#the-marker-is-not-inherited)
  - [`nilo.jsonParseFor`](./handlers.md#nilojsonparsefor)
  - [Unions](./handlers.md#unions)
  - [Writing JSON outside a request](./handlers.md#writing-json-outside-a-request)
  - [Text that is not UTF-8](./handlers.md#text-that-is-not-utf-8)

**[The request](./ctx.md)**: `Ctx` is one request in flight: everything a handler reads from it, answers with, and fails it with.

- [`Ctx`](./ctx.md#ctx)
  - [Reading](./ctx.md#reading)
  - [Answering](./ctx.md#answering)
  - [Response headers](./ctx.md#response-headers)
  - [Trailers](./ctx.md#trailers)
  - [`c.host` and `c.scheme`](./ctx.md#chost-and-cscheme)
  - [Compressed request bodies](./ctx.md#compressed-request-bodies)
  - [A stream with a `.length`](./ctx.md#a-stream-with-a-length)
  - [`c.url`](./ctx.md#curl)
  - [`c.sendFile`](./ctx.md#csendfile)
  - [Tracing](./ctx.md#tracing)
- [`Cookie`](./ctx.md#cookie)
- [`Session(T)`](./ctx.md#sessiont)
  - [The cookie name](./ctx.md#the-cookie-name)
  - [Expiry](./ctx.md#expiry)
  - [The secret](./ctx.md#the-secret)
- [`Upload`](./ctx.md#upload)
- [Failing](./ctx.md#failing)

**[Core](./core.md)**: `nilo_core` holds what every other module shares: `Str`, `Run`, the Scope, percent coding and the clock.

- [`Str`](./core.md#str)
- [`Run`](./core.md#run)
  - [`run.entropy`](./core.md#runentropy)
  - [`run.str` and `Str.static`](./core.md#runstr-and-strstatic)
  - [Passing a value down: `give` and `resolve`](./core.md#passing-a-value-down-give-and-resolve)
- [Scope](./core.md#scope)
  - [`AnyScope`](./core.md#anyscope)
- [`nilo_core.percent`](./core.md#nilo_corepercent)
- [The clock](./core.md#the-clock)
- [`nilo_core.tmpDir`](./core.md#nilo_coretmpdir)
- [A handler that blocks its thread](./core.md#a-handler-that-blocks-its-thread)
- [`nilo.spawn` and `app.spawn`](./core.md#nilospawn-and-appspawn)

**[Streaming](./streaming.md)**: The types for answering in pieces and holding connections open: a directory, a stream, server-sent events, a request body read in pieces, a WebSocket, and rooms that broadcast to them.

- [`Dir`](./streaming.md#dir)
- [`Stream`](./streaming.md#stream)
- [`Events`](./streaming.md#events)
  - [An event stream fed by Rooms](./streaming.md#an-event-stream-fed-by-rooms)
- [`Body`](./streaming.md#body)
- [`Socket`](./streaming.md#socket)
  - [`c.upgradeWith` options](./streaming.md#cupgradewith-options)
- [`Room`](./streaming.md#room)
  - [Several rooms](./streaming.md#several-rooms)
  - [A client that comes back](./streaming.md#a-client-that-comes-back)
- [`Rooms`](./streaming.md#rooms)

**[Middleware](./middleware.md)**: nilo's built-in middleware (logging, CORS, CSRF, security headers, rate limits, per-route deadlines and body limits), and `nilo.accept` for reading an `Accept` header.

- [Built-in middleware](./middleware.md#built-in-middleware)
  - [`nilo.cors`](./middleware.md#nilocors)
  - [`nilo.csrf`](./middleware.md#nilocsrf)
  - [`nilo.secure`](./middleware.md#nilosecure)
  - [`nilo.allowance`](./middleware.md#niloallowance)
    - [`allowance.keyed`](./middleware.md#allowancekeyed)
  - [`nilo.deadline`](./middleware.md#nilodeadline)
  - [`nilo.maxBody`](./middleware.md#nilomaxbody)
- [Holding the answer with `next.hold`](./middleware.md#holding-the-answer-with-nexthold)
- [`nilo.accept`](./middleware.md#niloaccept)

**[Testing](./testing.md)**: nilo's test helpers send requests to an App in memory, with no socket, and read back what it answered.

- [Testing](./testing.md#testing-1)
  - [`testing.Client`](./testing.md#testingclient)
  - [`answer.json`](./testing.md#answerjson)
  - [`testing.Wired`](./testing.md#testingwired)
  - [`testing.Live`](./testing.md#testinglive)
  - [`testing.Conversation`](./testing.md#testingconversation)
  - [`testing.show`](./testing.md#testingshow)
  - [`testing.tmpDir`](./testing.md#testingtmpdir)
  - [`testing.Refusals`](./testing.md#testingrefusals)

**[nilo_sql](./sql.md)**: `nilo_sql` talks to Postgres and SQLite through one API: a Row is a struct that names its table, and every statement is fixed while compiling.

- [`nilo_sql`](./sql.md#nilo_sql-1)
  - [A Row](./sql.md#a-row)
    - [`.projection`: a Row with no table](./sql.md#projection-a-row-with-no-table)
    - [`nilo_beside`: fields that are not columns](./sql.md#nilo_beside-fields-that-are-not-columns)
  - [`Db`](./sql.md#db)
    - [`db.expecting`](./sql.md#dbexpecting)
    - [`db.watching` and `sql.Sent`](./sql.md#dbwatching-and-sqlsent)
    - [`db.explain`](./sql.md#dbexplain)
    - [Starting, checking and stopping: `nilo_start`, `nilo_check`, `nilo_stop`, `nilo_ready`](./sql.md#starting-checking-and-stopping-nilo_start-nilo_check-nilo_stop-nilo_ready)
    - [The connection URL](./sql.md#the-connection-url)
    - [`Opts`](./sql.md#opts)
    - [A test suite with the database down](./sql.md#a-test-suite-with-the-database-down)
    - [A second database: `sql.Named`](./sql.md#a-second-database-sqlnamed)
    - [Prepared statements](./sql.md#prepared-statements)
    - [Views and columns the database fills](./sql.md#views-and-columns-the-database-fills)
    - [Schema in the marker: `.default`, `.unique`, `.index`, `.references`](./sql.md#schema-in-the-marker-default-unique-index-references)
  - [SQLite](./sql.md#sqlite)
    - [`threading`](./sql.md#threading)
    - [`sqlite.Options`](./sql.md#sqliteoptions)
    - [Connections and the file name](./sql.md#connections-and-the-file-name)
    - [What SQLite refuses](./sql.md#what-sqlite-refuses)
    - [Binary size](./sql.md#binary-size)
  - [Queries](./sql.md#queries)
    - [Raw parameters: `$1`, `$2`](./sql.md#raw-parameters-1-2)
    - [Set operations and round trips](./sql.md#set-operations-and-round-trips)
    - [Casting to text in a raw statement](./sql.md#casting-to-text-in-a-raw-statement)
    - [`rawOne`, `updateReturningOne`, `deleteReturningOne`](./sql.md#rawone-updatereturningone-deletereturningone)
    - [`db.page`](./sql.md#dbpage)
    - [`db.feed`](./sql.md#dbfeed)
  - [A batch](./sql.md#a-batch)
    - [`insertMany`](./sql.md#insertmany)
    - [`updateMany`](./sql.md#updatemany)
  - [Upserts](./sql.md#upserts)
  - [Options](./sql.md#options)
  - [Conditions](./sql.md#conditions)
    - [Null in a condition](./sql.md#null-in-a-condition)
    - [`sql.given`: a filter that may be absent](./sql.md#sqlgiven-a-filter-that-may-be-absent)
    - [`.across`: one search over several columns](./sql.md#across-one-search-over-several-columns)
  - [`sql.Ordering`: an order chosen at run time](./sql.md#sqlordering-an-order-chosen-at-run-time)
    - [`db.rawOrdered` and `db.rawPageOrdered`](./sql.md#dbrawordered-and-dbrawpageordered)
    - [Cost and refusals](./sql.md#cost-and-refusals)
  - [`.exists`: a condition on another table](./sql.md#exists-a-condition-on-another-table)
  - [A key of several columns](./sql.md#a-key-of-several-columns)
  - [A parent, children, a group](./sql.md#a-parent-children-a-group)
    - [How the join is found](./sql.md#how-the-join-is-found)
    - [`nilo_through`](./sql.md#nilo_through)
    - [`nilo_aggregate`](./sql.md#nilo_aggregate)
    - [`nilo_children`](./sql.md#nilo_children)
    - [Which calls accept these Rows](./sql.md#which-calls-accept-these-rows)
    - [`db.exactlyOne`](./sql.md#dbexactlyone)
  - [Streaming](./sql.md#streaming)
  - [`Tx`](./sql.md#tx)
    - [`tx.deadline`](./sql.md#txdeadline)
    - [`.lock`: holding the rows a read matched](./sql.md#lock-holding-the-rows-a-read-matched)
    - [Savepoints](./sql.md#savepoints)
  - [Types](./sql.md#types)
    - [A column type of your own](./sql.md#a-column-type-of-your-own)
    - [`Timestamp.nilo_parse`](./sql.md#timestampnilo_parse)
    - [Array columns](./sql.md#array-columns)
  - [Errors](./sql.md#errors)
    - [`sql.problem`](./sql.md#sqlproblem)
    - [`sql.violated`](./sql.md#sqlviolated)
  - [Migrations](./sql.md#migrations)
    - [The marker's schema words](./sql.md#the-markers-schema-words)
    - [Enum columns](./sql.md#enum-columns)
    - [`.managed = false`](./sql.md#managed--false)
    - [Constraint names](./sql.md#constraint-names)
    - [Generated keys](./sql.md#generated-keys)
    - [The schema](./sql.md#the-schema)
    - [Creating tables](./sql.md#creating-tables)
    - [The diff](./sql.md#the-diff)
    - [The ledger, and applying](./sql.md#the-ledger-and-applying)
    - [Refusing to serve a database that is behind](./sql.md#refusing-to-serve-a-database-that-is-behind)
    - [The files](./sql.md#the-files)
    - [The `.sql` twin](./sql.md#the-sql-twin)
    - [The generated block](./sql.md#the-generated-block)
    - [The commands](./sql.md#the-commands)
    - [Starting a migrations directory](./sql.md#starting-a-migrations-directory)

**[nilo_s3](./s3.md)**: `nilo_s3` reads and writes objects in S3 and anything that speaks the same API, with each bucket declared as a type.

- [`nilo_s3`](./s3.md#nilo_s3-1)
  - [`Store` and `Bucket`](./s3.md#store-and-bucket)
  - [Bucket calls](./s3.md#bucket-calls)
  - [`bucket.presignPost`](./s3.md#bucketpresignpost)
  - [`s3.Options`](./s3.md#s3options)
  - [Bucket options](./s3.md#bucket-options)
  - [Temporary credentials](./s3.md#temporary-credentials)
  - [Errors](./s3.md#errors)
  - [What it does not do](./s3.md#what-it-does-not-do)
  - [What it costs](./s3.md#what-it-costs)

**[nilo_fetch](./fetch.md)**: `nilo_fetch` is an HTTP client for calling somebody else's API from inside a request, with the limits a server needs.

- [`nilo_fetch`](./fetch.md#nilo_fetch-1)
  - [`fetch.Client` calls](./fetch.md#fetchclient-calls)
  - [`Client.Settings`](./fetch.md#clientsettings)
  - [`Client.Call`](./fetch.md#clientcall)
  - [A call under a traced request](./fetch.md#a-call-under-a-traced-request)
  - [Responses with no body](./fetch.md#responses-with-no-body)
  - [Errors](./fetch.md#errors)
  - [Compression](./fetch.md#compression)
  - [What it does not do](./fetch.md#what-it-does-not-do)
  - [`fetch.Target`](./fetch.md#fetchtarget)
  - [`fetch.Exchange`](./fetch.md#fetchexchange)
  - [`fetch.testing`](./fetch.md#fetchtesting)

**[nilo_job](./job.md)**: `nilo_job` runs work later, again, or on a schedule, from a queue stored as a table in the database you already have.

- [`nilo_job`](./job.md#nilo_job-1)
  - [Job declarations](./job.md#job-declarations)
  - [`job.Tick`](./job.md#jobtick)
  - [`job.Jobs(.{ … })`](./job.md#jobjobs--)
  - [`Jobs` calls](./job.md#jobs-calls)
  - [Push options](./job.md#push-options)
  - [`job.Settings`](./job.md#jobsettings)
  - [Schedules: `job.cron` and `job.every`](./job.md#schedules-jobcron-and-jobevery)
  - [Stores: `job.Table` and `job.Memory`](./job.md#stores-jobtable-and-jobmemory)
  - [Errors](./job.md#errors)
  - [What it does not do](./job.md#what-it-does-not-do)

**[nilo_id](./id.md)**: `nilo_id` makes, prints and parses UUIDs (v4 and v7), with no allocation and no IO.

- [`nilo_id`](./id.md#nilo_id-1)
  - [`id.v7Now` and `id.v7`](./id.md#idv7now-and-idv7)
  - [Printing a `Uuid`](./id.md#printing-a-uuid)
  - [How v7 keys sort](./id.md#how-v7-keys-sort)
  - [Entropy](./id.md#entropy)

**[nilo_config](./config.md)**: `nilo_config` reads settings from the environment into a struct of your own, and names every bad setting at once before the server starts.

- [`nilo_config`](./config.md#nilo_config-1)
  - [`config.fromEnv` and `config.from`](./config.md#configfromenv-and-configfrom)
  - [`Read(T)`](./config.md#readt)
  - [`Failure`](./config.md#failure)
  - [Sources](./config.md#sources)
  - [A `.env`](./config.md#a-env)

**[nilo_pw](./pw.md)**: `nilo_pw` hashes and checks passwords with Argon2id, and makes the random tokens behind reset links and API keys.

- [`nilo_pw`](./pw.md#nilo_pw-1)
  - [Call the `Ctx` methods](./pw.md#call-the-ctx-methods)
  - [`stored` may be null](./pw.md#stored-may-be-null)
  - [A stored string that is not a hash](./pw.md#a-stored-string-that-is-not-a-hash)
  - [The allocator](./pw.md#the-allocator)
  - [The PHC format](./pw.md#the-phc-format)
  - [Checking without a request](./pw.md#checking-without-a-request)
- [A token that is not a password](./pw.md#a-token-that-is-not-a-password)
  - [`pw.Token`](./pw.md#pwtoken)

**[nilo_cache](./cache.md)**: `nilo_cache` is an expiring cache inside this process, with a fixed memory budget taken once at `open`.

- [`nilo_cache`](./cache.md#nilo_cache-1)
  - [`Store` and `Space`](./cache.md#store-and-space)
  - [`space.get` and `Held`](./cache.md#spaceget-and-held)
  - [Values with pointers](./cache.md#values-with-pointers)
  - [`cache.open` options](./cache.md#cacheopen-options)
  - [`store.stats()`](./cache.md#storestats)
  - [Locking and admission](./cache.md#locking-and-admission)
  - [Sizing](./cache.md#sizing)
  - [Memory per entry](./cache.md#memory-per-entry)
  - [What it will not do](./cache.md#what-it-will-not-do)

**[nilo_jwt](./jwt.md)**: `nilo_jwt` checks a JWT that somebody else signed (RS256 or ES256), and never signs or fetches one itself.

- [`nilo_jwt`](./jwt.md#nilo_jwt-1)
  - [`jwt.verify` and `jwt.Keys`](./jwt.md#jwtverify-and-jwtkeys)
  - [`Options`](./jwt.md#options)
  - [Fetching the key set](./jwt.md#fetching-the-key-set)
  - [What is not an option](./jwt.md#what-is-not-an-option)
  - [Errors](./jwt.md#errors)
  - [`jwt.Keyring`](./jwt.md#jwtkeyring)
  - [`jwt.Verifier(Claims, Client)`](./jwt.md#jwtverifierclaims-client)
  - [What it does not do](./jwt.md#what-it-does-not-do)

**[nilo_proto](./proto.md)**: `nilo_proto` reads and writes protobuf messages as plain Zig structs, with the field numbers declared on the type and nothing generated.

- [`nilo_proto`](./proto.md#nilo_proto-1)
  - [`proto.decode` and `proto.merge`](./proto.md#protodecode-and-protomerge)
  - [`proto.encode`](./proto.md#protoencode)
  - [The `wire` table](./proto.md#the-wire-table)
  - [Types](./proto.md#types)
  - [Maps](./proto.md#maps)
  - [Merge rules](./proto.md#merge-rules)
  - [Unknown fields and groups](./proto.md#unknown-fields-and-groups)
  - [Errors](./proto.md#errors)
  - [`proto.Reader`](./proto.md#protoreader)
  - [What it does not do](./proto.md#what-it-does-not-do)
