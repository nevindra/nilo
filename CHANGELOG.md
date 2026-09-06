# Changelog

What changed between one tag and the next, not what changed between commits.
What was measured and what was got wrong on the way is in
[`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.2.0 does. Each entry says what you have to change; the
account of why is in the ADR it links.

### New

- **`nilo_jwt`, the tenth module: checking somebody else's signed token**
  ([ADR 0140](./docs/adr/0140-nilo-verifies-a-token-and-does-not-fetch-one.md)).
  A tool module — it imports nothing, needs no event loop, and
  `zig test jwt/jwt.zig` runs the whole of it. `jwt.parseKeys(gpa, jwks_bytes)`
  reads a JWKS document; `jwt.verify(Claims, gpa, token, .{ … })` checks an
  RS256 signature and reads the payload into a struct of your own. The three
  things easiest to get wrong are not options: the algorithm is nilo's constant
  rather than the token's `alg`, so `{"alg":"none"}` and an HMAC signed with
  your published modulus are both refused; nothing in the payload is read until
  the signature has passed; and `exp` is required. **Fetching the key set is
  still yours** — it is an HTTPS GET, which `nilo_fetch` already sends, and
  holding it is `nilo_cache`. Nothing to change: nothing imports it unless you
  do, and a program that does not link no RSA.

- **`nilo_cache`, the ninth module: an expiring cache in this process**
  ([ADR 0138](./docs/adr/0138-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md),
  [ADR 0139](./docs/adr/0139-an-in-process-cache-and-a-redis-client-are-two-modules.md)).
  A tool module — it imports nothing, needs no event loop, and a program that
  is not a server can take it on its own. `cache.Space("cart", Cart, .{ .ttl_s
  = 300 })` is a keyspace as a type; the value type decides whether `get` hands
  back a value or fills an array you declared, and a value with a pointer in it
  is a compile error naming the field. One number is the whole memory budget
  and it is a ceiling: nothing is allocated after `open` and nothing grows.
  Nothing to change — nothing imports it unless you do.

### Read this before deploying

- **`cors.Options.origin` is now `origins` and takes a list.** Nothing to do if
  you never called `cors.with` — `cors.permissive` is unchanged.
- **`db.raw` and `tx.raw` take a `comptime` statement.** Text assembled at run
  time cannot be passed any more, and there is no replacement call. What you
  get for it: the `SELECT` list is counted against the Row's fields while
  compiling, each column that plainly has a name is checked against the field
  in its position, and the statement is kept prepared like every other one —
  worth about 12 µs a query. A statement built at run time becomes a `switch`
  over the orderings the application actually supports, which is also the shape
  that stops an injection nobody meant to allow
  ([ADR 0148](./docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
  `db.exec` is unchanged and still takes its text at run time.
- **A Wire of your own takes one more argument.** `run` and `exec`, on the Wire
  and on its `Tx`, end in `problem: ?*?sql.Problem`. Pass `null` from a caller
  that does not want the text, and fill it from a driver that has some
  ([ADR 0146](./docs/adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
  Nothing to do unless you wrote a Wire.
- **A WebSocket served to a page on another host now needs `.origins` naming
  that page**, or the handshake is a 403.
- **Sessions expire now.** Everybody holding one signs in again on the deploy
  that picks this up, and a session cookie with no `max_age` lasts a day rather
  than forever.
- **A slow upload can be refused.** A body nilo buffers has to arrive at
  8 KiB/s once ten seconds of grace have gone, or the request is a 408 — which
  will also refuse an honest client on a bad link. `body_min_rate = 0` turns it
  off.
- **Four request shapes that used to be answered are now refused**: no `Host`
  or two of them, a `Transfer-Encoding` not ending in `chunked`, a body framed
  twice, and a body under a `Content-Encoding` nilo cannot read. Nothing a
  browser, a proxy or an HTTP library sends changes.
- **If you serve WebSockets, take this one for the shutdown fix alone** — a
  server that had served any usually did not come back from a SIGTERM.
- **`db.nilo_start(io)` is now `db.nilo_start(io, limits)`.** Only a program
  that starts a `Db` itself — a CLI, a migration, a test — writes that line at
  all; pass `.off`, which is what `nilo_fetch` and `nilo_s3` already take.
  `app.listen()` is unchanged and passes the Engine's.

Three more answers change with nothing for you to do: a client sending
`Expect: 100-continue` now gets one and stops waiting out its own timer, an
`If-Range` carrying a weak tag or a `*` gets the whole file rather than a range,
and a handler setting a header value with a control byte in it gets a 500 rather
than a split response. All three are under Fixed.

### Added

#### Serving

- **`app.named("addPartnerCapability")`** — a route says its own
  `operationId` instead of taking the one derived from the method and the
  path. The derived name is a good default and a poor key: it is not a word
  anybody chose, and it changes when the route moves path, which is wrong for
  anything written against it — a generated client's method names, or a
  default-deny authorisation table with one entry per operation. It composes
  with groups and with `with`, a name that is not a word a generator can use
  is refused while compiling, and two routes sharing one stop the process at
  registration
  ([ADR 0149](./docs/adr/0149-a-route-can-say-its-own-name.md)).
- **A path param can be a type that parses itself.** Give a type
  `pub fn nilo_parse(text: []const u8) ?Self` and it becomes a path param like
  a number or an enum: `fn show(id: sql.Uuid) !?User` is a route, a malformed
  id is a 400 before the handler runs, and the generated document says
  `{"type":"string","format":"uuid"}` rather than a bare string. `nilo_id`'s
  `Uuid` carries the declaration, so `sql.Uuid` works with nothing to do on
  your side. Null means "not one of these" and nothing else. A `nilo_parse` of
  the wrong shape is a compile error naming the shape it must have
  ([ADR 0142](./docs/adr/0142-a-path-param-can-parse-itself.md)).

- **`nilo.deadline(ms)`** — how long a route gets, clamping every wait nilo owns
  (the body, the write, a stream's pieces, a WebSocket's silence) to whichever
  comes first. A running handler is **not** interrupted; it asks `c.overdue()`
  or `c.timeLeftMs()` itself. Failing while overdue with nothing sent is a 503
  naming the budget; finishing late still answers, and is a log line
  ([ADR 0133](./docs/adr/0133-a-route-can-say-how-long-it-has.md)).
- **`allowance.with(.{ .per_window = 100, .window_s = 60 })`** — the
  hundred-and-first request from one address inside the minute is a 429 with a
  `Retry-After`, and the handler never runs. The window slides; the table is
  sized while compiling and lives in `.bss` (131,072 bytes at the default
  `.slots = 16 * 1024`, nothing in a program that does not use it); an IPv6
  client is a `/64`. **Behind a proxy set `.trusted_hops`**, or every request
  looks like it came from the proxy. Read it as a shaper rather than a
  guarantee — a flood is still `max_connections`
  ([ADR 0114](./docs/adr/0114-an-allowance-is-a-table-sized-while-compiling.md)).
- **`allowance.keyed(f, .{ .per_window = 1000, .on_null = .reject })`** — the
  same table keyed on what the application knows, because an address gave ten
  accounts behind one office NAT a single allowance. The key's bytes are not
  kept, only a 64-bit tag; `on_null` has no default, and `.reject` answers 403
  rather than 429. `per_window` goes to 65,535 here
  ([ADR 0131](./docs/adr/0131-a-key-the-application-knows-is-a-word-of-its-own.md)).
- **`app.metrics(.{})`** — counters, which nilo has never had: a Prometheus page
  on `/metrics` with requests per route, status class, duration and how many are
  in flight. **Counted per route, not per path**, so a crawler cannot make you a
  million series and a counted request still allocates nothing.
  `app.expose("orders_placed", .counter, &orders_placed)` puts a counter of your
  own on the page. Throughput cost is inside the noise; the binary pays 17,416
  bytes if you call it. [Metrics](./docs/guide/metrics.md),
  [ADR 0100](./docs/adr/0100-the-route-table-is-the-registry.md).
- **`app.spawn(f, args)`** — a ticker or a batching exporter registered before
  `listen()` and started once there is a server, owned by it exactly as a
  connection is. `nilo.spawn` needs a running server, so this work used to be
  reachable only from inside a handler
  ([ADR 0086](./docs/adr/0086-work-that-is-not-a-request-belongs-to-the-server.md)).
- **`.address = "unix:/run/nilo.sock"`** — a path instead of a port, so the
  proxy in front no longer reaches the server over loopback TCP and "who may
  connect" is "who may write to this directory". `port` is not read, a stale
  socket is removed before binding, this server removes its own, and `c.peer()`
  is empty
  ([ADR 0130](./docs/adr/0130-a-path-is-an-address-to-listen-on.md)).
- **`.trusted_proxies = &.{"private"}`** — which machine is in front rather than
  how many hops, so adding a CDN does not leave `.trusted_hops` one short and
  `clientIp()` quietly wrong. Each entry is a CIDR, a bare address, `"private"`
  or `"loopback"`; the header is not read unless the connection came from one.
  `.trusted_hops` still means what it meant, and the description wins when both
  are set
  ([ADR 0129](./docs/adr/0129-a-proxy-is-trusted-by-which-one-it-is.md)).
- **`listen(.{ .arena_keep = 1 << 20 })`** — a response larger than the arena
  keeps was a page fault per 4 KiB, every request: 257 of them on a route
  answering a megabyte, and 7,908 req/s where setting this gives 11,069. **The
  default is unchanged at 16 KiB** because the memory is held per connection
  ([ADR 0096](./docs/adr/0096-a-response-larger-than-the-arena-keep-is-a-page-fault-per-page.md)).
- **`body_min_rate` and `body_grace_ms`** — the admission policy above, on
  `c.body()` and the `Form`, JSON and `Bound` handlers over it. A megabyte gets
  138 seconds at the defaults. `c.bodyStream()` and a WebSocket are untouched
  ([ADR 0124](./docs/adr/0124-a-buffered-body-arrives-at-a-rate.md)).
- **`app.with(mw)`** — a middleware on one route, the other direction of
  `without` and the same shape: it hands back a group. It runs innermost and is
  matched on the pattern **and the method**, so a `DELETE` guard does not cover
  the `GET` beside it
  ([ADR 0126](./docs/adr/0126-a-route-can-say-what-covers-it.md)).

#### Reading a request

- **`c.queries()`, `c.queryString()`, `c.host()`, `c.scheme()`** — every
  parameter in arrival order (a name sent twice, or `?filter[status]=open`,
  needed an underscore field before), the bytes still encoded for a signature,
  and what a handler writes a URL to its own service with. `X-Forwarded-Proto`
  and `-Host` are read only behind `.trusted_hops`, on the terms
  `X-Forwarded-For` already is, and a forwarded host that is not host-shaped is
  dropped rather than put in a link somebody clicks
  ([ADR 0112](./docs/adr/0112-a-request-can-be-read-past-the-parts-a-handler-names.md)).
- **`c.headers()`** — every header a request sent, name and value both `Str`,
  for a middleware that does not know the names in advance. A wrapper over the
  walk `header` already does: nothing built, nothing allocated
  ([ADR 0107](./docs/adr/0107-every-header-without-handing-out-the-head.md)).
- **`nilo.accept.asks(c.header("Accept"), "text/html")`** — `.named`,
  `.anything`, `.unsaid` or `.refused`, because a client that sent no `Accept`
  has neither asked for HTML nor ruled it out. Quality values are read; nothing
  is allocated or collected
  ([ADR 0109](./docs/adr/0109-a-fallback-answers-a-navigation-not-a-missing-asset.md)).
- **A `union(enum)` can be a request body**, which used to be a compile error on
  the grounds that nothing in the type said which arm arrived. `nilo_json`'s
  `.tag` is the type saying it.

#### Responses and files

- **`nilo_json` — a type can say how its JSON is spelled.** `std.json` writes a
  union one way and most REST APIs use the other; this needed a hand-written
  `jsonStringify` and `jsonParse` per type
  ([ADR 0085](./docs/adr/0085-a-type-says-how-its-json-is-spelled.md)):

  ```zig
  const Condition = union(enum) {
      pub const nilo_json = .{ .tag = "signal", .rename_all = .lowercase };
      pub const jsonParse = nilo.jsonParseFor(@This());   // only if it arrives

      metrics: MetricCondition,
      logs: LogCondition,
  };
  ```

  `.tag` is the discriminator's key; `.rename_all` spells a variant or an enum
  tag the way the wire wants it (`.lowercase`, `.UPPERCASE`, `.camelCase`,
  `.PascalCase`, `.SCREAMING_SNAKE_CASE`, `.@"kebab-case"`) and does not touch
  field names. Sending needs no `jsonParse` line — nilo makes that call itself.
- **`Upload.saveTo(dir, name)`** — the four lines of `std.fs` every upload
  handler ended in, without blocking the executor thread and without resolving
  `../../etc/cron.d/anything` out of `u.filename`. The bytes go to a temporary
  name and one rename puts them in place, so a request reading that name
  mid-write gets the old file rather than a truncated one; `nilo.Dir` gained
  `writeFileAtomic` under it
  ([ADR 0123](./docs/adr/0123-a-file-is-written-by-the-engine.md)).
- **`c.streamWith(…, .{ .length = n })`** — bytes out of something that had
  already counted them went with no `Content-Length`, so a browser showed no
  progress and a `Range` could not be answered. With a length the pieces go out
  unframed and HTTP/1.0 gets keep-alive back. Writing past the promise is
  refused before a byte of the overrun goes out; finishing short closes the
  connection and logs both numbers
  ([ADR 0128](./docs/adr/0128-a-stream-that-knows-its-length-says-so.md)).
- **`c.url(pattern, args)` and `app.routes()`** — the pattern is the name, so
  there is no route name to keep in step with it. A missing param, a spare
  value, a value a path segment cannot carry and a `*` catch-all are compile
  errors naming the field, and every value is percent-encoded so a form value
  cannot pick the route. `url.into(buf, …)` is the same call with no allocation
  ([ADR 0127](./docs/adr/0127-a-route-pattern-is-the-name-of-its-url.md)).
- **`staticWith(.{ .reload = true })`** — every file left on disk and opened per
  request, so editing one under a running server works. It is the spill
  threshold set to zero and nothing else; a file that did not exist at startup
  still needs a restart
  ([ADR 0125](./docs/adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)).
- **`cors.reading(&origins, .{ … })`** — the same middleware reading its list
  from a variable you fill before `listen()`, because the front end's address is
  a fact about the deployment: `origins.setSplit(&buf, settings.web_origins)`
  and one binary serves staging and production. The list is borrowed rather than
  copied, so **a cross-origin response still allocates nothing**; `"*"` is
  refused outright, and `cors.with` is untouched
  ([ADR 0110](./docs/adr/0110-an-origin-is-a-fact-about-the-deployment.md)).

#### `nilo_sql`

- **`db.watching(f)` — the statements a request sent.** One line per request
  says a page is slow; nothing said what was slow in it, in Debug or otherwise.
  `f` is called with a `sql.Sent` after every statement: the text, the plan
  name it is kept prepared under, how long the database took, how many rows
  moved, and whether it failed. `sql.logging` is a ready-made one that writes a
  debug line, so `db.watching(sql.logging)` is the whole of the common case
  ([ADR 0137](./docs/adr/0137-a-statement-can-be-watched.md)).

  **Not the values it bound**, which are as often a password as an id — that is
  the decision rather than the first version, and a log is read by more people
  than a response is. A `Db` nobody watches pays one null test per statement;
  a watched one pays two clock reads at 15ns.

- **`nilo.monotonicMicros()`** — microseconds since an arbitrary point, for
  measuring how long something took. `nowMicros` is the wall clock and is
  allowed to step; the reference had been telling people to use a
  `monotonicNanos` that was never public.

#### `nilo_s3`

- **`bucket.presignPost(c, key, .{ .seconds = 900 })` gives a browser a form it
  posts straight to the bucket.** `presign` hands out a link to fetch; this hands out
  `url`, `fields` and `expires_at`, so a receipt or an attachment never passes
  through your server. `.content_type` pins what the browser may send,
  `.prefix = true` lets it pick the filename, and `.max_bytes` is **clamped to
  the bucket's `max_bytes` and defaults to it**. A form with no ceiling is not
  something this call hands out, and an object over `max_bytes` is one `get`
  refuses for the rest of its life. Life is clamped the three ways `presign`'s
  is, and `expires_at` is the true number
  ([ADR 0141](./docs/adr/0141-a-browser-uploads-with-a-form-rather-than-a-link.md)).

  It is in nilo because the alternative is writing SigV4 twice: the policy is
  signed with the key derived once a day
  ([ADR 0069](./docs/adr/0069-a-signing-key-changes-once-a-day.md)), and two
  implementations of that disagree at 00:00 UTC. Nothing to change; it touches
  no socket, and a program that does not call it links none of it.

#### Testing

- **`testing.Conversation`** — a WebSocket route driven through the public API,
  where a handler that upgrades leaves `testing.Client` nothing to read.
  `text`, `binary`, `ping`, `pong`, `close`, `fragments` and `raw` are what you
  send; `at(n)`, `first(kind)` and `closedWith()` are what came back, decoded by
  a reader sharing no code with the encoder it checks. The frames are queued
  before the server runs, so a test cannot answer what the server just said, and
  a `Room` broadcast needs two connections and is out of reach
  ([ADR 0113](./docs/adr/0113-a-websocket-route-can-be-driven-from-a-test.md)).
- **`testing.Client` can be a client.** `setHeader` applies to every request
  from then on, `sendRequest` takes a method, headers, a content type and a
  body, and `Client.init(gpa, .{ .cookies = true })` keeps what the answers set
  and sends it back — so a sign-in followed by a request *as* that user is two
  calls. **The jar is off by default** so an existing suite keeps asserting what
  it asserted; `send(&app, raw)` applies neither
  ([ADR 0108](./docs/adr/0108-the-test-client-can-do-what-a-client-does.md)).

#### Smaller

- **Twelve refusals** covering the ways of writing the `nilo_json` marker wrong,
  taking the framework's table from 63 to 75 and the five tables from 129 to
  141. The one worth knowing is a `.tag` whose name a variant already uses as a
  field: the only mistake here that corrupts the wire rather than failing.
- **[Work that is not a request](./docs/guide/background.md)** in the guide, and
  a ninth example — `zig build run-scheduled`.
- **The WebSocket has been run against Autobahn**: **294 OK, 4 NON-STRICT, 0
  FAILED** of 301 cases. Nothing in the framework changed; the framing rules
  have now been seen by something that did not write them.
  `bash bench/autobahn/run.sh`, [`bench/result/http.md`](./bench/result/http.md).
- **What a held-open stream costs, measured**: 21,058 bytes against 4,674 for an
  idle connection, plus your handler's stack byte for byte. The
  [streaming guide](./docs/guide/streaming.md) carries the number instead of a
  warning that it was unmeasured.

### Changed

- **`cors.Options.origin` is now `origins`, and takes a list** — the one
  breaking change, because a single compile-time string meant an application
  with a production front end and a staging one could not use the middleware at
  all. `Access-Control-Allow-Origin` carries one value, so the request's
  `Origin` is compared against the list and the match is what goes out
  ([ADR 0099](./docs/adr/0099-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)).
  The compare is unrolled while compiling and allocates nothing.

  ```zig
  try app.use(nilo.cors.with(.{
      .origins = &.{ "https://app.example.com", "https://staging.example.com" },
      .credentials = true,
  }));
  ```

  **Two things behave differently for a named origin**: it goes out only to a
  request whose `Origin` matched, where the single string went out on every
  response, and an origin you did not name gets an ordinary response with no
  allow header — the browser's refusal to make rather than the server's. `Vary:
  Origin` goes out either way. Three refusals come with it: an empty list, `*`
  beside a name it already covers, and an origin with a capital letter, which a
  browser lowercases before sending and so could never have matched.

- **A WebSocket handshake is same-origin unless the route says otherwise.** A
  browser applies no CORS to a WebSocket — no preflight, and it ignores
  `Access-Control-Allow-Origin` — so `cors.with` in front of an upgrade route
  set headers nobody enforced and the socket opened anyway, **carrying the
  session cookie**. An application with `Session(T)` and `c.upgrade` on the same
  server was open to any page on any origin. A handshake whose `Origin` does not
  name the authority its `Host` named is now a 403; a request with no `Origin`
  at all — curl, wstest, a native client — is unaffected, because the ambient
  cookie this guards is a browser's. Say
  `c.upgradeWith(chatLoop, room, .{ .origins = &.{"https://app.example.com"} })`
  for a page on another host, or `&.{"*"}` for a public socket. One compare on
  the handshake, nothing per message
  ([ADR 0102](./docs/adr/0102-a-websocket-handshake-is-same-origin-unless-the-route-says-otherwise.md)).

- **The blocking detector measures one unparked stretch rather than a total, and
  nothing is excused any more.** The old sum over a whole request had no upper
  bound on a connection that stays open, so streams, body readers and WebSockets
  were exempt — and a blocking call inside a WebSocket loop, where a stalled
  fiber holds its executor against every other socket, was never reported. Two
  things read differently: a handler that yields between short stretches is no
  longer reported, and a handler that blocks twice is now reported twice
  ([ADR 0132](./docs/adr/0132-what-is-watched-is-one-unparked-stretch.md)).

- **A request body under a `Content-Encoding` other than `identity` is a 415.**
  nilo decodes none of them, so a gzip stream reached `c.json` and came back as
  a 400 about a malformed body — true of the bytes and useless to the sender.
  The header on a request with no body is still ignored
  ([ADR 0111](./docs/adr/0111-a-body-under-an-encoding-nilo-cannot-read-is-refused.md)).

- **An HTTP/1.1 request with no `Host`, or with two, is a 400**, as RFC 9112
  §3.2 requires and as the front end nilo assumes is there already does. A
  repeat is refused even when the two agree. HTTP/1.0 is unaffected
  ([ADR 0101](./docs/adr/0101-a-request-nobody-else-would-answer-is-refused.md)).

- **A `Transfer-Encoding` whose last coding is not `chunked` is a 400.** It used
  to be served as a request with **no body at all**, leaving the bytes the
  client sent in the read buffer for the next turn of the connection loop to
  parse as a second request. `Transfer-Encoding: chunked` is unchanged.

- **A number in a path param, a query value or a form field is no longer read as
  a Zig literal.** `/users/+7` was user 7, `?page=1_0` was page ten, and
  `?ratio=nan` was an `f64` that loses every comparison it is in; all four are a
  400. A leading `-` on a signed field, a leading zero and an exponent's sign
  are still accepted
  ([ADR 0106](./docs/adr/0106-a-number-in-a-request-is-not-a-zig-literal.md)).

- **A single-page fallback answers a navigation rather than every path under its
  prefix.** It used to answer 200 with the page for anything that named no file,
  so a build whose hash had moved on handed a browser HTML where it asked for
  `app.abc123.js` — a syntax error on line 1, with the missing file named
  nowhere. A request naming `text/html`, or saying nothing and carrying no
  extension in its last segment, still gets the page; everything else gets a 404
  saying which path, and `.spa_fallback_for = .any_path` restores what shipped
  ([ADR 0109](./docs/adr/0109-a-fallback-answers-a-navigation-not-a-missing-asset.md)).
  **A second ordering change comes with it**: every directory is asked for the
  file before any directory is asked for its fallback, so an app mounted at `/`
  no longer answers `/assets/app.css` from its own `index.html`.

- **`c.body()` no longer commits the announced `Content-Length` before reading a
  byte of it.** A client that promised a megabyte and sent one byte a minute
  held 1,852,080 bytes of anonymous mapping per stuck connection, now 316,080.
  A body that arrives is the same one allocation it always was
  ([ADR 0105](./docs/adr/0105-a-body-is-taken-as-it-arrives.md)).

- **`Db.nilo_start` takes the Engine's `Limits` beside the loop**, because a
  Wire cannot bound a wait on its own — `std.Io.Condition` has no timed wait,
  and what stops a parked fiber is the Engine's timer reaching it
  ([ADR 0135](./docs/adr/0135-a-wait-for-a-connection-has-a-bound.md)). It is
  the signature `nilo_fetch` and `nilo_s3` already have. `app.listen()` and
  `app.start(io)` are unchanged; a program that starts a `Db` by hand writes
  `db.nilo_start(io, .off)`. A Wire of your own gains `width(rows)` and a
  `limits` field on `OpenOpts`, both listed at the top of `sql/wire.zig`.

- **A Dialect owes `json_form` and `enum_form` beside `uuid_form`.** Nothing to
  do unless you wrote a Dialect of your own; `assertDialect` names the missing
  declaration. Both answer `.native` or `.text`
  ([ADR 0119](./docs/adr/0119-the-sqlite-write-path-is-compiled.md)).

- **The generated API description follows whichever encoding the type asked
  for**, so a client generated from it reads what the server sends: a tagged
  union is `oneOf` with `discriminator`, an untagged one is still `{}`.

### Fixed

#### Serving

- **`/users/{id}` in a route pattern was five literal characters** and nothing
  said so. `{}` is what OpenAPI writes, what nilo's own document prints, and
  what every framework a porter is arriving from spells, so a path copied out
  of an existing document registered a route that answered nothing. On a route
  whose handler asked for the param it was already a compile error; on one that
  did not, the only symptom was a 404 on a URL the document promised. It is now
  refused while compiling, naming `:name`
  ([ADR 0147](./docs/adr/0147-a-pattern-written-the-way-the-document-prints-it.md)).
- **The refusal for a handler taking two structs by value sent you to
  `app.provide`** even when the argument was meant to be a path parameter. It
  now names the third possibility when the route has a path-param slot nothing
  has claimed.
- **A handler holding a `*Ctx` and returning nothing was described as writing
  its own response, and nilo does not know that.** It may have written one, or
  it may have taken the Ctx to read a header and left nilo to send 200 with an
  empty body. The document and the `listen()` line now say what is true — the
  signature does not settle what the route answers — and both name the way out,
  which is returning `Status(200, void)` and has always been there. No
  behaviour changed
  ([ADR 0150](./docs/adr/0150-a-ctx-handler-that-returns-nothing-may-have-written-it.md)).

- **A server that had served WebSockets usually did not come back from a
  SIGTERM** — the process never exited and one executor thread spun at 100%, so
  a deploy got a container that would not stop. The Engine's `Wake` handed two
  completions to the event loop every time a connection parked and never took
  them back, so the loop was left writing into a frame that had been handed on.
  `python3 bench/shutdown.py` at 24 connections: **23 of 25 SIGTERMs hung
  before, 0 of 25 after**. Nothing per connection, nothing on any message path
  ([ADR 0098](./docs/adr/0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md)).
- **A connection cancelled while leaving a `Room` kept its seat and its bell**,
  so a later broadcast pushed into the ring of a handler that had ended and rang
  a waker pointing into its `Socket` — narrow, and a use-after-free. Both locks
  on that path are uninterruptible now, and `nilo.Mutex.lockUncancelable` is
  what a Service with its own cleanup path should reach for
  ([ADR 0104](./docs/adr/0104-a-cleanup-path-is-not-cancellable.md)).
- **`socket.print` and `socket.json` could put a length on the wire their bytes
  did not match.** Both format twice, and a frame whose length is wrong by one
  leaves the reader at the wrong offset for the life of the connection. The two
  passes are held to each other; a disagreement closes with 1011 and returns
  `error.WriteFailed` rather than sending, usually before the frame leaves the
  buffer. A subtraction and a compare per call; `send` is untouched
  ([ADR 0097](./docs/adr/0097-a-frame-that-lies-about-its-length-is-not-sent.md)).
- **`Expect: 100-continue` was never answered, so curl waited out its one-second
  fallback timer before every upload.** nilo answers at the moment it commits to
  reading the body, and **a request refused before that line gets its final
  status with the body never sent** — a rejected 20 MB upload now costs the
  bytes of the 413. Nothing interim goes to HTTP/1.0 or where `Content-Length:
  0` says nothing is held back; no other expectation is read
  ([ADR 0094](./docs/adr/0094-a-header-is-answered-as-asked-or-refused.md)).
- **`GET http://example.com/users/7 HTTP/1.1` was a 404 on a route that plainly
  exists** — the whole target went to the router as a path. RFC 9112 §3.2.2 says
  a server must accept that form, and a client that believes it is talking to a
  proxy sends it. The authority is taken off and the path routed; `c.host()`
  answers from the target, and such a request needs no `Host` header. Two shapes
  become a 400 rather than a 404: userinfo (`http://a@b/`), and no path with a
  query (`http://example.com?a=1`). One byte compare on the request path
  ([ADR 0120](./docs/adr/0120-a-target-is-read-in-the-form-it-arrived-in.md)).
- **A request whose body was framed twice was read rather than refused** — four
  ways a `Content-Length` could disagree with the proxy in front, all now a 400:
  a value that is not plain digits (`+5`, `1_0`, `-0`), a repeat with a
  different value, `Content-Length` beside `Transfer-Encoding: chunked` in
  either order, and a second `Transfer-Encoding` after chunked. `chunked` is
  read as the last coding rather than as a substring, so `xchunked` no longer
  counts
  ([ADR 0090](./docs/adr/0090-a-body-framed-twice-is-refused.md)).
- **A response header value was never checked, so a handler could split its own
  response**: there is no escaping in `name: value\r\n`, so a value carrying a
  newline makes a *second* header, and two of them end the head and start a
  second response. Every path that sets one now goes through one check — the
  name a token, the value free of control bytes — and a refusal is a 500 naming
  the header and the rule, where the reserved-header refusal used to reach the
  client as `"internal server error"`. `error.ReservedHeader` is gone; the value
  is never quoted back
  ([ADR 0087](./docs/adr/0087-a-header-value-cannot-end-its-own-line.md)).
- **A session never expired, whatever `max_age` said.** The only bound was
  `Max-Age` on the cookie, which is an instruction to a *browser*, so a copy out
  of a proxy log went on opening forever unless you rotated the secret and
  signed everybody out. The seal now carries the moment it stops opening, under
  the AEAD tag. Leaving `max_age` null is still a session cookie and now seals
  `nilo.session.default_max_age` — **24 hours**. The plaintext layout moved, so
  every session out there is ignored; `session.openAt(T, cookie, key, when)` is
  public for a test. One 15ns clock read on a request that carries a session,
  and 12 bytes on the wire
  ([ADR 0088](./docs/adr/0088-an-expiry-a-client-can-ignore-is-not-one.md)).
- **A `without` exemption freed a route from a middleware on every method at
  that path**, so `.without(requireSession).post("/sign-up", …)` silently freed
  the `GET` beside it. Exemptions are matched on the method as well as the
  pattern now; `with` was written against the same record and would have had the
  identical bug.
- **Two ceilings were reached in silence**, both
  [ADR 0081](./docs/adr/0081-a-ceiling-that-is-reached-is-said-out-loud.md)
  applied where it had not been: a multipart form over `form.max_parts` (256) is
  a 400 naming the ceiling rather than reading the first 256 and walking past
  the rest, and a `422` from `Bound(T)` that runs out of `fail.max_message` ends
  with `; and N more` instead of stopping mid-word.
- **A checkbox did not bind to a `bool`.** A ticked HTML checkbox posts `on`, so
  `newsletter: bool = false` inside a `Form(T)` was a 400 the first time
  somebody ticked the box while the unticked half worked. A form reads `on` now,
  and anything else says `"newsletter" has to be true, false or on, not
  "maybe"`. **Only a form** — `Query(T)` and a JSON body still take `true` and
  `false` alone, and `off` is accepted nowhere. 0 bytes of binary
  ([ADR 0092](./docs/adr/0092-a-checkbox-is-a-bool-in-a-form-and-nowhere-else.md)).

#### Static files

- **A spilled static file that grew on disk served a stale length under a stale
  ETag** — the walk recorded size, mtime and ETag while the bytes were opened
  per request, so a complete, correct-looking response carried a prefix, and a
  client holding the old ETag was answered 304 forever. The head is written from
  one look at the descriptor whose bytes are going out. The Bulkhead's
  `File.size` became `File.stat`, which matters only if you wrote an Engine
  ([ADR 0125](./docs/adr/0125-a-file-is-described-by-the-descriptor-being-sent.md)).
- **`If-Range` accepted a weak validator**, which is the one comparison RFC 9110
  §13.1.5 says must be strong — a resumed download staples the bytes it gets
  onto a prefix it already holds. It uses `etagMatchesStrong` now: no `W/`, no
  `*`, one tag. `If-None-Match` is unchanged. Reachable only from a client that
  wraps a tag it was given in `W/`, so latent rather than live, and the failure
  mode is a corrupt file.
- **A gzipped static file behind a named-origin CORS lost its `Vary: Origin`**,
  because `setHeader` replaced and the CORS middleware runs before the static
  handler names its own axis of the same response. `Vary` repeats rather than
  replaces now — two lines rather than one joined value, since joining would put
  an allocation on the static path — and an exact duplicate is still dropped
  ([ADR 0089](./docs/adr/0089-two-layers-can-each-name-a-vary-axis.md)).
  `inline_headers` went from six to seven with it, measured; an idle connection
  is unchanged.
- **A multipart part naming its file only with `filename*` was read as a text
  field**, holding the raw upload bytes while the `Upload` the endpoint asked
  for was reported missing — so the 400 named the wrong thing. It is a 400
  naming the part now. nilo still does not read RFC 6266's encoding; browsers
  send both and are unaffected.

#### Types, JSON and compile errors

- **A `[]const u8` holding a byte that is not text went out as a JSON string**,
  so `{"name":"\xff"}` was unparseable by whoever asked for it. nilo writes
  `{"name":[255]}` as `std.json` does — the last place this module's stated
  contract was untrue
  ([ADR 0121](./docs/adr/0121-a-byte-that-is-not-text-is-not-a-string.md)).
- **A `[:0]const u8` went out as an array of byte values while `openapi.json`
  promised a string**, and was labelled `application/json` where a `[]const u8`
  is `text/plain`. Three files asked whether a type is a run of bytes and one
  got it right; there is one predicate now
  ([ADR 0103](./docs/adr/0103-one-file-decides-what-counts-as-text.md)).
- **A type holding a list of its own type could not reach a response at all** —
  the walk deciding which writer to use recursed with no floor, so it failed to
  *compile*, advising you to raise the branch quota. It stops at eight now, the
  ceiling the schema walker has.
- **Responses carrying a union were two to three times slower than they had to
  be**: `covers` did not recognise a `union(enum)`, so one union field anywhere
  sent the whole response to `std.json`, every string included. **2.8× to 3.2×**
  on a 374-byte payload, 3.4× to 3.5× on a 104-byte one. The bytes are unchanged
  ([`bench/result/http.md`](./bench/result/http.md)).
- **A `rename_all` that put two names on one was accepted silently** —
  `not_found` and `notfound` both sent `"notfound"`, and a reader took whichever
  variant declaration order reached first, so reordering two variants quietly
  changed which one a request parsed into. It is a compile error naming both
  names now
  ([ADR 0093](./docs/adr/0093-two-renamed-names-that-collide-are-refused.md)).
- **A nilo compile error could rename your own type into one of nilo's.** An app
  with `src/room.zig` holding a `pub const Room` was told its type was
  `nilo.Room` and sent looking for something it never imported, because the name
  table matched on a file name. nilo's types say their own name with a
  `pub const nilo_type_name` now, which yours cannot accidentally have —
  `session`, `room`, `body`, `stream`, `form`, `cookie` and `app` are all
  ordinary file names. Nothing at run time
  ([ADR 0122](./docs/adr/0122-a-type-says-its-own-name.md)).
- **Fifteen types printed a nilo file name in nilo's own compile errors** —
  `Socket`, `Room`, `Stream`, `Session`, `Bound` and ten more, so a WebSocket
  loop with the wrong first argument was told it had a `*ctx.Ctx`. The table is
  filled in, and **what holds it is a test that walks the module's exports**
  rather than the paragraph that was supposed to
  ([ADR 0095](./docs/adr/0095-the-name-table-is-checked-against-the-exports.md)).

#### `nilo_sql`

- **`db.raw` was the one call in the module the compiler did not check**, and
  it fills the Row by position. Two columns of the same type in the wrong order
  decode cleanly and answer wrong, with no run-time symptom at all — which on a
  schema of 145 `uuid` columns is the mistake worth catching. Its text is
  `comptime` now: the `SELECT` list is counted against the Row's fields, each
  column that plainly has a name is checked against the field in its position,
  and the statement is kept prepared like every other. A `*`, and a statement
  with no `SELECT` and no `RETURNING`, are counted as "not counted" rather than
  guessed at
  ([ADR 0148](./docs/adr/0148-a-raw-statement-is-counted-while-compiling.md)).
  **It refuses rather than reordering**: binding by name would silently repair
  a statement that is wrong and the reader would never learn the two disagree.
  Types are still not checked, because a comptime pass has no schema — that
  half is `db.checking`'s.

- **A statement that failed says what the database said.**
  `error.QueryFailed` was the whole debugging surface for one, and the
  reference's "logged, never sent" was true only on the path with a database
  behind it: when the driver refused the statement before it left the process,
  nothing was logged anywhere and Postgres had never seen it. `sql.Problem`
  now carries the message, the SQLSTATE `code`, `severity`, `detail`, `hint`
  and the `constraint` that was violated, on `Sent.problem` where
  `db.watching` can reach it, and `sql.logging` prints it
  ([ADR 0146](./docs/adr/0146-a-statement-that-failed-says-what-the-database-said.md)).
  `message` is never empty — a driver refusal reports the Zig error's name,
  which is the missing word this was built for. Fields a database cannot answer
  are empty rather than null; SQLite has no SQLSTATE and does not invent one.
  It lives in the request's arena and **never reaches the client**, which
  [ADR 0025](./docs/adr/0025-every-failure-answers-with-the-same-json-body.md)
  has not changed.

- **A `sql.Uuid` could not be a parameter to `db.raw` or `db.exec`.** Every
  statement this module writes takes one; a hand-written statement sent it to
  the driver untouched, which is `error.QueryFailed` at run time on Postgres
  and a compile error from inside zqlite on SQLite. The workaround was sending
  the thirty-six characters and writing `$1::text::uuid`, at an arena
  allocation per id. Raw parameters now go through the same conversion a Row's
  do — a `Uuid`, a `Str`, a `Timestamp`, a `Json(T)`, an enum, and a literal
  or a `null` written at the call site
  ([ADR 0145](./docs/adr/0145-a-raw-parameter-is-converted-the-way-a-rows-is.md)).
  **A call where nothing needs converting hands your own tuple straight to the
  driver**, which is most of them. A named struct of values is left alone,
  because that is zqlite's `:name` binding and has no position to convert
  against; passing one that holds a type nilo would have converted is now a
  compile error saying to use a tuple.

- **There was no array of `Uuid`, in either direction.** `[]const sql.Uuid` is
  `uuid[]` now — read, written, and as an `.in` list, which is what stops an
  N+1 on a page that attaches children to its rows. Before, one way was Zig's
  own `cannot cast` from inside `db.zig` and the other was a `@compileError`
  from inside pg.zig; neither named a nilo concept. A Row with a `uuid[]`
  column also **passed the startup check without anything having looked at the
  column**, because the Dialect had no case for the type and an unknown answer
  reads as *accept anything* (ADR 0145).

- **`db.checking` did nothing on default options, and said nothing about it.**
  `connect_on_init` is 0 by default, so a `Db` written `.{}` reached the schema
  check with an empty pool, the check answered `Disconnected`, and the server
  started behind a warning that read like a database being down. The point of
  checking at boot is that a Row disagreeing with its table stops a deploy; on
  defaults it stopped nothing and the deploy was green. A `Db` that has a check
  to run now dials one connection for it
  ([ADR 0144](./docs/adr/0144-a-check-dials-the-connection-it-needs.md)).
  **What does not change is that a database which is merely down still lets the
  server start**: a dial that fails falls back to the pool you asked for and
  says in one line that the check is not happening. A `Db` with no check, or one
  that set `connect_on_init` itself, is untouched.

- **`db.insertOrIgnore` demanded a key from a table that has none.** A pure
  join table is a composite primary key and no `id`, and it did not compile —
  "has no column `id`, so its nilo_table has to say which column identifies a
  row". It was asking for a key to leave out of a `SET` clause that
  `DO NOTHING` never writes. The conflict target given at the call site is the
  only identity the statement needs
  ([ADR 0143](./docs/adr/0143-do-nothing-has-no-key-to-leave-out.md)).
  `db.insertOrUpdate` still asks for one, and still should — `SET id =
  EXCLUDED.id` is a primary key change Postgres will make quietly.

- **A `db.raw` whose `SELECT` list was shorter than its Row read past the end
  of the driver's own array.** `fill` asks for column `i` of each field and
  pg.zig's `Row.get` is `self.values[col]` with no bound on `col`, so a column
  dropped from a hand-written join was a panic in ReleaseSafe — the whole
  process, for one request — and undefined in ReleaseFast. The width of the
  result is now compared against the Row's on the first row, and a short list
  is a `QueryFailed` naming both numbers
  ([ADR 0134](./docs/adr/0134-a-select-list-shorter-than-the-row-is-refused.md)).
  A list *wider* than the Row is unchanged and still read: that is what
  `SELECT *` into a narrow Row means. One compare per statement.

- **A number written out beside a value the caller was holding did not
  compile.** `db.update(User, c, .{ .set = .{ .age = 31 }, .where = .{ .id =
  found.id } })` — the most ordinary write there is — stopped with `unable to
  resolve comptime value` naming `options`, a parameter nobody wrote. A
  literal has no type of its own, so reading it made the read of the *whole*
  options struct a comptime one, which then could not reach the runtime `id`.
  The column's type is asked for by name now, which is the coercion that was
  going to happen a line later anyway. The same applied to a `null` and to an
  enum name written out.

- **A `Timestamp` was checked against a TEXT column on SQLite and bound as an
  integer.** So `created_at INTEGER` — the column that matches what is
  actually sent — failed the startup check and stopped the server, while the
  column that passed stored microseconds as digits in a text column, where
  `ORDER BY` sorts them as text and no date function reads them. It is checked
  against `INTEGER`, `INT`, `BIGINT`, `NUMERIC`, `DATETIME` or `TIMESTAMP` now,
  all of which keep an integer an integer
  ([ADR 0136](./docs/adr/0136-a-timestamp-is-checked-against-the-column-it-is-bound-into.md)).
  **A SQLite schema whose timestamp column is `TEXT` is now refused at
  startup**, and the digits in it were already sorting wrongly; the fix is
  `INTEGER` and a migration reading them back out. Postgres is unaffected.

- **A SQLite request could wait for a connection forever, and `timeout_ms` did
  not bound it.** `sqlite.Wire.open` read `size` and dropped the rest, and
  `takeWriter` waited on a `std.Io.Condition` with no deadline — so a handler
  holding a `tx` that then sent a statement through `db` rather than `tx`
  queued for the one writer it was itself holding, with nothing in the log.
  The wait is bounded now, by the Engine's timer through `core.Limits`, and
  the message names the mistake it is most often going to be
  ([ADR 0135](./docs/adr/0135-a-wait-for-a-connection-has-a-bound.md)). The
  timer is armed only by a fiber that is actually going to queue, so a
  statement that finds its connection free pays nothing; a handler that
  reaches SQLite pays 192 bytes of stack, which is per connection
  ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md)).
  Postgres is untouched — pg.zig's pool always honoured the number.

- **`id INTEGER PRIMARY KEY` stopped a SQLite server from starting** — the
  spelling every tutorial writes was reported as a schema mismatch, and
  `schema_mismatch_is_fatal` defaults to true. SQLite reports `notnull = 0`
  there because the column is an alias for the rowid. `INT PRIMARY KEY` and a
  composite `PRIMARY KEY (a, b)` keep reporting, because SQLite really does
  accept a NULL in both
  ([ADR 0115](./docs/adr/0115-an-integer-primary-key-is-the-rowid.md)).
- **`.in` and `.not_in` did not compile against SQLite at all**, and three
  documents said they did: the failure was `cannot bind value of type
  []const i64` from inside zqlite, on the operator every real schema uses. The
  list binds as one JSON array now, at one arena allocation per condition. **A
  `sql.Json(T)` column and an enum column could not be written there either**,
  found by the same run — all three are the SQLite write path never having been
  compiled by anything on `zig build test`
  ([ADR 0119](./docs/adr/0119-the-sqlite-write-path-is-compiled.md)).
- **A `Streamed` closed twice released its pool connection twice, in ReleaseSafe
  only** — the re-entry guard was inside `if (traps_enabled)`, which is Debug.
  `rows.close()` on an early return plus the `defer rows.close()` the doc
  comment recommends is exactly two calls, so this was reachable from the shape
  the API teaches. One byte on the stack of a handler that streams
  ([ADR 0117](./docs/adr/0117-a-guard-against-double-release-is-not-a-debug-trap.md)).
- **A NULL read into a field that cannot hold one was a `0` on SQLite and an
  error on Postgres.** The null test only ran for optional fields. It is
  `error.QueryFailed` on both Wires now, with a warning naming the column; the
  startup check cannot catch this for a view, which is where it bit
  ([ADR 0118](./docs/adr/0118-a-null-is-refused-by-both-wires-or-by-neither.md)).
- **A SQLite request could stall on a free connection**, with nothing in the log
  and nothing holding it: `takeWriter` and `takeReader` waited on one
  `std.Io.Condition` while testing different predicates, so a returning reader
  could wake the fiber queued for the writer. One queue per predicate now, woken
  with `broadcast`
  ([ADR 0116](./docs/adr/0116-a-queue-per-question-not-one-condition-for-two.md)).

#### `nilo_fetch`

- **`fetch` retried a reaped connection only when the peer's close landed
  first.** If your request lands first, the kernel sends an RST rather than a
  FIN and `std.http` reports `ReadFailed`, where the retry was bounded to
  `HttpConnectionClosing` — same reaped connection, and which one you got was a
  race nobody runs. The retry bounds are otherwise unchanged: only a replayable
  body, only inside the same permit and deadline, at most one attempt per
  connection the pool could hold
  ([ADR 0091](./docs/adr/0091-a-reaped-connection-arrives-two-ways.md)).

#### Documentation

- **"About 9 KB a connection" was still quoted in six places, and the number is
  4,669** (5,183 for an idle WebSocket), with `deploying.md` carrying an older
  ~21 KB from two rounds before that. The capacity warning an operator reads now
  says `an idle connection costs 4,669 bytes, plus whatever stack the handler
  touches`, because it is a floor rather than a total
  ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md)). The
  premise had gone stale too: `deploying.md` told you to turn `read_buffer` and
  `write_buffer` down for a server holding many connections open, and since
  ADR 0071 an idle connection gives both buffers back.
- **The SQL guide's snippets are compiled now** — 37 of its 51 blocks, against
  17 marked across the eight pages before it
  ([ADR 0083](./docs/adr/0083-the-guide-is-the-source-of-its-own-snippets.md)).
  Marking them found the `db.update` bug above, two examples handing `db.raw` a
  struct that is not a Row, and a running `User` missing the two columns its
  own examples set. A page may have a prelude of its own now, a block of
  statements is given the shapes the page declared above it, and a local the
  snippet does not read is discarded for it rather than in it.
- **`Message.data`'s documented lifetime was backwards** — the type said the
  bytes were the caller's. They are borrowed from the executor's free list and
  the loan ends at the next `receive`, sooner if the connection falls quiet.
  `docs/reference.md` always had this right. Copy before you keep.
- **`Room.roster` said its lock is "not held while posting", and it is held.**
  `handOut` takes it and keeps it for the whole loop over the roll, so `join`
  and `leave` queue behind a broadcast. The field says that now, with why
  shortening the hold is not a one-line change: `leave` drains a seat under that
  lock and `takeSeat` does not drain before handing one out. The guarantee that
  matters is unchanged — a post only fills a ring and rings a bell, and the
  bytes reach the wire on the connection's own fiber, so a client that has
  stopped reading is still on nobody else's path.
- **The cookie guide now says what to do about a cookie your front end
  encoded.** Node, Gin and Fiber all percent-decode on the way in; nilo does
  not, and that is the design
  ([ADR 0030](./docs/adr/0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md)).
  What was missing is that nothing reports the difference: a page writing
  `encodeURIComponent` reads one string from JavaScript and another from Zig,
  and a comparison just fails. The guide names the symptom and the one call,
  `nilo.percent.decode(arena, raw, false)`.

## 0.2.0

**0.1.0 was an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and
that server is one of its eight modules.**

The other seven are the parts a service needs in an ordinary week: Postgres,
SQLite, object storage, calling somebody else's API, settings, password
hashing, UUIDs, and the vocabulary the rest of them share. You import the ones
you use, and Zig never compiles the rest.

Needs Zig 0.16. Install it pinned:

```
zig fetch --save git+https://github.com/nevindra/nilo?ref=v0.2.0
```

**Five things break.** [Upgrading from 0.1.0](#upgrading-from-010) is all of
them, with the fix next to each.

### The eight modules

| Module | What it is | In 0.1.0 |
|---|---|---|
| [**`nilo_http`**](#nilo_http-the-server) | the server: routing, typed handlers, middleware, sessions, static files, streaming, WebSocket, OpenAPI | this was the whole library, and it was called `zfast` |
| [**`nilo_sql`**](#nilo_sql-postgres-and-now-sqlite) | Postgres and SQLite. Your struct is the table | wrote the SQL while compiling, and could not send it |
| [**`nilo_s3`**](#nilo_s3-object-storage) | object storage: S3, MinIO, R2. Your bucket is a type | new |
| [**`nilo_fetch`**](#nilo_fetch-calling-somebody-elses-api) | calling somebody else's HTTP API from inside a request | new |
| [**`nilo_config`**](#nilo_config-settings) | settings out of the environment, every bad one named at once | new |
| [**`nilo_pw`**](#nilo_pw-passwords) | password hashing: argon2id, stored as PHC | new |
| [**`nilo_id`**](#nilo_id-uuids) | UUIDs, v4 and v7 | new |
| [**`nilo_core`**](#nilo_core-the-vocabulary) | `Str`, the Scope, the clock, percent coding | new |

Which module a file belongs in is decided by one question: does it need the
event loop? A module imports downward only, and never sideways
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md)).
That is a build step rather than a paragraph. `zig build layering` reads the
imports and refuses one that goes the wrong way.

None of the seven knows `nilo_http` exists. `nilo_sql` asks for a **Scope**,
which is `arena()` and `str()` and nothing else, so the same query runs inside
a handler, inside a CLI, or inside a test with no server in the process. Where
there is no request, hand it a **`nilo.Run`**. Handing over something that is
neither is a Refusal naming the call.

### Upgrading from 0.1.0

#### 1. Everything spelled `zfast` is spelled `nilo`

The server's module is **`nilo_http`**, not `nilo`. The bare name belongs to
the project, which is eight modules now rather than one.

| Was | Is |
|---|---|
| `@import("zfast")` | `@import("nilo_http")` |
| `zfast_table`, `zfast_resolve`, `zfast_query`, `zfast_response` | `nilo_table`, `nilo_resolve`, … |
| `.zfast` in `build.zig.zon`, `zfast_sql` | `.nilo`, `nilo_sql` |
| `nilo.module("nilo")` in your `build.zig` | `nilo.module("nilo_http")` |

The markers are the ones worth knowing about, because they sit in **your**
structs rather than behind the import line. They are also the ones that do not
move again, because they are named after the project rather than after a
module. Alias the import back and the rest of your code is unchanged:

```zig
const nilo = @import("nilo_http");
```

#### 2. `nilo_sql` has to be asked for

Add `.sql = true` to your `b.dependency("nilo", …)`. Nothing else changes.
Leave it out and importing `nilo_sql` is a compile error that says this in one
sentence.

```zig
const nilo = b.dependency("nilo", .{
    .target = target,
    .optimize = optimize,
    .sql = true,
});
```

The flag is what fetches the drivers, and it exists because the old
arrangement never worked: **every dependent was downloading 11 MB of Postgres
driver**, including ones with no database in them at all. `b.lazyDependency`
is a request rather than a conditional, and the manifest had said otherwise
for a year ([ADR 0075](./docs/adr/0075-a-lazy-dependency-is-a-request.md)).
`zig build fetch-check -Dnetwork` is the measurement, run against an empty
package cache.

#### 3. A WebSocket handler hands its loop back

`c.upgrade()` no longer returns a `Socket` for the handler to loop over. It
takes the loop as a function, answers the handshake, and returns.

```zig
// was
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    var socket = try c.upgrade();
    var buf: [4096]u8 = undefined;
    while (try socket.receive(&buf)) |m| try room.say(m.kind, m.data);
}

// now
fn chat(c: *nilo.Ctx, room: *nilo.Room) !void {
    return c.upgrade(chatLoop, room);
}

fn chatLoop(socket: *nilo.Socket, room: *nilo.Room) !void {
    while (try socket.receive()) |m| try room.say(m.kind, m.data);
}
```

Three things move at once and they are all one change. The loop is a named
function. `receive` takes no buffer, because the message arrives in one the
executor lends the socket while the message is in flight and takes back when
the conversation goes quiet. And anything the handler knows that the loop
needs is the second argument to `upgrade`, up to 128 bytes: a `Str`, a
pointer, a service, or `{}` when there is nothing. The long form is
`c.upgradeWith(loop, state, .{ .protocol = …, .idle_ms = …, .max_message = … })`.

**This is worth 16 KB per open socket, and it is why the shape changed.** A
handler that keeps the loop is a suspended fiber holding the request's whole
frame (the `Ctx`, the parsed head, the route match) plus its own receive
buffer, for as long as the tab is open. An idle WebSocket cost **21,561 bytes
and now costs 5,183**. One that had received a single 60 KiB message cost
87,101 and now costs 5,186, which is the same socket either way
([ADR 0071](./docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).

One consequence to know about: **an open WebSocket no longer counts as a
request in flight**, so a shutdown is not held for the grace period by every
idle chat tab.

#### 4. A type with its own `jsonStringify` says what it looks like

The OpenAPI generator used to describe such a type by its *fields*, so a UUID
appeared in the document as `{ bytes: [16]integer }` while the wire carried a
string. That is a document contradicting the endpoint it describes. Say what
it looks like instead:

```zig
pub const nilo_openapi = .{ .type = "string", .format = "uuid" };
```

Missing it is a compile error naming the type
([ADR 0076](./docs/adr/0076-a-type-that-writes-its-own-json-says-so.md)).
nilo's own types carry theirs.

#### 5. Removed: `nilo.websocket.Handshake`

A struct wrapping the array `accept()` already returns. Nothing had ever used
it.

### `nilo_http`: the server

#### Memory per idle connection is 4,669 bytes

Down from 8,767, for HTTP and WebSocket alike, and nothing in your code has to
change to get it. Ten thousand idle keep-alive connections is 47 MB rather
than 88 MB.

The connection's read and write buffers already went back to the kernel when
it went quiet. What was left was two pages of fiber stack, and one of them was
there only because the connection then suspended itself four kilobytes deeper
than it needed to. The idle wait now happens at the connection loop's own
frame, the request's machinery is a frame of its own that unwinds before it,
and the cold half of a request (the log lines nobody hits, which cost stack
whether or not they print) is out of line.

Throughput neither paid for it nor gained from it. Four interleaved 30-second
runs against a same-machine baseline average 1,429,293 req/s against
1,420,424, which is **+0.6% and less than the spread of either column.** Read
that row as unchanged.

**The floor is still a floor.** A handler that touches 64 KiB of stack still
holds 64 KiB per connection, one byte for one byte. An ordinary route reading
one row and answering JSON holds **17,022 bytes**; a handler that only touches
an 8 KiB stack array holds **17,932**, which is more, so the database was
never the cause. **In this framework the arena is cheaper than the stack**
([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md)).

#### A WebSocket message, once through

Receiving one used to copy every byte into your buffer and then walk the same
bytes again to unmask them. It is one pass now, unmasked on the way across,
and a message too big to have arrived whole is read straight into your buffer,
past the connection's read buffer entirely
([ADR 0052](./docs/adr/0052-a-message-is-copied-once-and-framed-once.md)).

| `zig build profile` | was | is | |
|---|---|---|---|
| `websocket: frame overhead` | 9ns | 6ns | 1.5× |
| `websocket: receive 48 B` | 15ns | 12ns | 1.25× |
| `websocket: receive 16 KiB` | 196ns, 88.1 GB/s | 73ns, 244.5 GB/s | 2.7× |
| `room: say to 8 of 1,000 seats` | 494ns | 161ns | 3.1× |

Nothing about the API changed to get any of that. What did change:

- **`socket.print(fmt, args)` and `socket.json(value)`**, and the same pair on
  a `Room`. One text message, formatted or serialised straight onto the wire,
  with no stack buffer of yours to size:

  ```zig
  try room.print("welcome, {d} here", .{room.count()});
  try socket.json(.{ .kind = "joined", .who = name });
  ```

  Neither allocates on a Socket; on a Room they reuse the allocation `say` was
  going to make. Both run the format twice, once to size the frame and once to
  write it, because a frame states its length before its bytes.
- **`receive` ends when the server is stopping**, after telling the client so
  with a 1001. A message loop no longer needs `if (!socket.live()) break;` in
  it, which was a rule ADR 0020 stated and every handler had to remember.
  `live()` stays, for a handler doing work of its own between messages.
- **Sending on a socket that has already closed writes nothing** rather than
  failing. The other end closing between two of your sends is not a bug you
  can prevent, so it is not one you have to branch on.
- **A malformed close frame is refused with a 1002 rather than echoed.** A
  one-byte payload, a code nobody assigned, or a reason that is not UTF-8:
  echoing those put the same broken frame back on the wire. A reason of your
  own that is too long for a close frame is now cut on a character boundary
  rather than through the middle of one.
- **A fragment is measured against what is left of your buffer**, not all of
  it, so a continuation that cannot fit beside what came before is refused on
  its header.
- **Sizing a `Room` generously is a memory decision and nothing else.** `join`
  and `say` cost what the room holds rather than what it was sized for, and a
  `say` into an empty room allocates nothing at all.

#### Fixed: a WebSocket went deaf after its first message

**A socket that had sent anything stopped receiving `Room` broadcasts and
stopped being pinged.** `examples/chat` is what that looks like from outside:
two tabs, type in one and the other sees it, type in the other and the first
never hears from it again. `Options.idle_ms` had the same hole. It only ever
pinged a socket that had never spoken, so the heartbeat meant to catch a
client that has gone away could not catch one that had ever said anything.

The engine armed its `NetPoll` completion on the way *out* of a `.readable`
rather than on the way in, and `NetPoll` is level-triggered, so the next wait
answered `.readable` for bytes that had already been read and dropped the
fiber into a blocking read with no deadline on it. `Waker.wait` now states the
contract it always meant: **`.readable` is answered once per arrival of bytes,
not once per call.**

Worth knowing how it survived. The HTTP suite runs against in-memory buffers
with `Waker.off`, which answers `.readable` to everything by design, so no
test could see it, and no benchmark touched a WebSocket until this cycle. It
was found by measuring something else.

#### What a handler can reach

- **`Ctx.arena()` and `Ctx.str()`**: memory that lasts exactly one request,
  and text stamped with that request's lifetime. A module beside the framework
  needed a supported way to allocate for a request.
- **`c.entropy(n)`**: `n` unguessable bytes from the operating system,
  returned by value, with the wait paid for by the Bulkhead rather than by the
  thread every other request is sharing
  ([ADR 0046](./docs/adr/0046-entropy-belongs-to-the-loop.md)).
  `nilo.randomSecure(&buf)` is the same bytes into a buffer you already hold.
  Together with the clock, this is what `nilo_id` was waiting for:

  ```zig
  const key = id.v7(try c.entropy(id.Uuid.v7_entropy), @intCast(nilo.nowMillis()));
  ```
- **`nilo.nowMicros()` and `nilo.nowMillis()`**: what time it is, which
  nothing in nilo could answer before. They are `nilo_core`'s, so a program
  with no server in it has them too, and they are plain functions rather than
  calls on a `Ctx`, because reading a wall clock needs no event loop and
  nobody owns the time ([ADR 0045](./docs/adr/0045-core-knows-what-time-it-is.md)).
  15ns a call. Use `nilo.monotonicNanos()` for a duration, because a wall
  clock moves when an operator moves it.

#### Routes, groups and bindings

- **`g.without(mw)`**: the same group with one middleware off for the routes
  registered through it, which is how `/v1` gets a session guard and
  `/v1/sign-up` still answers. The default stays deny, and the exception lives
  where the route is, so renaming the route moves it
  ([ADR 0080](./docs/adr/0080-a-route-can-say-it-is-not-covered.md)).
  **`@TypeOf(g).mounted_at`** publishes the prefix a group was built with,
  which a plugin had no way to ask for.
- **`b.must("field", holds, "wants …")`**: a rule of your own, in the same 422
  as the fields nilo could not convert. Validation is still yours and nilo
  writes no rule; what it carries is the answer, so an endpoint stops refusing
  in two shapes ([ADR 0082](./docs/adr/0082-a-rule-of-your-own-joins-the-answer.md)).
  **`Bound(T).ok(value)`** builds one for a test without knowing `Outcome`
  exists.
- **A body nested deeper than nilo follows says so.** Past eight levels the
  400 was empty: no field, no reason, indistinguishable from a body that is
  not JSON. It now says which wall it hit
  ([ADR 0081](./docs/adr/0081-a-ceiling-that-is-reached-is-said-out-loud.md)).
- **A `union(enum)` gets a `oneOf` schema** instead of `{}`, and one shape
  that differs only by a lifetime, `Filing(Str)` against `Filing(Text)`, is
  one component rather than two
  ([ADR 0077](./docs/adr/0077-a-lifetime-has-no-rendering-in-json.md)).

#### Starting up

- **`app.start(io)`**: the phase there was not. After the services are open
  and before a socket exists, for the migration or the seed that has to run
  against a live pool. `listen()` reaches the same code, so a program that
  does both does not open two pools
  ([ADR 0079](./docs/adr/0079-there-is-a-phase-before-the-server.md)).
- **`listen()` finishes services that need the event loop.** A service
  declaring `nilo_start` is handed the loop once it exists and before the
  first connection is accepted, which is the only reason a connection pool can
  exist at all
  ([ADR 0040](./docs/adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)).
- **`nilo.Limits`** bounds an operation that is not a read or write of a
  connection nilo holds, for a service that asks for it
  ([ADR 0065](./docs/adr/0065-the-way-out-was-open-the-clock-was-not.md)).
  Nothing you wrote changes: `nilo_start` still takes `(self, io)`, and the
  three-parameter form is for a service that wants a clock.

  ```zig
  pub fn nilo_start(self: *Mailer, io: std.Io, limits: nilo.Limits) !void {
      self.io = io;
      self.limits = limits;
  }

  var bound: nilo.Limits.Bound = .idle;
  defer bound.release();
  bound.arm(self.limits, 2_000);
  ```
- **A mismatched `.optimize` is a warning**, at `listen()` and at the first
  `testing.Client`, the test step being the one that usually gets missed
  ([ADR 0084](./docs/adr/0084-a-library-can-tell-what-mode-the-program-was-built-in.md)).
  It reads the mode off two constants of std's own rather than one: in Zig
  0.16 `std.log.default_level` is `.info` for **all three** release modes, so
  the level alone answers ReleaseSafe for a `ReleaseFast` program and the
  warning fires at exactly the people who passed the mode through.
  `std.debug.runtime_safety` is what tells the pair apart.

#### The documentation compiles

**`zig build snippets`** compiles the marked snippets in the README, the
reference and the guide, which is how seven mistakes in one five-line example
were found ([ADR 0083](./docs/adr/0083-the-guide-is-the-source-of-its-own-snippets.md)).
New page: [Settings](./docs/guide/config.md), with the whole of a `main` that
reads a `.env`.

### `nilo_sql`: Postgres, and now SQLite

0.1.0 shipped the compile-time half: your struct was the table, and the SQL
was settled before the program ran. It could not reach a socket. It can now,
over [pg.zig](https://github.com/lalinsky/pg.zig) for Postgres and
[zqlite.zig](https://github.com/karlseguin/zqlite.zig) for SQLite, both
checked against a real database on every push.

Rows come out of the request arena, so nothing here is freed by hand.

#### Reading

- **`db.select`, `db.one`, `db.stream`.** `one` returns `?Row`, so a handler
  returning `!?User` answers 404 and the OpenAPI document says so, and it
  compiles its own `LIMIT 1`: a lookup on a column that is not unique costs
  one row rather than every match. `stream` is for a result set too big to
  hold.
- **`db.find(User, c, id)`**: `one` with the condition already filled in, on
  the column the Row's `.key` names. `fn show(db, c, id: i64) !?User` is then a
  whole endpoint, 404 included.
- **`db.count` and `db.exists`**: the total a page needs, and whether anything
  matches at all. Both take a condition and nothing else, and both go through
  the same walker `select` uses, so a page and its total are one condition
  written once and a misspelled column is the same compile error in both.
  `exists` is `SELECT EXISTS(…)`, which stops at the first row.
- **A written-out `.limit` costs one allocation, at any size.** The limit is a
  ceiling known before the first row arrives, so the list the rows go into is
  built to it instead of doubling its way there. Measured over a 32-byte row:
  one allocation from ten rows to a hundred thousand, against 2, 3, 5 and 9
  without it. [ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)
  claimed a number here for a year and the number was wrong. It is corrected
  in place and a test now holds it.
- **A `.limit` or an `.offset` binds as whatever integer you are holding**,
  `usize` included, rather than only the ones that coerce to `i64`.
- **A streamed row is `sql.Borrowed(User)`**, which is `User` with every `Str`
  replaced by `[]const u8`, because that text dies at the next row and the
  type says so. `stream` refuses a Row with a `Json` or a list column: a
  borrowed row allocates nothing, and parsing a document per row cannot.
- **`db.raw`**: the way past *one table, conditions that filter rows*. Still
  fills your struct, still uses the arena, and gives up the column check only.
- **`db.exec(c, sql, values)`**: a statement that answers with nothing, which
  used to mean inventing a Row to have one.

#### Writing

- **`db.insert`** (with `RETURNING`, so the generated key comes back),
  **`db.update`** and **`db.delete`**, the last two answering with the number
  of rows they touched and both refusing to compile without a condition.
- **`db.updateReturning` and `db.deleteReturning`**: the rows themselves
  rather than a count. A `PATCH` that changes a row and answers with it was an
  update and then a select, which is two round trips and a read that could
  find what somebody else changed in between. The clause they add is the
  `SELECT` list this module already writes.
- **`db.insertOrIgnore` and `db.insertOrUpdate`**: `ON CONFLICT`, which had no
  spelling, so an idempotent write was a caught `AlreadyExists` and a second
  statement. Two round trips, with a window between them that a retry does not
  close. Now one statement and no window. The conflict target is the last
  argument, written the way a key is (`.email`, or `.{ .tenant_id, .email }`),
  and it does not have to be the Row's key, which is the case it exists for.

  Two calls rather than an option on `insert`, because the answers differ:
  `DO NOTHING` stores no row so `insertOrIgnore` returns `?User`, and
  `insertOrUpdate` returns `User`. `db.insert` is untouched. The update half
  writes every column you passed except the conflict target and the key, since
  `"id" = EXCLUDED."id"` would renumber the row that was already there.
- **`db.insertMany(Row, c, rows)`**: a whole batch in one statement and one
  round trip, whatever the batch size
  ([ADR 0053](./docs/adr/0053-a-batch-is-one-array-per-column.md)). The rows
  come back in the order they were sent.

  ```zig
  const Line = struct { sku: Str, qty: i32 };
  const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
  ```

  It sends one array per column and lets Postgres `unnest` them, rather than
  the `VALUES ($1,$2),($3,$4),…` most libraries generate, whose placeholder
  count *is* the batch size. That would mean building the SQL per call and
  Postgres planning a new statement for every size. Here the text is a
  constant and the size is data. It costs one allocation per column, not per
  row, and a batch that violates a constraint takes all of its rows with it,
  because it is one statement.
- **`db.updateMany(Row, c, rows)`**: the batch's other half, and the same
  `unnest`, joined against the table rather than selected into it. Each row
  carries the Row's key and is found by it, so there is no `.where`, and a
  batch that does not carry the key is a compile error. Order is the planner's
  and a repeated key changes its row once. Both are what a join is, and
  `db.update` in a loop is the answer where either matters.
- **`tx.insertMany` and `tx.updateMany`** are the same calls inside a
  transaction.

#### Conditions

- **`.not_in`, `.not_like` and `.not_ilike`.** `.ne` was the only negation
  there was, so `not in`, which is as common as `in`, meant a second query or
  `db.raw`. `.not_in` is `<> ALL($1)`: one parameter however long the list is,
  exactly as `.in` is.
- **A condition takes a `Str`.** `.where = .{ .email = form.email }` is what
  everybody writes, and it did not compile.
- **An optional in a condition no longer compiles.** `.handle = null` written
  out is `IS NULL`. `.handle = maybe`, with `maybe` a `?[]const u8`, used to
  take the parameter path and send `"handle" = $1` with NULL in it, which is
  never true in SQL. The query ran, matched nothing, and said nothing. Which
  of the two statements is right depends on a value that arrives after the
  statement is a constant, so it is a Refusal asking for the branch
  ([ADR 0044](./docs/adr/0044-a-condition-holds-a-value-not-a-maybe.md)).
  Writes are untouched: `.set = .{ .handle = maybe }` is how a column is set
  to NULL, and it means one thing.
- **`.distinct_from` and `.not_distinct_from`**: SQL's null-safe comparison,
  and the one operator a condition takes an optional for.

  ```zig
  var handle: ?[]const u8 = maybe_from_the_request;
  const found = try db.select(User, c, .{
      .where = .{ .handle = .{ .not_distinct_from = handle } },
  });
  ```

  It is `=` with null treated as an ordinary value, so the SQL is the same six
  words either way, which is why this one operator does not have the problem
  above. It also finds the null rows `<>` silently drops. The compile error
  for an optional points here first and at the branch second.

#### Transactions

- **`db.begin(c, .{})`**, held and released the way every other resource in
  nilo is: `defer tx.deinit()` rolls back unless committed.
- **A transaction takes what it is on the `BEGIN`.** `.isolation` and
  `.read_only` are comptime and folded into the statement, so neither option
  costs a round trip.
- **`tx.savepoint()`**: a mark one part of a transaction can be undone back
  to. `sp.release()` keeps the work, `sp.rollback()` undoes it, `sp.deinit()`
  undoes unless something kept it. This is what a nested transaction is.
  Postgres has no nested `BEGIN`, and an inner commit is not durable. It is
  also the only way to survive a failed statement inside a transaction, which
  otherwise aborts all of it.
- **A read inside a transaction can hold what it matched.** `.lock = .update`,
  `.update_nowait`, `.update_skip_locked` or `.share`, written where the
  condition is. `.update_skip_locked` is a work queue in one option, and
  `.update_nowait` answers `error.Locked`. A `.lock` on `db.select`, `db.one`
  or `db.stream` is a compile error, because a lock with no transaction around
  it is taken and dropped before the handler reads a row
  ([ADR 0054](./docs/adr/0054-contention-is-what-a-transaction-is-for.md)).
- **`tx.deadline(ms)`**: bound how long each statement in a transaction may
  run, and get `error.TimedOut` when one goes past it
  ([ADR 0047](./docs/adr/0047-a-deadline-needs-a-connection-you-hold.md)). It
  is on the transaction rather than on `Db` because a deadline is always a
  second command and has to travel down the same connection as the statement
  it bounds, which is what a transaction already holds and a plain
  `db.select` does not. One round trip, paid by the caller who asks for it.
- **A failed statement inside a transaction no longer costs a reconnect.**
  Postgres marks an aborted transaction with a ReadyForQuery status pg.zig
  maps to the same state it uses for a dead socket, so the `ROLLBACK` that
  followed was refused and nilo destroyed the connection rather than return
  one it could not vouch for. Nothing downstream could tell, because the pool
  re-dialled, so this is a latency and connection-churn fix rather than a
  correctness one. It applies to every failed statement in a transaction, not
  only a timed-out one.

#### Column types

- **`sql.Timestamp`, `sql.Uuid` and `sql.Json(T)`**: the three columns Zig has
  no word for, read and written as themselves. A `timestamptz` arrives as
  microseconds since the epoch, a `uuid` as its sixteen bytes, and a `jsonb`
  parsed into the struct you named. Each writes itself into a JSON body the
  way the API description promises. **`sql.Timestamp.now()`** is there so
  `created_at` is a field a handler fills rather than a database default it
  has to remember to set.
- **`sql.Uuid` works on SQLite too.** It binds as 36 characters there and as
  16 bytes on Postgres, which is what each stores
  ([ADR 0078](./docs/adr/0078-a-uuid-is-whatever-the-database-stores.md)). It
  used to be a compile error from three layers down naming a Zig issue.
- **`sql.Decimal`**: a `numeric` column, which this module could not read at
  all. Money in an `f64` is wrong quietly, and reading the column type that
  exists to prevent that into a float gives the whole problem back. It holds
  the digits, it does not calculate, and **in a JSON body it is a string**:
  `"1234.56"`, not `1234.56`, because a bare number is exact on the wire and
  becomes a double the moment a consumer parses it
  ([ADR 0050](./docs/adr/0050-a-numeric-is-digits-and-a-string-in-json.md)).
  Comparisons are numeric, it costs the same one arena copy a text column
  always has, and unlike `sql.Json(T)` it streams.
- **A column type can come from outside this module.** Any struct or enum with
  `nilo_column`, `nilo_read(text, arena)` and `nilo_write(arena)` is one, and
  it travels as the text Postgres prints. An `interval`, a `money`, a PostGIS
  `geometry` or anything an extension adds is readable without this module
  knowing it exists. `sql.AsText("money")` is that protocol's smallest
  instance ([ADR 0055](./docs/adr/0055-a-column-type-can-come-from-outside-this-module.md)),
  and **`sql.Interval`, `sql.Inet` and `sql.Decimal` are two lines of it
  each**, with no special case left in the Dialect or the driver.
- **Array columns.** `text[]` and `int4[]` are read as plain Zig slices,
  `tags: []const Str` and `scores: ?[]const i32`, with no wrapper type to
  learn ([ADR 0051](./docs/adr/0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)).
  A Row that declared one used to fail to compile four frames inside pg.zig.
  `[]const u8` is still text, so a list of text is `[]const Str` or
  `[]const []const u8`, and an array whose elements can be NULL is read as a
  slice of optionals.

  Two shapes Postgres allows and a slice cannot hold now fail the request: an
  array with a NULL in it read into a non-optional element, and an array more
  than one dimension deep. Both used to be an assert inside the driver, which
  is a panic in Debug and ReleaseSafe and a read past the end of the buffer in
  ReleaseFast.
- **An enum column that has fallen behind its table fails the request instead
  of the process.** A Postgres enum grows a value with `ALTER TYPE … ADD
  VALUE`. A Zig enum that has not grown it used to reach
  `std.meta.stringToEnum(T, str).?` inside the driver and panic, which in Zig
  takes every in-flight request with it
  ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)). It is a 500 now,
  with the value and the type named in the log.

#### The schema check

- **`db.checking(&.{ User, Order })`**: each Row compared against its table
  while the server starts, instead of on whichever request got there first. A
  table that is not there at all is one line saying so, rather than one
  `no_such_column` per column of a table nobody created. An enum carrying
  `pub const nilo_column = "user_role"` is compared like any other type.
- **A table can be qualified.** `.name = "app.users"` is a schema and a table
  now, quoted as two identifiers and introspected in that schema. Before, it
  was quoted as *one* identifier, `"app.users"`, a relation nobody created,
  and the error arrived at run time. A bare name still means whatever
  `search_path` resolves to. More than one dot is a compile error rather than
  a run-time surprise.
- **A Row can read a view or a materialized view.** The check asked
  `information_schema`, which cannot see a materialized view at all, hides
  columns the role has no privilege on, and reports every view column as
  nullable. A Row over a view was one disagreement per field and, by default,
  a server that refused to start. It asks `pg_catalog` now, and a column's
  nullability has a third answer for the case the database does not know
  ([ADR 0056](./docs/adr/0056-a-view-is-a-table-that-cannot-say-what-is-not-null.md)).

#### Statements are kept prepared, and nothing in your code asks for it

Every statement this module sends is settled while compiling, so each is kept
on the connection it went down under a name derived from its own text. The
second send skips Parse and Describe. Measured at **30% of a key lookup and
14% of a page with a sort**, about 12 µs a query either way, which is a fixed
cost and so worth most to the cheap queries a service runs most of
([ADR 0057](./docs/adr/0057-a-statement-that-is-a-constant-can-be-prepared-once.md)).

Through a server rather than a stopwatch it is worth more than the per-query
share suggests: **89k to 135k req/s at a pool of eight, 106k to 177k at
thirty-two, 112k to 191k at sixty-four**, with p50 down 33 to 45%. A pool
connection is a serial queue, so time not spent holding one is capacity.

`db.raw` is never prepared, because its text arrives at run time. Behind
**pgbouncer in transaction mode** set `.prepared = false`, or a statement
prepared on one server connection is missing on the next.

#### A second database is a second type

`sql.Named("replica")` gives back a `Db` distinguished by its name, so two
pools are two services and which one a statement takes is written where a
reader sees it: the handler's argument list. Good for a read replica, a
reporting warehouse, or a database somebody else owns.

Nothing routes between them, because an automatic reader needs health
checking, lag awareness and read-after-write safety, and the last one fails
silently. There is no query cache for the same kind of reason: invalidation
cannot be right from a module that sees only its own writes
([ADR 0060](./docs/adr/0060-a-second-database-is-a-second-type.md)).

#### SQLite

`sql.Db` is Postgres and **`sql.Sqlite(…)` is SQLite**. Everything above this
line (Rows, conditions, `find`, `select`, `stream`, transactions, savepoints,
the schema check) is the same code against either, because the driver was
always behind a seam and this is the seam being used
([ADR 0073](./docs/adr/0073-a-file-has-no-socket-to-wait-on.md)). The SQL half
of that seam was written and tested a release earlier with no driver behind
it, and twelve of its thirteen declarations fitted with nothing changed
outside the Dialect
([ADR 0061](./docs/adr/0061-the-second-dialect-is-the-test-of-the-seam.md)).

```zig
const Db = sql.Sqlite(.{ .threading = .{ .hop = nilo } });

var db = Db.init(gpa, "/var/lib/app/shop.db", .{ .size = 5 });
defer db.deinit();
try app.provide(&db);
```

**`threading` has no default and will not compile without one.** SQLite is a
library reading a file, so there is no socket to wait on and no answer the
framework can pick for you. `.{ .hop = nilo }` hands the statement to the
Engine's thread pool and costs a few microseconds. `.in_fiber` runs it on the
fiber that asked and is faster until one statement is slow, at which point it
holds a thread that was serving other connections. Which should be advised is
unmeasured, and it is the module's next benchmark.

- **One writer and `size - 1` readers**, and that is the database rather than
  a setting. SQLite allows one writer at a time, and under WAL the readers run
  beside it. Writes queue on a `std.Io.Mutex`, so a fiber waiting its turn
  parks instead of holding a thread
  ([ADR 0074](./docs/adr/0074-one-writer-is-not-a-setting-it-is-the-database.md)).
- Every connection is primed with WAL, `foreign_keys = ON` and
  `synchronous = NORMAL`, which is WAL's recommended setting, where the
  database cannot corrupt and a power cut can lose recent transactions.
  `.full` is one word away and `OFF` is not offered.
- **Which connection a statement takes is its first keyword.** Exact for
  everything the module generates, a guess for `db.raw`, and the guess is safe
  because a reader is opened read-only. On a file. In memory, SQLite's URI
  `mode=` overrides the open flag, which is why a bare `:memory:` is refused
  at `open` and the shared form is the one to write.
- **Five Refusals, each naming the dialect**: `insertMany` (no `unnest`, and
  SQLite's batch form grows its own statement text), `.lock` (writers are
  serialised by a database-wide lock, so there is no row to hold),
  `tx.deadline` (`sqlite3_interrupt` aborts the connection rather than the
  statement, and `busy_timeout_ms` covers the case that happens), a list
  column (no array type), and any isolation below `.serializable` (there is
  nothing weaker to ask for). **Code that batches is not portable between the
  two**, which is the seam refusing rather than lying.

A pool connection holds **28 KiB** opened, growing towards `cache_size` as
pages are touched. The 2 MiB default was measured to buy nothing at either
shape tested ([`bench/result/sql.md`](./bench/result/sql.md)).

The driver bundles the SQLite 3.53.0 amalgamation and is `.lazy = true`, so a
project that uses Postgres or no database at all fetches, builds and links
none of it. `nilo_sql` links libc now, which it did not before.

`zig build bench-sql` grew a SQLite half that needs no server, and its
comparisons now run five interleaved passes and print the spread as well as
the best. That change came from the harness catching itself: three consecutive
passes of one measurement on a loaded machine differed by 1.8×.

#### Fixed: a server whose database was down refused to start

`connect_on_init` defaults to zero and is documented as "the pool is
allocated, nothing is dialled". It never worked, because `pg.Pool.initUri`
copies two fields of the options it is given and drops the third. So every
pool opened `size` connections at startup and died on the first refusal, which
also made a `size` larger than the server's `max_connections` a server that
would not boot. nilo parses the URL itself now
([ADR 0062](./docs/adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md)).

One sharp edge comes with it: **driving a `Db` from a `std.Io.Threaded` wants
`connect_on_init = size`.** Anything less hands the rest to pg.zig's
reconnector, whose thread cannot park against a `Threaded` Io. Under the
engine it is fine. A server boots with Postgres down, connects when it comes
up, and serves 135,000 requests a second at a pool of eight.

A failure inside a transaction is also reported as its own now. `translate`
reads the server's code off the connection, and a transaction holds one across
statements, so a broken pipe after a unique violation came back as
`AlreadyExists`, the previous statement's answer.

**`error.AlreadyExists` is a 409.** A unique violation is the one database
error whose meaning does not change with the request around it, so it is the
only one given a default answer. The rest reach your handler as errors that
read.

#### Still refused

The module is not an ORM. Joins, aggregates and migrations are out
([ADR 0039](./docs/adr/0039-the-shape-of-a-query-is-settled-while-compiling.md)),
and **44 Refusals** hold its error messages: a Row written wrong, a column
misspelled, an update with no condition, a key where a condition belongs.

**Set operations and pipelining are refused, and both are measured or argued
rather than skipped.** Over one table, `UNION`, `INTERSECT` and `EXCEPT` are
boolean algebra on the `WHERE` clause and the module writes all of it. Over
two they are a view, which a Row may already name
([ADR 0058](./docs/adr/0058-a-set-operation-over-one-table-is-a-condition.md)).
A CTE is `db.raw`. Several statements in one round trip is refused with
numbers: **a round trip to Postgres is 24 µs and the query inside it is about
2**, and a server here does **215,000 requests a second with a real query in
every one**, because a waiting fiber frees its thread
([ADR 0059](./docs/adr/0059-a-round-trip-is-not-the-cost-worth-chasing.md)).
`bench/sql_server.zig` is that measurement, and it is in the repository.

### `nilo_s3`: object storage

**S3, MinIO, R2, anything that speaks the dialect**
([ADR 0072](./docs/adr/0072-an-object-store-is-a-service-that-dials.md)).

```zig
const s3 = @import("nilo_s3");

// A bucket is a type. Its name is compiled in, so the host and the path
// prefix are built once, and a name that could never work is refused
// before the program runs.
const Avatars = s3.Bucket("avatars", .{ .max_bytes = 2 << 20 });

var store = try s3.open(gpa, .{
    .endpoint = "https://s3.ap-southeast-1.amazonaws.com",
    .region = "ap-southeast-1",
    .credentials = .{ .static = .{
        .access_key_id = settings.aws_key,
        .secret_access_key = settings.aws_secret,
    } },
});
defer store.deinit();

var avatars = try Avatars.open(&store);
defer avatars.deinit();
try app.provide(&avatars);

fn avatar(avatars: *Avatars, c: *nilo.Ctx, id: nilo.Str) !void {
    const object = try avatars.get(c, id.view());
    return c.send(200, object.content_type.view(), object.bytes.view());
}
```

`get`, `getRange`, `getIf`, `stream`, `put`, `putStream`, `delete`, `head` and
`presign`. One Store holds the pool, the credentials and the signing key. Each
Bucket is a type over it, and two buckets share one pool.

- **A bounded `get` makes one allocation**, and it holds the body, the content
  type and the ETag together.
- **An object over the bucket's `max_bytes` costs a round trip, not a
  download.** `content-length` is checked before a byte is read.
- **A signing key is derived once a day**, not once a request
  ([ADR 0069](./docs/adr/0069-a-signing-key-changes-once-a-day.md)). What a
  request pays is one SHA-256 and one HMAC.
- **The canonical request is never assembled as bytes.** It is written
  straight into the hash, because the bytes would be a buffer on a handler's
  stack, and a handler's stack is held per connection
  ([ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md)).
- **Seven errors**, because a handler would do something different about each:
  `NotFound`, `TooLarge`, `Throttled`, `Unavailable`, `TimedOut`, `Rejected`,
  `Failed`. S3's own code is logged rather than sent on, because a `Rejected`
  reaching a client as 403 would be telling the caller they are not allowed
  when the truth is that the server's credentials are wrong. A skewed clock is
  read out of the error body and said plainly.
- **Temporary credentials are one function**, called lazily by the request
  that notices they are near expiry. There is no background task.
- **`presign` touches no socket**, and the life it reports is the true one:
  the smallest of what was asked, what the bucket allows, and what the
  credentials have left.

**No `LIST`, no `COPY`, no multipart upload.** One sentence covers all three:
they are where S3 stops being bytes at a key and starts being a document
format ([ADR 0068](./docs/adr/0068-a-bucket-is-a-type-and-a-key-is-not.md)).

What it costs is in [`bench/result/s3.md`](./bench/result/s3.md), against the
same seven routes written in Go and Rust, and all four of ADR 0018's axes are
in it. Reading a 1 KB object costs **11,814 ns of CPU** beyond answering the
same bytes from memory, which is 5.0× less than Rust with the official AWS SDK
and 8.3× less than Go with its own. An idle connection holding a store costs
nothing over one that does not, and an idle connection that has *read* an
object costs 2,057 bytes more. A megabyte through the arena is 4,108, and
8,202 for the same megabyte streamed through 64 KB of stack. The frugal-looking
route is the expensive one, which is
[ADR 0063](./docs/adr/0063-a-handlers-stack-is-per-connection.md) with a number
under it.

### `nilo_fetch`: calling somebody else's API

A module of its own, and the layer it introduced: it borrows the loop and owns
no destination ([ADR 0070](./docs/adr/0070-a-fitting-borrows-the-loop.md)).

```zig
const fetch = @import("nilo_fetch");

var api: fetch.Client = .init(gpa, .{});
try app.provide(&api);

fn charge(api: *fetch.Client, c: *nilo.Ctx) !Receipt {
    const res = try api.post(c, "https://api.example.com/v1/charges", "amount=500", .{});
    if (!res.ok()) return nilo.fail.status(502, "the payment service said no", .{});
    return res.json(Receipt, c);
}
```

`std.http.Client` is the client: pool, HTTP/1.1, TLS. What this adds is
sixty-five lines of the policy a server needs and a script does not, and each
line of it closes something real.

- **A gate on calls in flight** (32 by default). std's pool bounds *idle*
  connections and not in-use ones, so 500 concurrent handlers is 500 live
  connections at 59,151 bytes of buffers each.
- **A deadline per call** (30s by default), because `std.http.Client` has none
  and an endpoint that accepts and then goes quiet otherwise holds a handler
  until the process dies. `error.TimedOut` is this call's own deadline and
  `error.Canceled` is a shutdown, and the two are told apart rather than
  guessed at.
- **A bounded drain**, so refusing a 500 MB response does not download it, and
  the drain itself, so refusing a small one does not throw the connection
  away. std does one or the other depending on where the body stopped: from an
  untouched body its `deinit` reads the whole thing to keep the connection,
  and from one that was started and stopped it closes the connection however
  few bytes remain. `max_drain` decides both, which it did not before.
- **A body ceiling**, enforced while reading, so a lying `content-length` buys
  nothing.
- **A `Str` in your Scope**, so the body lives exactly as long as the request
  and nothing is freed by hand.
- **The body asked for uncompressed.** `std.http.Client` advertises
  `Accept-Encoding: gzip, deflate` and then hands back the *compressed* bytes.
  Decompressing is a separate call there, so a caller who copies the obvious
  four lines gets unreadable bytes and no error to say so. `nilo_fetch` sends
  `identity`. Decompressing instead would cost a 32 KiB flate window on the
  handler's stack, which is per *connection* rather than per request.

A 4xx or a 5xx is a `Response`, not an error: the call worked and the service
said no. Retries, circuit breakers and rate limiting are deliberately absent,
because they are facts about somebody else's service.

**One exception, and it is about a socket rather than a service.** A call onto
a pooled keep-alive connection the peer had already closed is sent again on a
fresh one. `std.http.Client` keeps 32 idle connections and every server reaps
them, so the first calls after a quiet spell get no answer at all, and nothing
about the request reached anybody. Left alone that is a 500 the caller did
nothing to earn: a `wrk` run against `bench/s3_server.zig` after 80 seconds
idle answered **exactly 32 requests non-2xx**, and zero against a warm pool.

The bound is the pool's own size rather than one attempt, and that is measured
too: one retry only took the 32 down to **13**, because when a whole pool goes
stale together the retry draws a second dead socket about as often as a live
one. At most one attempt per connection the pool could be holding takes it to
**0**, with throughput unmoved. A `.stream` body is never replayed, because its
reader has been spent
([`bench/result/s3.md`](./bench/result/s3.md),
[ADR 0067](./docs/adr/0067-most-of-an-s3-client-is-not-s3.md)).

**`fetch.Exchange`** is the same policy with the body left on the socket, for
an answer too big to hold. Read the head, decide, then move the bytes into a
writer rather than into memory.

```zig
var ex: fetch.Exchange = .idle;
defer ex.end();

const head = try ex.begin(client, .{ .method = .GET, .url = url });
if (head.content_length) |n| if (n > ceiling) return error.TooLarge;
_ = try ex.pipe(&body.writer);   // allocating nothing
```

`begin`, then one of `take` (into the Scope, bounded), `readInto` (exactly
that many bytes), or `pipe`, then `end` when done. The transfer and redirect
buffers are the caller's, because their cost is the caller's stack.
`nilo_s3` is built on it, and `Client.send` is the same code path with the
body taken whole.

`examples/outbound/` is a working one: `zig build run-outbound`, then
`curl localhost:8787/repos/ziglang/zig`. `zig build smoke-tls -Dnetwork` calls
a real HTTPS endpoint and is deliberately not part of `zig build test`. All
four axes, each against a control that calls `std.http.Client` directly, are
in [`bench/result/fetch.md`](./bench/result/fetch.md).

### `nilo_config`: settings

Read into a struct of your own, before the socket opens
([ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)).

```zig
const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
    database_url: []const u8,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const read = config.fromEnv(Settings, init.minimal.environ);
    const settings = read.value() orelse {
        try read.report(stderr);
        std.process.exit(2);
    };
}
```

- **The field is the setting, and its name is the variable.** `database_url`
  is read from `DATABASE_URL`, a default is what "not set" means, and a `?T`
  is a setting that may be absent. Those are the same three sentences a
  `Query(T)` follows. `fromWith(T, .{ .prefix = "NILO_" }, …)` puts a prefix
  in front of every one.
- **Every bad setting is named at once**, which is the reason this exists
  rather than the reading. `value()` is `?T` the way `Bound`'s is, so there is
  no way to reach past a failure into a half-filled struct:

  ```
  3 settings could not be read from the environment:
    PORT has to be a whole number, not "soon"
    DATABASE_URL is not set
    LOG_LEVEL has to be one of debug, info, warn, not "verbose"
  ```

  `read.failures()` walks them if you would rather write your own.
- **It opens no files, and that is the decision.** `config.Fixed` is the seam
  a program hands its own parsed pairs through, so TOML is a dependency you
  pick rather than one this module makes every project carry. `std.zon.parse`
  is in the standard library and costs nothing.
- **A `.env` is a source, and you open the file**
  ([ADR 0064](./docs/adr/0064-a-dotenv-is-text-somebody-else-read.md)).
  `config.Dotenv` takes the *text*, so the module still allocates nothing and
  still imports nothing. `config.layered` puts sources in the order they win,
  and the first with the name answers, which is how a variable somebody
  actually set beats the file:

  ```zig
  const text = std.fs.cwd().readFileAlloc(arena, ".env", 64 * 1024) catch "";
  const file = config.Dotenv{ .text = text };

  const read = config.from(Settings, config.layered(.{
      config.Env{ .environ = init.minimal.environ },
      file,
  }));

  try file.report(stderr);   // writes nothing when the file is clean
  ```

  The text has to outlive the Config, exactly as the environment block does. A
  line that meant to be a setting and is not is **reported with its number,
  never skipped**, because otherwise a missing `=` on line 7 reads as
  "DATABASE_URL is not set" about a file that plainly sets it. It reads
  quoting, `export `, CRLF and `#` comments on their own line, and refuses
  escapes, interpolation and comments after a value, so `PASSWORD=abc#123`
  survives. A report never quotes a value.
- **Text is `[]const u8`, not `Str`.** Settings are read once and held for the
  life of the process. The lifetime a `Str` carries has nothing to say about
  them, and `config.Env` reads the environment block where it lies rather than
  copying out of it. On Windows use `config.Map` with the `environ_map`
  `std.process.Init` already hands to `main`.

### `nilo_pw`: passwords

argon2id, and the two `Ctx` methods that make it safe to call from a handler
([ADR 0048](./docs/adr/0048-a-password-hash-is-gated-because-forgetting-is-silent.md)).

```zig
// signing up
const stored = try c.hashPassword(pw.huge_pages, form.password);
_ = try db.insert(User, conn, .{ .email = form.email, .password = stored.text() });

// signing in
const row = try db.find(User, conn, .{ .email = form.email });
if (!try c.verifyPassword(pw.huge_pages, if (row) |r| r.password else null, form.password))
    return nilo.fail(401, "that is not a sign-in");
```

- **`stored` is optional, and null means there is no such account.** It does
  the work anyway and answers false, which costs the same as an account that
  exists. A sign-in that returns early on an unknown address answers in a
  millisecond instead of thirty, and turns the form into a query for which
  addresses are registered. There is no signature here that lets the fast
  wrong version be written.
- **The methods are on `Ctx` because forgetting is silent.** One hash is 13 ms
  and 19 MiB. Thirteen milliseconds is *under* `block_warning_ms`, so a
  handler calling the pure module directly holds its thread on every sign-in
  and nothing in the log ever says so. These take the salt from `c.entropy`,
  park the fiber on the blocking pool, and hold a permit from a Gate.
- **`Options.password_hashes_at_once` defaults to 8**, and the number is
  measured. Argon2id is bound by memory bandwidth, not cores: on 16 cores the
  throughput ceiling is about 280 hash/s, and eight reaches 91% of it for 152
  MiB, where the ungated 32 reaches *less* for 608 MiB.
- **`pw.huge_pages` is the allocator to hand it.** The same 19 MiB asked for
  in 2 MiB pages rather than 4,864 of 4 KiB: **13.6 ms a hash becomes 11.0**,
  and nothing is held between hashes
  ([ADR 0049](./docs/adr/0049-a-hash-asks-for-the-pages-it-walks.md)). It is
  `std.heap.page_allocator` on anything that is not Linux, so a call site does
  not have to ask what it is running on.
- **The stored form is the PHC string everybody else writes**,
  `$argon2id$v=19$m=19456,t=2,p=1$…`, so a hash of nilo's can be migrated off,
  and one made elsewhere at any parallelism verifies here.
- **A Cost below OWASP's weakest published configuration is a compile error**,
  and so is one with more lanes than memory to divide between them. Turning
  the Cost down to make a test suite fast is the mistake worth catching,
  because a weak hash looks exactly like a strong one afterwards.
- **`c.verifyPasswordWith(cost, …)` if you hash at anything but the default.**
  The no-account path does the work of a hash rather than returning early, and
  the Cost is what that work is measured out at. Left at the default while
  your rows are 46 MiB, the two answers take visibly different lengths of time
  and the form is a list of addresses again.
- **`pw.needsRehash(stored, .default)`** answers whether a row was written at
  a weaker Cost than the one in force, for the sign-in that just succeeded to
  write it forward. Fewer kibibytes, fewer passes, a shorter salt or a shorter
  digest; lanes are not in it.
- **`pw.hash` fails one way**, `error.OutOfMemory`. `NotAHash` is something
  only a stored string can be, and hashing never answered it.

### `nilo_id`: UUIDs

```zig
const id = @import("nilo_id");

const key = id.v7(random, ms);            // sortable, the millisecond first
const token = id.v4(random);              // 122 random bits
try w.print("/users/{s}", .{&key.toText()});
```

- **`sql.Uuid` is `nilo_id`'s `Uuid`**, re-exported, so a generated key goes
  straight into `db.insert`. What did *not* move down is the opinion about the
  column: a module that has never heard of Postgres does not carry
  `nilo_column`.
- **`v4` and `v7` are given their randomness rather than fetching it**, and
  `v7` is given its millisecond. In Zig 0.16 entropy and the wall clock are
  both IO, and a module in the bottom layer has no Bulkhead to reach through,
  so this module ships the *format* and says so. A v4 built from a seeded
  `DefaultPrng` is a session token anybody can predict, and the doc comment
  says that at the function. Inside a handler, `c.entropy` is where the bytes
  come from.
- `toText()` answers a `[36]u8` by value, `parse` takes hyphens or not, and
  `millis()` reads a v7's clock back and answers null for anything else. A
  `Uuid` in a returned struct leaves as text rather than as sixteen numbers.

### `nilo_core`: the vocabulary

`Str`, the Scope, the clock and percent coding, needed by every layer and
needing no event loop. **Nothing you wrote changes**: `nilo.Str` is the same
declaration it always was.

- **A Scope is `arena()` and `str()`**, and nothing else. That pair was all
  `nilo_sql` ever wanted from a `Ctx`.
- **`nilo_core.percent`** is percent coding, both directions
  ([ADR 0066](./docs/adr/0066-percent-is-needed-by-two-layers.md)). The
  decoding half moved down from `http/` and behaves exactly as it did. The
  encoding half is new, and it is here because a Service that signs a URL
  cannot import `nilo_http` to reach it. `percent.encodeInto(dst, raw, .path)`
  leaves `/` alone, `.unreserved` escapes it, a space is always `%20`, and hex
  is uppercase. None of those three is an option, because each is a failure
  that says nothing when it happens.

### Running one module's tests

A module that needs no event loop is a module whose tests need no module
graph, and for the bottom layer that is the entry condition rather than a
convenience.

```
zig test core/core.zig       # and id/id.zig, config/config.zig, pw/pw.zig
zig build test-core          # the same, both optimize modes
zig build test-id  test-config  test-pw  test-fetch  test-s3
zig build layering           # no module imports upward or sideways
zig build snippets           # the documentation's own snippets compile
```

**129 error messages** are held in place by five build steps: 63 for the
server, 44 for `nilo_sql`, 10 for `nilo_s3`, 9 for `nilo_config` and 3 for
`nilo_pw`. Each is a program written wrong on purpose that must fail to
compile with the sentence nilo wrote
([ADR 0027](./docs/adr/0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

### What it costs

The two hard axes are unchanged. **Allocations per request** is what it was,
held by a test rather than by intent, and **memory per idle connection went
down**, from 8,767 bytes to 4,669. Throughput and p99 are unmoved: the one
change that could have touched them was measured at +0.6% across four
interleaved runs, which is less than the spread.

Binary size is the axis this release spends, and only for what you import.
Stripped `ReleaseFast`, measured before and after rather than quoted:

| If your program | it pays |
|---|---|
| never imports `nilo_sql` | **560 bytes**, the startup hook, and no driver at all |
| uses all of `nilo_sql` on Postgres | **733 KB**, of which the entire write half is 53 KB and the rest is pg.zig's TLS dependency |
| names `sql.Sqlite` | **523,352 bytes**, the amalgamation, dropped outright by the linker otherwise |
| never signs anybody in | **0 bytes** of `nilo_pw`, byte-identical in every section |
| calls `Ctx.hashPassword` | **149 KB**, plus **820** for `huge_pages`, `verifyWith` and `needsRehash` |
| calls out with `nilo_fetch` | **1,688 bytes** for the module, and 655,600 for `std.http.Client` and TLS |
| reads a bucket with `nilo_s3` | **708,576 bytes**, of which roughly 51 KB is the module and the rest is `std.http.Client` and TLS |
| reads a two-field Config | **3,392 bytes**, or **6,448** with `Dotenv` |
| generates a v7 | **16 bytes** |
| never upgrades a WebSocket | **0 bytes** of the WebSocket work; the chat example pays **896** |

Splitting `nilo_core` out cost **zero bytes**, measured on three binaries
rather than assumed, and adding `nilo_id` and then `nilo_config` beside it
cost the same three binaries nothing again. A seat in a `Room` costs 8 bytes
more than it did, so a room of the default 1,024 seats is 8 KB larger, once.

The one unconditional cost is **+11,400 bytes on the hello example and
+17,272 on rest**, which is the last round of fixes: an App with a start phase
before the server, an exemption list on the chain resolver, and a third
startup warning. `hello` has no body type, no binding, no service and no
document, and it pays most of it, which is what makes it unconditional.

Where the numbers came from is in [`bench/result/`](./bench/result/), one file
per area, each saying what was run, on what machine, at what commit, and which
decision it moved.

### Still not in it

Unchanged from 0.1.0, and each is a decision rather than a backlog item:
templates, TLS, HTTP/2, a gRPC server ([ADR 0028](./docs/adr/0028-tls-is-terminated-in-front.md)),
a `recover` middleware ([ADR 0008](./docs/adr/0008-no-recover-middleware.md)),
counters, and compressing a handler's response. Static files under the spill
threshold are still compressed once, at startup.

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
[`bench/result/http.md`](./bench/result/http.md), with eight other servers through
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
