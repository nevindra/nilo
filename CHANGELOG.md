# Changelog

What changed between one tag and the next — not what changed between commits.
What was measured and what was got wrong on the way is in
[`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

**zfast is now nilo**, and the SQL module went from compiling queries to
running them. Needs Zig 0.16.

Install it pinned — `zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.2.0`.

### Breaking: the rename

Everything spelled `zfast` is spelled `nilo`, and **the server's module is
`nilo_http` rather than `nilo`** — the bare name belongs to the project, which
now has three modules rather than one
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md)). A search
and replace covers all of it:

| Was | Is |
|---|---|
| `@import("zfast")` | `@import("nilo_http")` |
| `zfast_table`, `zfast_resolve`, `zfast_query`, `zfast_response` | `nilo_table`, `nilo_resolve`, … |
| `.zfast` in `build.zig.zon`, `zfast_sql` | `.nilo`, `nilo_sql` |
| `nilo.module("nilo")` in your `build.zig` | `nilo.module("nilo_http")` |

The markers are the ones worth knowing about, because they sit in **your**
structs rather than behind the import line — and they are the ones that
**do not** move again, because they are named after the project rather than
after a module. Alias the import back and the rest of your code is unchanged:

```zig
const nilo = @import("nilo_http");
```

Nothing else about the API changed in this release.

### `nilo_sql` runs

The compile-time half shipped in 0.1.0 and could not reach a socket. It can
now, over [pg.zig](https://github.com/lalinsky/pg.zig), checked against a
real Postgres on every push.

- **Reading** — `db.select`, `db.one`, and `db.stream` for a result set too
  big to hold. `one` returns `?Row`, so a handler returning `!?User` answers
  404 and the OpenAPI document says so, and it compiles its own `LIMIT 1` —
  a lookup on a column that is not unique costs one row rather than every
  match.
- **`db.count` and `db.exists`** — the total a page needs, and whether
  anything matches at all. Both take a condition and nothing else, both go
  through the same walker `select` uses, so a page and its total are one
  condition written once and a misspelled column is the same compile error in
  both. `exists` is `SELECT EXISTS(…)`, which stops at the first row.
- **A written-out `.limit` now costs one allocation, at any size.** The limit
  is a ceiling known before the first row arrives, so the list the rows go
  into is built to it instead of doubling its way there. Measured over a
  32-byte row: one allocation from ten rows to a hundred thousand, against 2,
  3, 5 and 9 without it. [ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)
  claimed a number here for a year and the number was wrong; it is corrected
  in place and a test now holds it.
- **Writing** — `db.insert` (with `RETURNING`, so the generated key comes
  back), `db.update` and `db.delete`, both answering with the number of rows
  they touched and both refusing to compile without a condition.
- **Transactions** — `db.begin(c)`, held and released the way every other
  resource in nilo is: `defer tx.deinit()` rolls back unless committed.
- **`db.raw`** — the way past *one table, conditions that filter rows*. Still
  fills your struct, still uses the arena; gives up the column check only.
- **`db.checking(&.{ User, Order })`** — each Row compared against its table
  while the server starts, instead of on whichever request got there first.
- **`sql.Timestamp`, `sql.Uuid` and `sql.Json(T)`** — the three columns Zig
  has no word for, read and written as themselves. A `timestamptz` arrives as
  microseconds since the epoch, a `uuid` as its sixteen bytes and a `jsonb`
  parsed into the struct you named; each writes itself into a JSON body the
  way the API description promises.
- Rows come out of the request arena. A streamed row is `sql.Borrowed(User)`,
  which is `User` with every `Str` replaced by `[]const u8` — because that
  text dies at the next row, and the type says so. `stream` refuses a Row
  with a `Json` column: a borrowed row allocates nothing, and parsing a
  document per row cannot.
- **A `.limit` or an `.offset` binds as whatever integer you are holding**,
  `usize` included, rather than only the ones that coerce to `i64`.

Six more Refusals, for an insert or an update written wrong. The module is
still not an ORM and still refuses joins, aggregates and migrations
([ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)).

### Also

- **`error.AlreadyExists` is a 409.** A unique violation is the one database
  error whose meaning does not change with the request around it, so it is
  the only one given a default answer. The rest reach your handler as errors
  that read.
- **`Ctx.arena()` and `Ctx.str()`** — memory that lasts exactly one request,
  and text stamped with that request's lifetime. A module beside the
  framework needed a supported way to allocate for a request.
- **`listen()` finishes services that need the event loop.** A service
  declaring `nilo_start` is handed the loop once it exists and before the
  first connection is accepted, which is the only reason a connection pool
  can exist at all ([ADR 0040](./docs/adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).

### A third module, below the other two

nilo is now a toolkit whose largest module is a server, rather than a server
with things beside it
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md)). Which
module a file belongs in is decided by one question — does it need the event
loop? — and **a module imports downward only, never a sibling.**

Nothing you wrote changes. `nilo.Str` is the same declaration it always was.

- **`nilo_core`** holds `Str` and the Scope, needs no event loop, and can be
  imported on its own by a program that serves nothing.
- **A Scope is `arena()` and `str()`**, and nothing else. That pair was all
  `nilo_sql` ever wanted from a `Ctx`, so a query now takes either — the
  `*Ctx` a handler was given, or a **`nilo.Run`** where there is no request.
  `db.select(User, &run, .{ … })` runs in a CLI, in a scheduled tick, or in a
  test with no App in it. Handing over something that is neither is a Refusal
  naming the call.
- **`zig build test-core`** runs the bottom layer in both modes, and
  `zig test core/core.zig` runs it with no `build.zig` at all. That this works
  is the property the layering exists for, not a convenience.

### What it costs

A project that does not import `nilo_sql` links none of it — not the driver,
not TLS — and pays **560 bytes** for the startup hook. One that uses the
whole module pays **733 KB**, of which the entire write half is 53 KB and the
rest is pg.zig's TLS dependency. Allocations per request, memory per idle
connection and p99 are unchanged.

Splitting Core out cost **zero bytes**, measured on three binaries rather than
assumed.

## 0.1.0

The first release, published as **zfast**. Needs Zig 0.16.

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
  requests. A file over `max_file_bytes` is not refused but opened per request
  and sent with `sendfile`, so a directory with a video in it still starts and
  the memory figure still holds
  ([ADR 0037](./docs/adr/0037-a-file-too-big-to-hold-is-opened-not-read.md)).
- **A handler can answer with a file.** `?nilo.FileBody` serves one out of a
  directory opened on purpose, with ranges, `If-Range`, conditional requests and
  `HEAD` handled for it — and null still meaning 404. The name is checked a
  segment at a time, and the path handed to the kernel never comes from a
  request.
- **Streamed responses and server-sent events.**
- **WebSocket** — handshake, framing, masking, pings, closing handshake. A
  connection that goes quiet is asked whether it is still there and closed with
  1001 if it does not answer; a quiet WebSocket is a working one, so this is a
  ping rather than a deadline (`.idle_ms`, 30 seconds, `0` waits forever).
- **Broadcast — `nilo.Room`.** Saying something to sockets a handler does not
  hold. Provide a `Room` like any other service, `join` on the way in,
  `defer leave` on the way out, and `say` reaches everybody in it:

  ```zig
  fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
      var socket = try c.upgrade();
      try room.join(&socket);
      defer room.leave(&socket);

      var buf: [16 * 1024]u8 = undefined;
      while (try socket.receive(&buf)) |message| {
          try room.say(message.kind, message.data);
      }
  }
  ```

  That loop is the one an echo server writes. A post arriving while a
  connection is quiet is written out by *that connection's own fiber*, inside
  `receive`, so a handler never sees one — and one client that stops reading
  costs that client and nobody else. It adds **4 measured bytes per idle
  connection**, with throughput and p99 unmoved
  ([ADR 0038](./docs/adr/0038-a-broadcast-rings-a-bell-it-does-not-write.md)).
- **A generated OpenAPI document**, written from the signatures rather than from
  annotations ([ADR 0017](./docs/adr/0017-the-api-description-comes-from-the-signatures.md)).
- **Failure in nilo's own words.** Get a handler wrong and compilation stops
  with a sentence naming your route, your argument and the fix; `refusals/` is
  56 programs written wrong on purpose that keep it that way
  ([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).
- **`nilo.spawn`** for work that is not a request, owned by the server so
  shutdown counts it ([ADR 0029](./docs/adr/0029-a-spawned-fiber-belongs-to-the-server.md)).

A full `Room` backlog drops the oldest post by default, or the newest if you say
so, and `room.missed(&socket)` says how many were dropped. That amends
[ADR 0020](./docs/adr/0020-a-request-that-lasts-is-still-one-request.md), which
refused to have such a queue at all.

### What it holds itself to

One allocation per request and 8,767 bytes per idle connection, both hard
invariants held by tests rather than by intent
([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)). Measured
numbers and the method behind them are in
[`docs/benchmarks.md`](./docs/benchmarks.md), with eight other servers through
the same harness in [`docs/comparison.md`](./docs/comparison.md).

### What is not in it

- **Templates** — a refusal rather than a backlog item. nilo is for building
  APIs and services; rendering pages is not what it is for, and the reasoning is
  in [the roadmap](./docs/roadmap.md#not-coming).
- **Counters.** Requests carry an id and lines can be JSON, but how many
  requests, at what statuses, and how long is not collected anywhere.
- **TLS**, and with it HTTP/2 and a gRPC server. This is a refusal rather than a
  gap — terminate in front
  ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)).
- **A `recover` middleware.** Zig cannot recover from a panic, so there is
  nothing to build ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)).
- **Compressing a handler's response**, `permessage-deflate`, and streamed
  multipart. Static files under the spill threshold *are* compressed, once, at
  startup; one above it is sent as it lies on disk.

`zfast` was a working name, and it changed in 0.2.0.
