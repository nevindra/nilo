# Decided

What nilo has decided, so it is not decided twice. Three kinds of thing are in here, and none of them is work: a gap that was looked at and **accepted** as the rule rather than as debt, a question that was **answered** in a line and kept so nobody re-derives it, and a feature that is **not coming**, with the reason. What is still open is in [`todo.md`](./todo.md); the decisions that are binding on the code are in [`adr/`](./adr/), and an entry here that grows past a screen is one of those.

An entry leaves this file only by being reopened, and every entry says what would do that. Bring that, not the patch.

## Accepted

A gap that is the rule. Each was looked at, priced, and kept as it is, and the entry says what it would take to look again.

### `nilo_s3`

**`putMultipart` has no `bench/release/` program.** CLAUDE.md puts a module's new everyday operation there, and multipart is not one: it is minutes of network bounded by the uplink, so instructions and allocations per operation — what `bench/release.py` counts — measure the part loop's bookkeeping against a cost five orders of magnitude larger. The per-call allocations are stated in ADR 058 instead, where they are a claim about the arena rather than a number about speed.

**Reopened by:** a caller whose parts are small and local enough that the bookkeeping shows up, or `bench/release.py` growing a way to measure per-byte overhead rather than per-operation cost.

**`copy` and `compose` have no `bench/release/` program either**, for the same reason: their cost is the store's own copy, seconds of work inside the store against a request's bookkeeping, so instructions and allocations per operation would measure the part that does not matter. ADR 058 states their allocations and stack instead.

**Reopened by:** the same thing as `putMultipart`'s entry, or a store whose copies are fast enough (metadata-only, as on AWS for a whole object) that the request's own cost becomes the cost.

### `nilo_core`

**The layering step cannot tell a test import from a real one.** `zig build layering` refuses an import that is not in that module's row of the `layers` table, and `sql/db.zig` legitimately names `nilo_http` from a `test` block. Telling the two apart needs a parser rather than a scan, so the table has an `in_tests` list the step allows and does not verify. A rule with a listed exception still beats a rule in a document. This is the part of it that is weaker than the rest.

**Reopened by:** the exception list getting long enough to hide something.

### `nilo_config`

**`config.Env` is POSIX only.** It reads the environment block where it lies, which is what makes the whole module allocate nothing, and Windows moves that block. `config.Map` is the portable half and takes the `environ_map` that `std.process.Init` already hands to `main`, so nothing is unreachable. It just costs the map, and the `@compileError` on `Env.get` says which to use rather than letting the failure come out of the standard library.

**Reopened by:** nothing on its own. The allocation-free property is worth more than one uniform call.

### `nilo_id`

**A v7 is not sortable within a millisecond.** Two made in the same one come back in random order relative to each other. RFC 9562 allows a counter in `rand_a` and this has none, on the grounds that it buys ordering nobody asked for at the price of a threadlocal.

**Reopened by:** a service inserting a batch in a tight loop that has noticed.

### `nilo_jwt`

**HS256 is absent on purpose.** A shared-secret token is what a service issues to itself, and a module verifying both algorithms has to be careful about the confusion attack that a module verifying one cannot commit. A client that holds no cookie and needs a token its own server issued gets `nilo.Bearer(T)` ([ADR 265](adr/265-a-bearer-token-is-a-session-sealed-for-a-header.md)): the session's encrypted, expiring seal in an `Authorization: Bearer` header, opened under the session secret and its fallbacks, with no `alg` and no compare to write. Hand-written HMAC is no longer the way round.

**Reopened by:** a caller who must verify an HS256 token issued by somebody else, brought with the reason an RS256 issuer will not do.

### `nilo_job`

**Nothing sweeps finished rows.** `Table.sweep(scope, before)` deletes `done` rows older than a moment, `sweepDead` (on `Table` and `Memory`) the dead ones, and nothing calls either: a program that wants the table small runs it from a scheduled job of its own. Written down so nobody is surprised by a table that only grows.

**Reopened by:** somebody who would rather have a `keep_done_s` setting than a three-line job.

**A revived dead row runs without its unique key.** `retryDead` clears nothing and restores nothing: the key was set to NULL when the row died (so the index could take the next push), and putting it back would need a column on `nilo_jobs` to keep it in, which is a migration for every `Table` user for a rare, manual operation. So a row pushed under the same key after the first one died can run beside the revived one. A caller who needs at most one checks before reviving, with `deadOnes` and a look at what is queued. A scheduled kind is the case that did break something, a second chain of ticks, and `retryDead` refuses it with `error.Scheduled`.

**Reopened by:** a caller whose dead rows carry a key that matters and who revives them often enough that checking by hand is the cost, or a migration that is happening to `nilo_jobs` anyway.

### `nilo_http`

**A `print` or `json` message bigger than the write buffer is still unchecked.** [ADR 076](./adr/076-a-frame-that-lies-about-its-length-is-not-sent.md) holds the two passes to each other by reading `Writer.end`, which is exact only while nothing drains. Past the write buffer a drain moves it and there is nothing left to compare against, so a large formatted message can still put a length on the wire that its bytes do not match.

**Reopened by:** nothing on its own. The two calls are for the small structured messages a WebSocket carries, and the alternatives — a wrapper writer on every byte, or a third pass over the arguments — both cost more than the shape they would guard.

**`csrf` covers neither a `GET` that changes something nor a browser from before 2020.** A cross-site `GET` is a link, and refusing one refuses every link into the site, so a route that changes something on a `GET` is the route's bug. A request with neither `Sec-Fetch-Site` nor `Origin` passes, because that is every non-browser client and none of them carries somebody else's cookie; the browser that sends neither has left the market ([ADR 224](./adr/224-a-request-that-changes-something-says-where-it-came-from.md)).

**Reopened by:** a browser still in use that sends a cross-site `POST` with neither header.

**The API description names one failure, and endpoints have several.** `!?T` puts a 404 in the document because the signature settles it ([ADR 023](./adr/023-a-failure-mode-belongs-in-the-return-type.md)). A `fail.conflict` on a duplicate email is a line in a function body and stays invisible. That is the rule rather than a gap, since the document promises what the signature settles, but it is the rule that costs the most. Widening it means a second place to write a failure down, which is an annotation wearing another name and is the one thing this framework does not ask for.

**Reopened by:** a shape that states a failure *in the type*. Wanting one does not.

**A byte past 0x7f in a request target is routed as sent.** RFC 3986 has no such byte in a URI and llhttp refuses one; nginx and Go route it, `curl` sends a UTF-8 path that way, and it cannot end a line or split a field. A front end that percent-encodes it sends `%XX`, which a path param decodes to the same bytes. `fuzz-llhttp` counts it under `decided` rather than failing ([ADR 231](./adr/231-a-second-parser-reads-what-the-first-one-reads.md)).

**Reopened by:** a front end that reads such a target as a different path from the one nilo routes.

**On HTTP/1.0, a `Connection: close` line before a `Connection: keep-alive` line reads as open.** `close` anywhere in one line wins, and on HTTP/1.1 a `close` stays closed whatever follows; remembering it across lines on HTTP/1.0 is a ninth byte in a `Request` whose eight fill its padding ([ADR 073](./adr/073-a-header-is-answered-as-asked-or-refused.md)).

**Reopened by:** a client that sends the two on separate lines, or a ninth field that `Request` needs anyway.

### `nilo_sql`

**A Row left out of the `checking` list is not checked, and nothing says so.** A `Db` with no list at all warns now ([ADR 192](./adr/192-a-db-with-no-schema-check-says-so-or-is-told.md)); a list with one Row missing from it is still silent for that Row, because Zig cannot enumerate the Rows a program declares and there is nothing to compare the list against. One `sql.Schema` handed to `checking`, the migrations tool and `createMissing` is the answer ([ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md)): a Row the tool does not know about has no table either, which is found the first time a migration is generated.

**Reopened by:** nothing on its own.

---

## Answered, and kept to one line each

Every row has a design that is known and nobody who needs it, or a decision that has been made. They are rows rather than paragraphs because none of them is work until the last column happens.

### `nilo_id`

| Claim | The answer today | What reopens it |
|---|---|---|
| Only UUID v4 and v7 are here; ULID, nanoid, Snowflake, and the v3/v5 name hashes are not | UUID is here because a database column has that type, and a module holding every identifier is a catalogue rather than a decision; v3 and v5 would also make it carry MD5 and SHA-1 | the argument UUID had: a column, a wire format, or a system that requires the shape |

### `nilo_config`

| Claim | The answer today | What reopens it |
|---|---|---|
| A setting cannot be marked secret, so a `report` could print `PGPASSWORD=…` | nothing in the module logs a Config, so there is nothing to redact | the first thing that logs one |

### `nilo_pw`

| Claim | The answer today | What reopens it |
|---|---|---|
| `std.crypto.pwhash.argon2` does its 16-word permutation one word at a time; as four `@Vector(4, u64)` lanes the same hash is **11.19 ms instead of 13.78**, and 8.98 out of `pw.huge_pages`, byte-identical | upstream's to take; nilo will not carry a copy of somebody else's crypto to get it ([ADR 044](./adr/044-a-password-hash-is-gated-because-forgetting-is-silent.md)) | somebody sending `std` the patch |

### `nilo_cache`

| Claim | The answer today | What reopens it |
|---|---|---|
| There is no `getOrPut`, so two threads can compute the same value at once | a `getOrPut` that computes would hold the lock across the caller's work, which [ADR 109](./adr/109-a-cache-holds-its-bytes-under-a-lock-it-can-spin-on.md) forbids. The claim half is `Space.putIfAbsent`; the waiting half needs an `Io`, which this module has none of, so it lives in `nilo_http` as `nilo.Cached` and `nilo.Idempotent` ([ADR 188](./adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)) | a caller of `cache.Space` outside `nilo_http` with a stampede, who then waits on the claim in their own layer |

### `nilo_jwt`

| Claim | The answer today | What reopens it |
|---|---|---|
| A `kid` miss fetches the key set rather than refusing | `jwt.Keyring` bounds that fetch to one an interval ([ADR 111](./adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)), and a caller who wants a miss refused calls `verify` rather than `verifyOrRefresh` and decides | two callers writing the same refusal policy; one is a caller, not a pattern |

### `nilo_proto`

| Claim | The answer today | What reopens it |
|---|---|---|
| Unknown fields are skipped and not kept, so a message decoded and encoded again loses them | a proxy that must pass a message through untouched reads it with `proto.Reader` and copies the bytes it did not name ([ADR 245](./adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)); keeping them would put a list and an allocation on every decode | a caller whose job is to forward messages it does not own, in a count that makes the copy by hand the wrong answer |
| A `map<K, V>` is a slice of `proto.Entry(K, V)`, not a hash map | it is what the wire holds, and a hash map would choose an allocation and a hash for the caller; the entries go into whichever map they want | a caller for whom building that map every decode is the cost |
| There is no `.proto` compiler and no `.proto` reader | the structs are the schema ([ADR 245](./adr/245-protobuf-is-read-from-the-struct-that-declares-it.md)); a project whose contract is a `.proto` file of hundreds of messages is better served by a generator, and nilo reads and writes its bytes either way | a build step that emits the structs from a `.proto`, written by a caller who wants it |
| A message that contains itself directly (`?*const S`) is not supported; recursion goes through a slice | a slice of at most one element stands in | a message in a real schema that cannot be written that way |

### `nilo_http`

| Claim | The answer today | What reopens it |
|---|---|---|
| A response could be brotli or zstd beside gzip | Neither, on the numbers ([`http.md`](../bench/result/http.md#which-deflate-is-fastest-and-whether-brotli-or-zstd-would-beat-it)). brotli at level 5 is 10% smaller than gzip and 14% slower, cannot be pooled so it allocates 1.4 MB a body, and adds 913 KB. zstd is the fastest at every size, and HttpArena accepts only `gzip` and `br`, about 83% of browsers send it, and Zig's std has no encoder | a client population that sends `zstd` and a board that scores it; for brotli, an encoder that can be reset |
| A response whose text is not ASCII pays a byte-at-a-time UTF-8 walk: 10ns for the 365-byte payload `bench/` measures, 2,404ns for a kilobyte of `é` ([ADR 096](./adr/096-a-byte-that-is-not-text-is-not-a-string.md), [`http.md`](../bench/result/http.md)) | `std.json` pays the same; a Keiser–Lemire validator is the fix | a caller whose payloads are mostly not ASCII |
| `Room.handOut` holds the roster lock for a whole broadcast, so `join` and `leave` queue behind it | shortening the hold means draining in `takeSeat` as well, and nothing measures a Room under load: `bench/ws_server.zig` runs the chat loop with the room taken out | a harness that contends for the lock |
| A service argument is found by scanning the registry per request: 1.2ns an entry, 1.6% of a request at four services, 13.4% at thirty-two ([`http.md`](../bench/result/http.md)) | under [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s bar for every app in `examples/`; resolving it into the route at `listen()` is the fix | a caller with more than about sixteen services |
| A megabyte assembled in the arena is retained per connection, and a per-thread block cache read as worth 10,229 → 14,365 req/s | it cannot be built as described: a block recycled while an `io_uring` send still names it corrupts that response, and the number was taken on an L3 this box does not have ([history](./history.md#where-the-cost-turned-out-to-be)) | a rule for when a block is safe to recycle, which is [ADR 003](./adr/003-request-arena-and-the-str-type.md)'s territory |
| The API description costs +14 KB on hello and +34 KB on rest whether or not `docs()` is called ([ADR 016](./adr/016-the-api-description-comes-from-the-signatures.md)) | accepted: 14 KB does not buy a line in every dependent's `build.zig`; it rides along if a third build option ever lands | nothing on its own |
| The logged duration of a streamed response is its lifetime, not its latency | one line per request is the contract; time to first byte is a different number | a caller who needs time to first byte |
| A listener somebody else opened cannot be taken over, so a deploy with nothing in front drops connections in flight | `unix:` addresses ship ([ADR 103](./adr/103-a-path-is-an-address-to-listen-on.md)); an inherited descriptor is one more `address` variant in the Engine, plus a naming protocol (`LISTEN_FDS` or a bare number) | a caller with no proxy in front, saying which spelling their supervisor uses |
| `Forwarded` (RFC 7239) is not read, only the `X-` headers are ([ADR 090](./adr/090-a-request-can-be-read-past-the-parts-a-handler-names.md)) | nginx, HAProxy, Envoy, the cloud balancers and Cloudflare all send the `X-` headers | a proxy that writes `Forwarded` and nothing else |
| A cookie cannot be bound to a handler argument the way a header can ([ADR 131](./adr/131-a-header-a-handler-can-be-given.md)) | `Session(T)` owns the one cookie most programs read; a bare cookie is `c.cookie` and a convert | the cookie half at the scale the header half was built for |
| Every method nilo does not name is `.other`: `PROPFIND`, `PURGE`, `LINK`, `CONNECT` and `TRACE` are one tag | a method carrying its own text costs a string compare on the request path that an enum tag does not | WebDAV, a cache purge, or an internal API that needs two of them apart |
| A sealed cookie cannot be revoked, so "sign out everywhere" is not in the mechanism | a version number in the session checked against the row the handler fetches anyway ([guide](./guide/sessions.md#revoking-a-session-early)); anything further is the store [ADR 033](./adr/033-a-session-is-sealed-into-the-cookie.md) declined | an argument that nilo should have more of an opinion than that |
| `If-Modified-Since` is never answered, only `If-None-Match` and `If-Range` | every browser and CDN made this century sends an ETag, and two validators are two answers that have to agree | a client that sends only the date |
| A route cannot be scoped by host; `useOn` and `group` scope by path | two processes behind the proxy, which is a good answer | a deployment that cannot put two processes behind the proxy |
| Of Fiber's thirty-two middleware, six are neither queued here nor a typed argument: `favicon`, `responsetime`, `redirect`, `rewrite`, `proxy`, `skip`. Two more are here in another shape: Fiber's `cache` is `nilo.Cached(Space, .{ .ttl_s })` on the route ([ADR 188](./adr/188-a-route-can-say-cache-this-answer-for-a-minute.md)), and its `etag`, a hash of every body, is `nilo.Versioned(T)`, a version the handler names before the body is built ([ADR 189](./adr/189-a-version-a-handler-names-is-an-etag.md)) | each of the six is three to ten lines against nilo's own middleware shape, which is the argument on both sides | an application that wrote one of the six wrong |
| `staticWith(.{ .reload = true })` does not pick up a file made after startup, so a bundler's hashed `app-3f9a1c.js` is a 404 until the server restarts ([guide](./guide/static-files.md#reloading-files-during-development)) | a rescan on a miss would let a request-carried name decide when the disk is walked, which is the traversal `static` refuses; the bundler's dev server with a proxy to nilo covers development (`zig build dev` does not: it restarts on the binary and on nothing else, [ADR 190](./adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)), and a production build is there before the server starts | a design for a rescan that a request cannot trigger |
| `zig build dev` does not restart the server when the front end beside it is saved | by design ([ADR 190](./adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)): the watch is the build's, which reads the `.zig` the binary is built from and what it `@embedFile`s, and a front end has a dev server of its own; `bench/devloop.py` holds it ([guide](./guide/getting-started.md#what-triggers-a-restart)) | nothing on its own: a second path for `nilo-dev` to watch is a second reading of which files matter, which is the design the ADR rejected |
| `spa_fallback` has no list of path prefixes that never fall back (`.except = &.{"/api/"}`) | by design ([ADR 087](./adr/087-a-fallback-answers-a-navigation-not-a-missing-asset.md)): a `fetch` or `curl` at an unknown API path is already a 404 under the `Sec-Fetch-Mode` rule, and a browser address bar is a navigation that is better shown the application's own not-found screen. A path that must never be the page is given a route |
| A connection could start on the executor whose acceptor took it, not round-robin | No. `.local` against round-robin on 2 executors ([`http.md`](../bench/result/http.md#whether-a-connection-should-start-on-the-executor-that-accepted-it)): HTTP/1.1 won 1 to 20%, HTTP/2 keep-alive lost 11 to 53% in all three rounds, because the kernel wakes whichever acceptor it likes and 64 connections split 6 and 58 or 59 and 5 where round-robin deals 32 and 32. | An accept path that spreads connections itself (a listener per executor with `SO_REUSEPORT`, whose own cost would have to be measured), or a kernel that spreads wakes. |
| The `Stream` rebuilt at each HTTP/2 recycle, and the monitor at the end of a stream something else reads, could be cut or made per connection | Neither: as upper bounds (the monitor made a no-op everywhere, the rebuild replaced by thirty field writes) no message row cleared the 20 ns the tree's layout moves it by ([`http.md`](../bench/result/http.md#what-a-stream-costs-to-recycle-and-the-monitor-at-the-end-of-one)). An `Inbox` per connection could not hold two bodies at once without a pool. | A profile in which either is more than about 3% of a request, which would have to come from a change that makes the rest cheaper first. |
| A panic ends every connection the process holds, where Go's `net/http` loses the one request | Zig cannot recover from a panic ([ADR 007](./adr/007-no-recover-middleware.md)), so a panic is contained by the process: a supervisor that starts it again and more than one instance behind the balancer. `nilo.panic` names the request that did it; the warning when a root file lacks it is open in [the todo list](./todo.md), and so is a pre-fork worker mode | a way to contain a panic in less than a process that costs nothing on [ADR 017](./adr/017-the-trade-budget-has-four-axes.md)'s hard axes |
| A CPU-heavy handler holds its thread, where Go preempts a goroutine and steals work | a fiber is cooperative and stays on the thread it was dealt to ([ADR 199](./adr/199-a-connection-is-served-by-the-thread-it-was-dealt-to.md)); CPU work goes to `nilo.blocking`, and the watchdog names a hold past 250 ms ([ADR 013](./adr/013-handlers-must-not-block-the-thread.md)). Showing the shorter holds is open in the todo list | zio or Zig able to preempt a fiber, or work stealing measured to win |
| Two services of the same type, a primary and a replica, cannot both be provided | services are found by type, so each one is a wrapper struct of its own ([ADR 002](./adr/002-typed-handlers-are-a-thin-layer-over-ctx.md)); the type is what keeps a lookup a scan with no names. The refusal's wording and the guide's recipe are open in the todo list | a way to name a service that costs no string compare per request |
| A path param cannot be constrained by a pattern, as chi's `{id:[0-9]+}` is, so `/files/:id` and `/files/:slug` cannot sit side by side | one pattern is one route and a duplicate is refused ([ADR 012](./adr/012-the-most-specific-route-wins-and-duplicates-are-refused.md)); the param's type is its constraint, and a value that does not fit is a 400 | two routes a real API needs that differ only in the shape of a param |
| There is no live profiler like Go's `net/http/pprof` | Zig has no runtime to ask for a heap or a goroutine dump; `perf` against the running binary is the answer, and the metrics page is where a number a program needs to watch goes | a profile a program can take of itself with no runtime under it |
| The default address is `127.0.0.1`, where Go's `":8080"` binds every interface | a server that faces nothing until it is told is the safer default, and a container sets `.address = "0.0.0.0"`. That the deploying guide does not say so is open in the todo list | nothing on its own: the cost is a sentence, and the todo entry pays it |

### `nilo_sql`

| Claim | The answer today | What reopens it |
|---|---|---|
| `db.watching` shows the statement, the plan, the duration and the rows, and not the values it bound ([ADR 108](./adr/108-a-statement-can-be-watched.md)) | the decision rather than the gap: bound values are personal data in a log | a second flag whose name says it puts personal data in a log, designed rather than defaulted |
| `sql.Timestamp` is always microseconds, and the schema check cannot tell an `INTEGER` of milliseconds from one of microseconds | `sql.UnixMillis` and `sql.UnixSeconds` put the unit in the type ([ADR 067](./adr/067-a-value-is-whatever-the-database-stores.md)); what nothing can see is an `INTEGER` column's unit, so it is the schema's to get right | a database that can name the unit of an integer column |
| SQLite stores a `Timestamp` as an integer and there is no way to ask for text ([ADR 067](./adr/067-a-value-is-whatever-the-database-stores.md)) | a `time_form` beside `uuid_form` is the shape, and [ADR 127](./adr/127-what-a-server-prints-it-can-read.md) already gave `Timestamp` the RFC 3339 parser it needs | a caller with a SQLite file whose times are RFC 3339 text |
| An upsert cannot name a constraint (`ON CONFLICT ON CONSTRAINT …`), a partial index (`… WHERE deleted_at IS NULL`) or a `DO UPDATE … WHERE` | `db.raw`, which cannot express `RETURNING` into a Row plus a conflict target without giving up the column check; a constraint name is a string this module would have to take on trust, which is the one place it takes nothing on trust | a caller, and the soft-delete uniqueness case is the one most likely to be it |
| A raw statement has no `sql.given`: a filter a screen may not have set is `($1 IS NULL OR x = $1)` in the text, with the optional bound NULL ([guide](./guide/sql/raw.md#parameters)) | `given` works by dropping a leaf from a condition nilo composes, and a raw statement is text nilo does not compose; the `IS NULL` guard is one plan and correct SQL on both databases | a caller for whom the guard's plan is measurably worse than the two statements it replaces |
| `db.exec` sends its run-time text as written, so `$n` there is SQLite's named parameter and not the numbered one `raw` respells ([ADR 204](./adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)) | its statements are DDL and `PRAGMA`, which have no parameters, and respelling run-time text is an allocation on a path that did not ask for one | an `exec` with parameters that has to run on both databases |
| A Row cannot say `DISTINCT`, a window function other than a page's total, a CTE, a union, a join through a condition rather than a reference, or an aggregate over an expression rather than a column ([ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)) | `db.raw`; each of these is a statement whose shape a field's type cannot say, and the Row stays a description of the answer rather than a second query language | a shape a field can declare that keeps ADR 218's two properties: the Row still describes the answer, and `.limit` still counts what is listed |
| An aggregate's `.where` and a `nilo_children` entry's `.where` take a value, `null`, the six comparisons, `.in` and `.not_in` over the table's own columns and through a reference, `.now` and `.today` moved or not, and nothing else ([ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)) | the values are written into the statement, because the entry is part of the Row and has nothing to bind; a pattern, `.any` or `.exists` goes in the read's own `.where`, or `db.raw` | a filter from a real screen that the read's `.where` cannot carry instead |
| A `numeric` column does not read into an `f64` field, on a narrower Row or anywhere ([guide](./guide/sql/tables.md#a-numeric-that-is-not-money)) | a column type of the program's own, `nilo_column = "numeric(14,3)"` with an `f64` inside, says the rounding once and by name ([ADR 049](./adr/049-a-column-type-can-come-from-outside-this-module.md)); reading `f64` off a field's type would make the rounding a choice each Row makes silently | a `numeric` that a column type of the program's own cannot read |
| A read of children is two statements, and outside a transaction they are two snapshots ([ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md)) | the decision: `tx.select` is the same call and holds, and one statement would be a `LATERAL` with a JSON document parsed back per parent, on Postgres only | a measurement where the second round trip is the cost that matters |

---

## Not coming

Not "later". Decided against, with the reasoning written down. This list is about the repository, so it is what to check before proposing a change, whichever module the change is in.

**Templates.** nilo is for building APIs and services, and rendering a page is the thing it is not for. Two arguments point the same way. Rendering means producing a string per request, which is an allocation per request, which is the one axis [ADR 017](./adr/017-the-trade-budget-has-four-axes.md) treats as a hard invariant rather than a budget: the 4,669 bytes and the single allocation are what nilo has to sell, and a template layer spends both. And the two shapes Zig actually offers are far apart with nothing argued for in between, comptime-checked templates being a compiler of their own and runtime string interpolation being a worse `std.fmt`. [jetzig](https://www.jetzig.dev/) is built for that job and does it with zmpl, which is a better outcome for everybody than a second half-answer here.

A `<form>` posted to a handler still works. [`examples/forms`](../examples/forms/) is that, and `Bound(Form(T))` is what makes its failures legible ([ADR 034](./adr/034-a-binding-hands-its-failures-to-the-handler.md)). **This is a refusal of templates, not of everything on that side of the line.** Whether some other convenience from the batteries-included world earns its place gets decided one feature at a time, against the two numbers above.

**A serialiser for anything but JSON: XML, CSV, MsgPack.** (Protobuf was in this list. It is a module now, [`nilo_proto`](./reference/proto.md), because the codec is something a caller imports and calls on the struct they wrote, not a format nilo applies to a response by a rule it picked: [ADR 245](./adr/245-protobuf-is-read-from-the-struct-that-declares-it.md).) Gin ships four and Fiber three, and nilo ships a declaration instead: a type carrying `nilo_content_type` and `nilo_write` goes out as whatever it writes, under its own label, and the document names it ([ADR 157](./adr/157-a-type-can-write-its-own-answer.md)). What is refused is the reflection — a struct turned into XML elements by a rule nilo picked — because XML has namespaces, attributes and a dozen date encodings, and the consumer who needs XML is by definition the one who will not change to suit nilo's pick. The same goes for CSV's quoting and MsgPack's schema. The bytes are the caller's; the label and the description are what nilo adds.

**A config file parser: TOML, YAML, or any other.** `nilo_config` reads the environment and hands `Fixed` to a program that has parsed something itself ([ADR 039](./adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). Writing one means weeks to reach where somebody else already is, and depending on one means every project importing the module fetches it. For TOML that somebody is [sam701/zig-toml](https://github.com/sam701/zig-toml): about 2,000 lines, arena-backed, already on 0.16's `std.Io`. For YAML there is no finished answer to depend on, and that is the argument rather than a gap. [kubkon/zig-yaml](https://github.com/kubkon/zig-yaml) skips 322 of the roughly 400 cases in the official suite, written by a Zig core contributor, and a partial YAML parser misreads real files quietly instead of refusing them.

`config.Dotenv` is not the exception it looks like. It takes *text*, opens no file, and needs no dependency at all ([ADR 039](./adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). What the module refuses is the filesystem, and a format whose parser somebody else has to maintain.

**A `recover` middleware.** Zig cannot recover from a panic at all, so there is nothing to build ([ADR 007](./adr/007-no-recover-middleware.md)).

**TLS in the default build, HTTP/2 in the default build, and gRPC in the default build.** Terminated in front, and that is the answer rather than the plan ([ADR 027](./adr/027-tls-is-terminated-in-front.md)). Zig's standard library can be a TLS client and not a TLS server, nobody in the comparison wrote their own, and the two alternatives are a one-person crypto dependency or a C toolchain in the install story. HTTP/2 and gRPC were said out loud because nobody derives them from "no TLS". `Ctx.clientIp()` and `.trusted_hops` are this decision's other half. **What was reopened, once, is the default**: a build that passes `.tls = true` gets a TLS 1.3 listener on the one-person library, for the server that has nothing in front of it, and every build that does not contains none of it ([ADR 212](./adr/212-tls-is-an-option-a-build-asks-for.md)). The trust argument is unchanged; the memory argument turned out to be a design choice, since the record buffers go back at idle like everything else. **What moved the second time is gRPC**, because it runs over h2c, which needs no TLS, so the derivation above never covered it: a build that passes `.http2 = true` answers unary calls over h2c on any plain listener, beside HTTP/1.1 on the same port, and a method is an ordinary `app.post` route ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)). **What moved the third time is HTTP/2 for browsers and ordinary routes**: a build that passes both `.tls = true` and `.http2 = true` has a TLS listener that offers `h2` and `http/1.1` by ALPN and serves every route on either ([ADR 259](./adr/259-http2-is-a-framing-of-every-request.md), [ADR 027](./adr/027-tls-is-terminated-in-front.md)). The default build still has neither, and a proxy is still the recommendation for a server on the internet.

**A gRPC call run on the connection's own fiber.** Four times the throughput, measured, and refused: a gRPC client puts every call on one connection, so one slow call would hold the rest, and the connection's own PINGs, behind it. The cost it would have saved is the scheduler's rather than the fiber's, and is asked of zio instead ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)).

**HTTP/3 and QUIC in the binary.** Terminated in front, by the CDN or the proxy that is already there. HTTP/2 came in because a protocol nilo serves needed it: gRPC runs over h2 and over nothing else ([ADR 220](./adr/220-grpc-is-served-over-h2c-behind-a-flag.md)), and the server half then cost little more for every route ([ADR 259](./adr/259-http2-is-a-framing-of-every-request.md)). Nothing nilo serves needs QUIC, and QUIC is a transport rather than a framing: UDP, its own TLS handshake inside it, and loss recovery and congestion control in user space, none of which the Engine has. It is written here so that it is not derived from "HTTP/2 was refused and then built". What would reopen it is a protocol a caller needs nilo to serve that runs over QUIC only, WebTransport being the likely one.

**An ORM.** `nilo_sql` is not one and the name is the promise. No change tracking, which costs a copy of every row. No lazy relations, which are queries nobody wrote. No identity map, which is a lifetime problem in a language with no garbage collector ([ADR 036](./adr/036-the-shape-of-a-query-is-settled-while-compiling.md)).

**Auth contents.** The mechanism is provided, in middleware and resolved values. The policy is yours.

**socket.io's wire protocol.** A Room is WebSockets, and a socket.io client speaks a protocol of its own on top of them (its own handshake, packet types, acknowledgements and a long-polling fallback), so it talks only to a socket.io server. Speaking it would make nilo carry another project's protocol and follow its versions. What a socket.io user wants from it, a room, a message to everybody in it, and a reconnect that catches up, is a Room with history ([ADR 229](./adr/229-a-room-that-keeps-history-catches-a-returning-stream-up.md)). What would reopen it is a front end that cannot change its client.

**Benchmark claims without a benchmark machine.** A figure gets published only alongside what it does *not* mean, and alongside the fact that a handler touching a database flattens the whole comparison ([ADR 017](./adr/017-the-trade-budget-has-four-axes.md)).

---
