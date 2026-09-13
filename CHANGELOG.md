# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Needs Zig 0.16, as 0.3.0 does. Each entry says what you have to change; the
account of why is in the ADR it links.

One module, and the thirty-odd things a real port hit, in the order they cost
it the most. `nilo_job` is the queue the port had written by hand — a job is a
struct, the table is in the database you already have, and a schedule makes
you choose what an overlap means. The rest are shapes the port needed and found
missing — a page that knows its total, a filter that is absent, a header as a
typed argument, a health page the balancer can trust, a route that answers
once per `Idempotency-Key` — and the seven fixes it found underneath them,
two of which are the reason `zig build test` runs on a Mac at all.

### New

- **`nilo_job`: a queue in the database you already have, and a schedule.**
  The eleventh module, and the second Fitting
  ([ADR 0198](./docs/adr/0198-a-queue-is-a-table-in-the-database-you-already-have.md),
  [ADR 0199](./docs/adr/0199-a-schedule-is-a-type-that-makes-the-caller-choose.md)).
  A job is a struct: its fields are the payload, `run` is the work, and every
  pointer after the Run is a service the queue was handed at `open`.

  ```zig
  const SendWelcome = struct {
      pub const nilo_job = "send-welcome";
      pub const retry: job.Retry = .{ .times = 5, .backoff = .{ .exponential = .{ .from_ms = 1_000, .to_ms = 3_600_000 } } };

      user_id: u64,
      email: Str,

      pub fn run(self: SendWelcome, scope: *nilo.Run, mail: *Mailer) !void {
          try mail.send(scope, self.email, "Welcome");
      }
  };

  const Jobs = job.Jobs(.{ .kinds = .{ SendWelcome, Nightly }, .store = job.Table(sql.Db), .deps = struct { mail: *Mailer } });
  ```

  `jobs.push(c, SendWelcome{ … }, .{})` from a handler, `jobs.pushIn(&tx, c, …)`
  inside the transaction that made the work, `.after_ms` and `.at` for later,
  `.unique` for at most one queued-or-running row per key. `Jobs.Row` goes in
  `db.checking` and the migration like any other table; several servers share
  it through `FOR UPDATE SKIP LOCKED`, a worker that dies gives its row up
  when the lease runs out, and a failed `run` is retried the way the job said
  and then is dead, with the error's name kept. **At least once**: write `run`
  so that running it twice is safe.

  A schedule is a job with three more lines, and two of them have no default:

  ```zig
  pub const schedule = job.cron("0 3 * * *");   // UTC, parsed while compiling
  pub const overlap: job.Overlap = .skip;       // or .queue
  pub const missed: job.Missed = .drop;         // or .catch_up
  ```

  `job.Memory` is the same contract in this process, for a test or for a
  program that can lose its queue at a restart — full is `error.QueueFull`,
  never an overwrite. `jobs.drain(&run)` runs everything due on the calling
  thread, which is the whole of a test. A `cache.Space` of `job.Status` keeps
  a state per row for a route to poll, and one of `job.Mark` in front of a
  `.unique` key is a window: "at most one of these every thirty seconds".

  `app.provide(&jobs)` and `app.spawn(Jobs.serve, .{&jobs})` start the
  workers under the server; `jobs.serveOn(io)` is the same loop for a worker
  process with no server in it. Twelve Refusals, `zig build test-job`,
  `test-job-sql`, `bench-job`, and a page: [`docs/guide/jobs.md`](./docs/guide/jobs.md).
  **Nothing changes for a program that does not import it.**

Six of them came from the same port a week later, once it had used the first
eleven and reached its first hard seam — an event bus. One more it reported —
five places where it wrote the untyped call while a typed one existed, with no
error message behind any of them — is a named failure mode rather than a change:
[ADR 0168](./docs/adr/0168-an-escape-hatch-that-costs-nothing-teaches-nothing.md).

**Eight of them are that lesson applied on purpose.** The port built nothing new
for them: it put one question to the 6,281 lines it already had — *what does nilo
make us write* — and eight answers came back. Seven have no error message behind
them at all. Every one of those compiled, passed and read as ordinary code, which
is the only reason they took a sweep to find.

**The last five are what happened when it tried to use them.** One is a feature
that shipped and could not be used at all by the product it was written for, and
finding that out took the port half an hour and a `git revert`. The other four
are the ordinary list endpoint — a search box, a dropdown, and a count beside the
rows — which turned out to be four gaps that only close together.

- **`app.health("/healthz")` — a page that says whether this process can do
  its job, by asking the services that know**
  ([ADR 0192](./docs/adr/0192-a-health-route-asks-the-services.md)).
  `200 {"status":"ok"}`, or `503` naming each service that is not ready and
  why, or `503 {"status":"stopping"}` from the moment the server was told to
  stop — so a balancer drains the instance before its listener closes. A
  service joins in with `pub fn nilo_ready(self: *T, scope: *nilo_core.AnyScope)
  ?[]const u8`: null is ready, a sentence is why not. **`sql.Db` sends
  `SELECT 1` down the pool**, which is what turns a server started with
  `connect_on_init = 0` over a database that is down into a 503 rather than a
  200 over an empty pool; an `s3` Store answers whether it started. Nothing
  per request that is not the probe; one arena allocation for the page.
  `c.stopping()` is the flag it reads, public now. One refusal: a `nilo_ready`
  of the wrong shape.

- **`nilo.Idempotent(Replays, .{ .by = account })` — the `Idempotency-Key`
  header as a typed argument, and with it the route answering once per key**
  ([ADR 0193](./docs/adr/0193-a-request-answered-once-is-answered-the-same-way-again.md)).

  ```zig
  const Replays = cache.Space("orders-replay", []const u8, .{ .ttl_s = 86_400, .max_bytes = 16 << 10 });

  fn placeOrder(key: nilo.Idempotent(Replays, .{ .by = account }), body: NewOrder, …) !nilo.Status(201, Order)
  ```

  The first request with a key runs the handler and keeps what it returned;
  every retry with that key gets it back, byte for byte, with
  `Idempotent-Replayed: true`, and the handler does not run. No key is a 400,
  a key still being answered is a 409, a key reused on a different request is
  a 422. What the handler *failed* with is not kept, so a retry after a
  failure runs it again. `Replays` is a `nilo_cache` bytes Space — or any type
  with the same six declarations — provided as a service; `.by` is whose key
  it is. In the document, a required header and the two extra answers. On the
  route that asks: one arena allocation to encode, one of `max_bytes` to
  replay, nothing on the stack. Four refusals: not a bytes Space, the key
  asked for twice, a handler that returns nothing, one that returns a file or
  a redirect. [Answering once](./docs/guide/idempotency.md) is the page.

- **`nilo.Authorization(.bearer)` and `nilo.Authorization(.{ .basic = "realm" })`
  — the `Authorization` header as a typed argument, refused with the challenge
  a 401 has to carry**
  ([ADR 0191](./docs/adr/0191-an-authorization-header-a-handler-can-ask-for.md)).
  The scheme is matched case-insensitively, which RFC 9110 says it is, and
  absent or another scheme is a 401 with `WWW-Authenticate: Bearer` or
  `Basic realm="…"` on it — the header every 401 has to carry and the one both
  hand-written copies in this repository left off. Basic is decoded and split
  at the first colon into `.user` and `.password`.

  ```zig
  fn me(auth: nilo.Authorization(.bearer), issuer: *const Issuer) !Profile   // auth.value
  fn admin(auth: nilo.Authorization(.{ .basic = "admin" })) !void            // auth.user, auth.password
  ```

  `T.refuse("…", .{})` is `fail.unauthorized` with the same header, for the
  refusal after reading; `c.authorization(.bearer)` is the same read from a
  resolver. In the OpenAPI document, a `security` entry and a 401 rather than
  a parameter. Bearer allocates nothing; Basic decodes into the arena once; a
  connection weighs what it weighed, because the challenge sits in padding
  `Failure` already had. Two refusals: an empty Basic realm, and one with a
  quote in it. **What to change**: nothing — but a `startsWith(value,
  "Bearer ")` in a resolver is now three lines shorter and right.

- **`nilo.FromHeader("X-Staff-Id", T)` — one request header, as a typed
  argument** ([ADR 0163](./docs/adr/0163-a-header-a-handler-can-be-given.md)).
  The same family as `Query(T)` and `Form(T)`, converted the same way, and —
  the point — **written into the API description**, so a generated client knows
  the endpoint needs it. `c.header` read one and appeared nowhere.

  ```zig
  fn addComment(actor: nilo.FromHeader("X-Staff-Id", Uuid), body: NewComment) !Comment
  ```

  Absent is null for a `?T` and a 400 naming the header for anything else. It is
  `FromHeader` rather than `Header` because `nilo.Header` is the response side.

- **`nilo.maxBody(bytes)` — how much body a route takes**, as a middleware on
  `with`, the way `nilo.deadline(ms)` is for time
  ([ADR 0194](./docs/adr/0194-a-route-can-say-how-much-body-it-takes.md)).
  `listen()`'s `max_body` used to be the one number for every route, so a
  server with a 50 MB import had told its sign-in route to hold 50 MB too.
  Bounds every read into the arena — `c.body()`, a JSON body, a `Form(T)` —
  and not `c.bodyStream()`, which keeps its own `max_bytes`. Costs one store
  into a field the `Ctx` already had; `maxBody(0)` is a compile error.
  `c.giveBodyLimit(bytes)` is the same thing from a middleware of your own.

- **`listen(.{ .max_in_flight = 256 })` — a server past its limit says so at
  once.** Past that many requests being answered, the next one is a `503`
  with `Retry-After: 1` and `Connection: close` before it is routed, rather
  than a place in a queue behind the pool
  ([ADR 0197](./docs/adr/0197-a-server-past-its-limit-says-so-at-once.md)).
  Off by default, and off costs one comparison on a value the request path
  already had — the count a shutdown waits on. Counted under a fifth
  fixed slot, `<shed>`, on the metrics page; pick the number from
  `nilo_requests_in_flight` there. Requests, not connections:
  `max_connections` is still the other one.

- **A type can write its own answer.** Give a struct
  `pub const nilo_content_type = "application/xml";` and
  `pub fn nilo_write(self: T, w: *std.Io.Writer) !void`, return it from a
  handler, and it goes out as whatever it wrote under that label — bare, in a
  `?`, in a `Status(201, …)`, in a `Response(…)`, or kept by an `Idempotent`
  route ([ADR 0195](./docs/adr/0195-a-type-can-write-its-own-answer.md)). The
  document names the content type, and describes the body with the type's
  `nilo_openapi` when it has one. Costs what a JSON answer costs — the same
  arena buffer — and links nothing in a program with no such type. Five
  refusals cover the pair written wrong: one declaration without the other,
  an empty label, a label with a control character in it, a `nilo_write` of
  another shape. What nilo does *not* do is reflect a struct into XML, and the
  roadmap's [Not coming](./docs/roadmap.md#not-coming) now says why; the
  question of answering anything but JSON, open since the roadmap was
  written, is closed.

- **`app.writeOpenApi(w)` — the API description, with no server**
  ([ADR 0167](./docs/adr/0167-the-document-is-a-build-artefact.md)). The
  document was reachable only from `GET /openapi.json` on a listening server,
  and `listen` runs `db.checking` — so producing the file a typed frontend
  client is generated from needed a **migrated database**. Called after the
  routes are registered and before `listen`, this needs no port, no database and
  no network, which makes `zig build openapi > openapi.json` an ordinary build
  step. The served copy goes through the same call, so a checked-in file and a
  running server cannot describe two different APIs.

- **A query parameter can be a list**
  ([ADR 0164](./docs/adr/0164-a-query-parameter-that-is-a-list.md)).
  `tag: []const Str = &.{}` in a `Query(T)`, elements of any type a query value
  can become — so a list of enums is refused with a 400 before the handler runs
  and its values are in the document.

  **Both spellings are read** — `?tag=a,b` and `?tag=a&tag=b` — and the document
  says which one nilo would write, as `style: form, explode: false`. A server
  that reads only one of them answers with fewer rows, which looks exactly like
  a filter that worked. Absent is the empty list, so a list field is never
  `required`.

- **A `Query(T)` or `Form(T)` field can be a type that parses itself**
  ([ADR 0158](./docs/adr/0158-one-arrival-one-answer.md)). `/deals/:id` read a
  `sql.Uuid` and `?actor=<uuid>` refused one, off the same request line. Now
  both work; `tryConvert` had handled the case since ADR 0142.

- **A struct can say how its field names are spelled on the wire**
  ([ADR 0181](./docs/adr/0181-a-field-name-is-a-spelling-too.md)). `rename_all`
  renamed an enum tag and a union variant and stopped at field names, so the port
  carried 10 response structs, 77 fields, 5 mapping functions written out field
  by field and 5 arena loops — and the whole job of all of it was `full_name`
  becoming `fullName`. Nothing held a Row field against the DTO field carrying
  it, so a column added to a Row reached the wire only if somebody remembered a
  second file.

  ```zig
  const Contact = struct {
      pub const nilo_json = .{ .rename_all = .camelCase };

      id: u32,
      full_name: []const u8,   // "fullName"
  };
  ```

  The API description says the same keys, and it costs nothing per request — the
  name is a comptime string either way.

  **What you have to change: nothing, unless you were using one type in both
  directions.** This is a spelling for what goes *out*. `std.json` chooses the
  parser for a body and reads it into the field names as they are written, so a
  renamed struct used as a request body, a form or a query string is now a
  compile error naming the route — that route would have documented `fullName`
  and answered 400 to a client that sent it. Give what comes in a struct of its
  own.

  A renamed struct that nilo's own writer cannot reach is refused too. One shape
  it does not recognise — a tuple, an array of bytes, an untagged union, a type
  with its own `jsonStringify`, anything past eight deep — sends the whole value
  to `std.json`, which does not read the marker; the keys would go out unrenamed
  while the document promised otherwise.

- **A type that writes its own JSON and says what it looks like is a leaf now,
  not a wall**
  ([ADR 0182](./docs/adr/0182-a-leaf-that-says-what-it-is-can-be-carried.md)).
  **You get this without asking, and it is the largest of the five.** `covers`
  refused any type carrying `jsonStringify`, and it is answered for the *whole*
  value — so one `sql.Uuid`, `sql.Timestamp`, `sql.AsText` or `id.Uuid` anywhere
  in a response sent the entire struct to `std.json`, strings included. A port
  with 145 uuid columns had no response on the fast path at all.

  A type carrying `nilo_openapi` beside `jsonStringify` has already promised its
  JSON is one scalar, which is the promise the writer needs to keep writing the
  object around it. So the leaf goes to `std.json` and the rest does not:
  **250ns → 165ns on a 305-byte contact row with three uuids in it**, byte-for-
  byte identical output ([`bench/result/http.md`](./bench/result/http.md)).

  It also reopens `rename_all` on a struct, which is what reported this. Every
  response in that product held a uuid, so ADR 0181's fallback refusal fired on
  every one of them — correctly, and it made the feature unusable. `jsonStringify`
  with no `nilo_openapi` beside it is still a wall, and still refused.

- **A value can reach the bottom of the call stack**
  ([ADR 0165](./docs/adr/0165-a-value-that-reaches-the-bottom.md)).
  `nilo_resolve` arrives as a handler argument, which is the top; an audit row
  assembled sixty calls down had nowhere to read it from. Both scopes answer
  `resolve` now, so one function body works either way:

  ```zig
  const actor = try scope.resolve(Actor);   // a *Ctx or a *Run
  ```

  Under a request that is the declared resolver, unchanged. A tick is told
  once — `try run.give(Actor, .{ … })` — and `run.resolve` answers
  `error.NotGiven` rather than null, because the failure this exists for is an
  audit column that is quietly NULL. **This is not `c.locals`**: nothing was
  added to `Ctx` and ADR 0016 stands.

- **`nilo.AnyScope` — a Scope that can cross a function pointer**
  ([ADR 0177](./docs/adr/0177-a-scope-that-crosses-a-function-pointer.md)). Zig
  has no closures, so a bus, a queue or a job registry stores a callback as a
  function pointer — and one cannot be generic over the Scope it runs under while
  still running under a request *and* under a `Run` in a test. The port wrote 57
  lines of pointer-and-vtable for it, and so would anything else with a bus.

  ```zig
  var erased = nilo.AnyScope.of(c);   // or `.of(&run)`
  try reaction(&erased, payload);
  ```

  It passes the Scope check, so a reaction can query. **The ordinary Scope is
  unchanged**: ADR 0041 stands, every call still takes `anytype`, and the vtable
  is paid for only where somebody erases one.

- **`nilo.Run` can mint a key**
  ([ADR 0160](./docs/adr/0160-a-scope-that-can-mint-a-key.md)). nilo's own
  refusal says *pass the `*Ctx` the handler was given, or a `nilo.Run` if there
  is no request* — and `entropy` was on `Ctx` alone, so every service function
  that creates something failed to compile under a `Run`.

  ```zig
  var run = nilo.Run.initIo(gpa, io);   // and `entropy` works
  ```

  `Run.init(gpa)` is unchanged and answers `error.NoIo` from `entropy`.

- **`id.v7Now(scope)` — a key from the Scope in hand**
  ([ADR 0176](./docs/adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)).
  Minting one was two lines and a cast, six times in one context, and neither
  half is a decision a caller makes:

  ```zig
  const key = try id.v7Now(c);   // was: id.v7(try c.entropy(…), @intCast(nilo.nowMillis()))
  ```

  `id.v7(entropy, ms)` stays, for a key at a time you chose. On a `Run` built by
  `init` rather than `initIo` this is `error.NoIo`.

- **A `Uuid` prints with `{f}`** (same ADR). Every refusal that named the record
  it could not find was `{s}` with `&id.toText()`. `writeText` is a method, so it
  answers a writer you already hold and answers nothing to a format string;
  `format` is what `{f}` looks for.

  ```zig
  return nilo.fail.notFound("partner {f} not found", .{id});
  ```

- **`entropyInto(buf)` on `Ctx` and `Run`**
  ([ADR 0166](./docs/adr/0166-entropy-a-function-pointer-can-carry.md)).
  `entropy` answers `![n]u8` with `n` comptime, and a **function pointer** has to
  name one return type — so a Scope type-erased to cross one carries exactly one
  width. Zig has no closures, so erasing a Scope is what storing a callback comes
  to. Same bytes, same wait; `entropy` is now written in terms of it.

- **`Str.blank()` and `Str.trimmed()`**
  ([ADR 0175](./docs/adr/0175-required-text-arrives-as-two-spaces.md)).
  `std.mem.trim(u8, s.view(), " \t\r\n").len == 0` was written eight times in one
  context, with the charset spelled out in six of them. Required text arrives as
  `"  "` in the ordinary case rather than the rare one, and a copy that drops
  `\n` accepts a comment whose whole body is a newline — a required field that
  every screen renders as empty, with nothing failing. The set is
  `std.ascii.whitespace`. A read of the bytes, not a validation rule.

- **`nilo_sql`: six shapes a listing page needed, and one of them was a wrong
  answer rather than a missing one.** Each is a widening of a shape that was
  already there, and all six cost nothing on ADR 0018's four axes — every one is
  comptime string concatenation and the parameter tuple it was already sending.

  - **`contains`, `starts_with`, `ends_with`, and their folding and negated
    spellings** — twelve operators in all
    ([ADR 0173](./docs/adr/0173-the-database-escapes-the-pattern-it-is-going-to-match.md)).
    **Change your search boxes.** `.name = .{ .like = term }` never escaped the
    caller's text, so a term holding `%` matched far more than it should and one
    holding `_` matched a character it should not — no error, and only on the
    input nobody tried. The pattern is now built and escaped inside the
    statement, so this costs no allocation:

    ```zig
    .where = .{ .name = .{ .icontains = search } }
    ```

    On SQLite the case-sensitive half (`contains`) is a Refusal naming the
    dialect, because its `LIKE` folds ASCII case and cannot be told not to by a
    statement. `icontains` is what that database does.

  - **A key can span several columns**
    ([ADR 0172](./docs/adr/0172-a-key-is-as-many-columns-as-it-takes.md)).
    `.key = .{ .tenant_id, .id }`, and `db.find` then takes a struct naming
    every column of it — named rather than positional, because two `i64` columns
    written the other way round would find the wrong row and say nothing.
    `updateMany` joins on all of them, and `CREATE TABLE` writes a
    `PRIMARY KEY (…)` constraint.

    **Breaking, and it is the snapshot:** `table.Desc.key` became `Desc.keys`, so
    a `.zon` snapshot written by an older `generate` no longer parses. Run
    `db generate` to rewrite it from your types.

  - **`.exists` and `.not_exists`**
    ([ADR 0171](./docs/adr/0171-a-row-over-there-is-a-condition.md)) — the first
    time the *one table* line has moved, and it moved to where the two
    properties behind it actually hold. The join comes out of the child Row's
    own `.references`, so there is nothing new to write at the call site:

    ```zig
    .where = .{ .exists = .{
        .{ .in = PartnerCapability, .where = .{ .capability = cap } },
    } }
    ```

    `exists` and `not_exists` are now reserved column names, beside `any`. A Row
    with a column called either is refused by name.

  - **`sql.Bytes` — a `bytea` and a `BLOB`**
    ([ADR 0174](./docs/adr/0174-bytes-are-a-type-not-a-second-protocol.md)). A
    file hash, a sealed token, a signature. `sql.AsText("bytea")` still works and
    is now the wrong answer: it goes through Postgres's hex printing and costs a
    conversion each way.

  - **`.set = .{ .views = .{ .plus = 1 } }`** — arithmetic on the column's own
    value, so an atomic counter is one statement. Without it the shape everybody
    reaches for is read-modify-write, which is two round trips and races unless
    it is wrapped in a transaction with `.lock = .update`. `plus` and `minus`
    only, on a column holding a number; a nullable one is a Refusal, because
    `views = views + 1` on a NULL stores NULL and reports one row changed.

  - **`.order = .{ .rank = .asc_nulls_last }`** and its three siblings. Postgres
    sorts NULLs last ascending and SQLite sorts them first, so a Row ordered on a
    nullable column already answered differently on the two and nothing said so.
    `.asc` and `.desc` still mean *the database's own default*, so every order
    term you have written compiles to the same SQL it did.

- **A filter that is absent is not a filter that is null: `sql.given`**
  ([ADR 0183](./docs/adr/0183-a-filter-that-is-absent-is-not-a-filter-that-is-null.md)).
  A condition still cannot hold an optional — a null reaching `= $1` matches
  nothing and says nothing, which is ADR 0044 and is not moving. What could not
  be spelled is the other question, *no condition on this column at all*:

  ```zig
  .where = .{
      .name = .{ .icontains = sql.given(filter.search) },
      .status = sql.given(filter.status),
  }
  ```

  ```sql
  ($1 IS NULL OR "name" ILIKE '%' || $1 || '%') AND ($2 IS NULL OR "status" = $2)
  ```

  **One statement, one parameter list, one prepared plan**, however the screen is
  set — the alternative, one statement per combination of filters, is 2ⁿ of each
  and a plan cache that thrashes as somebody clicks the dropdowns. Two optional
  filters used to be four arms of `db.select` beside four of `db.count`.

  Inside an `.exists` it drops the whole subquery rather than one term of it,
  because dropping the term would leave the subquery asking whether *any* joined
  row exists — which excludes every row that has none. It is refused beside a
  fixed condition in the same `.exists`, inside `.any`, on `.in`, on
  `not_distinct_from`, on a value that is not optional, and in the condition of
  an `UPDATE` or a `DELETE`.

- **`db.page` — a page and its total in one statement**
  ([ADR 0185](./docs/adr/0185-a-page-knows-what-it-left-out.md)).

  ```zig
  const found = try db.page(Order, c, .{
      .where = .{ .status = "open" },
      .order = .{ .id = .asc },
      .limit = 20,
      .offset = page * 20,
  });
  // found.rows is []Order, found.total is every order that matched.
  ```

  The documented shape was `db.count` beside `db.select`, and the round trip is
  the smaller half of what is wrong with it: **two statements against a table
  somebody else can write between**, so the screen says "20 of 47" while holding
  20 of 46 and nothing says so. `count(*) OVER ()` rides on the page and cannot.
  One integer read per statement, not per row.

  `.limit` and `.order` are both required and `.lock` is refused — a page with no
  ceiling is the whole table, a page with no order can hold one row twice across
  two requests, and `FOR UPDATE` beside a window function is a run-time error
  from Postgres. `tx.page` is the same call inside a transaction.

  **With `sql.given` this is the ordinary list endpoint in one typed call**, and
  the two only pay off together — either alone leaves the query raw.

- **`db.rawOne` and `db.updateReturningOne`**
  ([ADR 0179](./docs/adr/0179-a-statement-with-a-key-in-it-has-a-single-row-answer.md)).
  `db.one` is the typed select's answer to *this row or none*; `raw` and
  `updateReturning` had none, so a statement with a primary key in its `WHERE`
  ended in the same unwrap six times in four files:

  ```zig
  const found = try db.raw(Card, c, card_sql, .{id});
  return if (found.len > 0) found[0] else null;
  ```

  Both answer `!?T`, which is already a 404 in the typed layer, and both exist on
  a `Tx`. **`rawOne` adds no `LIMIT 1`** — this module did not write the
  statement and has nowhere honest to put one — so it is a shorter unwrap rather
  than a cheaper query.

- **`.key` as a conflict target**
  ([ADR 0186](./docs/adr/0186-a-key-is-named-once.md)).

  ```zig
  try tx.insertOrIgnore(rows.StaffRole, c, .{ .staff_id = id, .role = role }, .key);
  ```

  A Row has named its key since ADR 0172 and the call site spelled the same tuple
  a second time. The two could disagree, and the way they disagree does not fail:
  a key that gains a column and a call site that does not is a statement
  conflicting on the **old** columns, which inserts a duplicate where it used to
  ignore one. Spelling the columns out still works and is still right for what
  the reference says it is for — a unique index that is not the key. A Row with a
  column called `key` is a Refusal naming both readings.

- **A caller can read what the database said about its own statement**
  ([ADR 0184](./docs/adr/0184-a-failure-belongs-to-the-call-that-caused-it.md)).
  **Breaking if you catch `error.ConstraintViolated` for a foreign key.** Class
  23 arrived as one word for a race, a check somebody wrote and a null the code
  should never have sent. Three of them are named now:

  | | |
  |---|---|
  | `23503` | `error.ForeignKeyViolated` |
  | `23502` | `error.NotNullViolated` |
  | `23514` | `error.CheckViolated` |

  `error.AlreadyExists` (`23505`) is unchanged and is still the only one with a
  default status. `ForeignKeyViolated` deliberately has none: it is a 409 for a
  delete that lost a race and a 400 for an insert naming a parent that was never
  there, and nothing in `http/` can tell those apart. Both Wires answer the same
  word — SQLite's extended result codes name all three natively.

  `sql.problem(c)` is the other half, for the question a name cannot answer:
  *which* unique index fired.

  ```zig
  db.delete(Staff, c, .{ .where = .{ .id = id } }) catch |err| switch (err) {
      error.ForeignKeyViolated => return fail.conflict(
          "{s} was given something to do a moment ago and can no longer be deleted.",
          .{name},
      ),
      else => return err,
  };
  ```

  It belongs to the call rather than to the `Db`, which is shared by every
  request in flight: it is bound to the fiber, cleared by every statement, and
  answers null to a Scope that is not the one the failure happened under. Read it
  in the `catch`; it lives as long as the request does.

- **`pub const nilo_table = .projection;` — a Row that owns no table**
  ([ADR 0155](./docs/adr/0155-a-row-that-owns-no-table.md)). A `UNION ALL`, a
  `GROUP BY` rollup or a card joining four tables is a shape no table has, and
  had to name one anyway to get past `assertRow`. `db.raw` and `tx.raw` fill a
  projection; everything that writes its own SQL refuses it by name — including
  `db.checking`, which used to take the decorative name at its word and go
  looking for a column of a table nobody meant.

- **`.managed = false` — a table this program reads and does not build**
  ([ADR 0162](./docs/adr/0162-a-table-this-program-reads-and-does-not-build.md)).
  A `.references` names the Row that owns the table, so a foreign key onto
  `staff` needed a `Staff` Row — and the migration tool then wanted to create
  `staff`. That made it all-or-nothing on a schema you own part of.

  ```zig
  pub const nilo_table = .{ .name = "staff", .managed = false };
  ```

  `plan`, `createMissing` and `generate` skip it; `db.checking` still holds it
  against the live schema. The snapshot records it, so a program that starts
  building one is a visible line in the file rather than a silent change.

- **`sql.Timestamp` reads RFC 3339 back**
  ([ADR 0159](./docs/adr/0159-what-a-server-prints-it-can-read.md)). It wrote
  one and could not read one, so every keyset cursor — a value the same server
  printed a request ago — needed a parser of the caller's own, and a parser that
  disagrees with the writer pages past rows silently. An offset and fractional
  seconds are accepted; **a time with no zone is refused**, because guessing UTC
  moves the page by hours at a customer who is not in it.

- **`nilo_cache`: `space.putIfAbsent(key, value)` and `space.getInto(key, buf)`.**
  The first stores only if the key is free and says whether it did — one shard
  lock around the scan and the write, so two callers racing get one `true`
  between them; `put` compiles to what it was. The second reads into a buffer
  of your choosing rather than a `Held`, for a caller whose buffer is an arena.
  Both exist because `Idempotent` needed them, and both are ordinary API.

- **`nilo.testing.show(value)` — a failure message somebody can read**
  ([ADR 0169](./docs/adr/0169-a-failed-assertion-that-can-be-read.md)).
  `std.testing` prints with `{any}`, which is the specifier that skips a type's
  own formatter, so a `Uuid` prints as sixteen decimal numbers and a
  `[]const u8` as its bytes. `show` renders as JSON into whatever writer is
  formatting it — `{f}` — allocating nothing:

  ```zig
  errdefer std.debug.print("row: {f}\n", .{nilo.testing.show(row)});
  ```

  A renderer rather than an assertion, so it works in `expect`, in
  `expectError`, and in a `std.debug.print` while you are poking about.

- **`answer.json(T, arena)` and `nilo.testing.Wired`**
  ([ADR 0180](./docs/adr/0180-a-response-is-read-back-the-way-it-was-written.md)).
  An `Answer` handed back bytes, so pulling one field out of a create meant
  reaching for `std.json` and walking a `Value`. nilo already decided how the
  value was written:

  ```zig
  const made = try answer.json(struct { id: []const u8 }, arena);
  ```

  It de-chunks first and copies into the arena; `answer.bytes(arena)` is the raw
  half. Unknown fields are ignored, which is the opposite of the rule on the way
  in and deliberately so. `Wired` holds an `App` and a `Client` together —
  `wired.app` stays a plain field, so routes and services are registered exactly
  as before and no database is assumed.

- **`nilo.testing.Refusals` — read a fail function's status and sentence outside
  a request**
  ([ADR 0161](./docs/adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)).
  With no request in flight the status and the message were dropped, so a
  service function refusing four ways was four identical `error.Failed`s. Driving
  the endpoint with `testing.Client` was the answer and is not one for a
  function a CLI or a seed calls.

### Read this before deploying

Four things change what a running program does. None needs a line changed to
build; two may need one to keep behaving the same.

- **`error.ConstraintViolated` is three errors now.** A foreign key is
  `error.ForeignKeyViolated`, a null is `error.NotNullViolated`, a check is
  `error.CheckViolated`; `error.AlreadyExists` is unchanged. A `catch` that
  named the old word for a foreign key has to name the new one — the entry
  under New has the `switch`.
- **Every `nilo_fetch` call made under a request sends `X-Request-Id`.** A
  service that rejects headers it does not know gets
  `fetch.Client.Settings.forward_request_id = false`; a call naming its own
  keeps it.
- **`nilo_cache` forgets differently.** An entry earns its place by being read
  a second time, so a cache that is written and never read holds its first
  entries rather than its newest; `shards` defaults to 64. Eight threads read
  29% to 50% faster and one thread 8% to 10% slower — the right side of that
  trade for a server, the wrong side for a single-threaded program, and the
  entries under Changed have the numbers.
- **A `Db` that cannot dial logs `warn`, not `err`.** A CI step that read the
  suite's exit code was failing on a skipped database; one that grepped the
  log for `err` sees nothing now.

`listen(.{ .max_in_flight })` and `nilo.maxBody` are off until asked for, and
`app.health` and `nilo.Idempotent` are routes and arguments you add. Nothing
else above changes an answer a client gets.

### Changed

- **A `Db` that cannot dial warns rather than errs**
  ([ADR 0178](./docs/adr/0178-a-suite-whose-database-is-down-is-not-a-suite-that-failed.md)).
  The Zig test runner counts a logged `err` as a failed test, so a suite that
  skipped 95 tests exactly as it meant to still exited 1 behind 190 log lines.
  `nilo_start` returns the error either way, which is what the caller acts on —
  the same argument `sqlite.read` and `db.wireOf` already make in comments. A Row
  that disagrees with its table still logs at `err`, because that is a broken
  program rather than a machine without a database on it.

  The other half is not nilo's: pg.zig logs its own connect failure at `err`.
  `std.testing.log_level` is what turns it down, and the reference now says so
  next to `connect_on_init` — including the thing that costs an afternoon first,
  that `std_options` in a tested file is never consulted.

- **A request's id goes out with every `nilo_fetch` call made under it.**
  `client.get(c, …)` and the four beside it send `X-Request-Id` — the id a
  proxy sent and nilo checked, or the one nilo minted — so the service on the
  other end logs the same string you do
  ([ADR 0196](./docs/adr/0196-a-request-id-goes-out-with-the-call.md)). Read
  off the Scope by declaration, so a `nilo.Run` sends nothing and
  `nilo_fetch` still names no `Ctx`; `nilo.AnyScope` carries it across a
  function pointer as `erased.requestId()`. A call with no headers of its own
  costs nothing for it; one that passes headers spends one bump of the request
  arena on the merge. **If the service you call rejects headers it does not
  know**, `fetch.Client.Settings.forward_request_id = false` sends none, and
  a call naming its own `X-Request-Id` always keeps it. `Exchange.begin` is
  untouched: a signed request sends exactly what it signed.

- **`nilo_cache` reads 13% faster on eight threads, because a lookup no longer
  takes the shard's lock**
  ([ADR 0188](./docs/adr/0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)).
  Every `get` used to take the lock exclusively, so eight readers queued behind
  each other. A read now copies the value out with nothing held and then reads
  the region's write cursor a second time: if it has passed the entry, some
  `put` was writing over those bytes while they were read, and the answer is
  discarded. 124.5–124.9M reads a second against 108.8–110.7M, four interleaved
  rounds a side, and unchanged on one thread. Hit rate is up 0.1 to 0.3 points
  at every size as well, because a key the ring has seen before now skips the
  doorkeeper. **Nothing to change**: the API, the memory and the budget are the
  same. Two things are worth knowing. `Stats.evicted` now also counts the rare
  read whose bytes a `put` overwrote mid-copy, so it is no longer only about the
  ring being too small. And `Store.stats()` takes no lock, so it is a sum over a
  moving target rather than a snapshot.

- **`cache.Options.shards` defaults to 64 rather than 16**
  ([ADR 0187](./docs/adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)).
  Nine reads to a write on eight cores: 87.4M ops/s at the old default, 125.0M
  at the new one. No hit-rate cost at any budget measured; single-thread cost
  is 5%. Nothing to change unless you set `.shards` yourself.

- **`nilo_cache`'s eviction policy changed: an entry now earns its place by
  being read a second time.** A new entry lands in a small region, a tenth of
  each shard's ring, and is promoted into the other nine tenths only the next
  time it is read. On Zipf 0.99 traffic the hit rate went from 67.0% to 75.6%
  at 512 KiB and from 52.4% to 64.2% at 128 KiB, which is 2 to 3 times less
  memory for the same hit rate. **What you might notice:** a cache that is
  written to and never read now holds its first entries indefinitely, rather
  than forgetting the oldest one first.

- **The table takes a sixth of `.bytes` rather than a quarter**, so the ring
  takes five sixths rather than three quarters. A quarter bought about twice as
  many slots as the ring could ever fill. Nothing to change: it is the same
  memory holding the same entries at the same hit rate, 7.5% faster on one
  thread and 5% on eight. Set `.entries` yourself if the split is wrong for
  what you store.

- **`cache.Stats` gained a `rescued` field**: entries a read moved out of the
  write cursor's way before it reached them. Zero means the eviction policy
  is doing nothing.

- **Cost of all of it together: single-threaded throughput is 8% to 10% lower,
  and eight-thread throughput is 29% to 50% higher.** The right side of that
  trade for a module whose caller is a server, and the wrong side for a
  single-threaded program. Against the Go caches that answer the same question,
  eight threads now reads 135.0–136.0M a second where freecache reads
  46.8–47.0M and bigcache 51.4–52.2M, on 64.3 bytes an entry against their
  132.0 and 149.4. Full numbers in
  [`bench/result/cache.md`](./bench/result/cache.md).

### Fixed

- **`nilo_cache` could hand a lookup another key's bytes on an ARM machine.**
  The lock-free lookup this release introduces (ADR 0188) proves an entry was not
  being overwritten by reading the ring's cursor after the copy; on aarch64 the
  processor may reorder the copy past that read, and the writer's `memcpy` past
  its own cursor store, so the proof held the compiler and not the hardware.
  One to three wrong answers per run of the suite on an M1 Pro; none on x86,
  which does not reorder either. The reader issues a load-load barrier on
  aarch64 now and the writer moves the cursor with a swap off x86. Measured at
  no cost in either mode; x86 is byte-for-byte unchanged. Nothing to change
  ([ADR 0190](./docs/adr/0190-an-ordering-is-proved-on-the-processor-that-runs-it.md)).

- **`nilo_cache` compiles on macOS.** `clock.zig` named `CLOCK_MONOTONIC_COARSE`,
  which exists on Linux and nowhere else, so every build that reached the module
  — `test-cache`, `snippets` — stopped at one line. Darwin's name for the same
  cheap clock is `MONOTONIC_RAW_APPROX`; anywhere that has neither gets the
  precise `MONOTONIC`, which is right before it is fast. Nothing to change.

- **`zig build test` on an Apple Silicon machine no longer runs it out of
  memory.** The `ReleaseSafe` test gates were on Zig's self-hosted backend
  everywhere, on the strength of x86_64 figures; on aarch64 that backend takes a
  290 MB compile past 15 GB and does not finish, and eight of those at `-j8`
  took a 16 GB laptop down before printing a line. The self-hosted backend is
  now named only on x86_64, where it was measured; everywhere else both modes
  are Zig's default, which is LLVM. Nothing to change in a project that depends
  on nilo — this is nilo's own suite
  ([ADR 0189](./docs/adr/0189-a-backend-is-trusted-where-it-was-measured.md)).

- **A `db.raw` reading a text column got the wire format and kept it as if it
  were digits**
  ([ADR 0154](./docs/adr/0154-a-raw-statement-cannot-cast-what-it-did-not-write.md)).
  A `date` came back as four characters and **nothing errored**. The Dialect
  adds `::text` to every `SELECT` list nilo writes and to none that you write,
  so this was the one silent wrong answer in the module — and `Decimal` is
  `AsText("numeric")`, so it was money as much as dates.

  It is now a compile error, in the machinery that already counts the columns
  (ADR 0148):

  ```
  nilo: column 2 of the statement handed to `db.raw` is `total`, and field 2 of
  Invoice is a `numeric` column read as text.
    […] Ask for it as `total::text AS "total"`.
  ```

  **What you have to change:** cast the column — `total::text AS "total"` on
  Postgres, `CAST(total AS TEXT)` on SQLite. Only two shapes are refused, a bare
  column and a `*`; any expression at all is left alone.

- **`[]const Str` was documented as a `db.raw` parameter and was not one**
  ([ADR 0156](./docs/adr/0156-a-list-of-str-is-a-parameter-too.md)). It stopped
  inside nilo with `expected type '…!?[]const []const u8'`, naming a line of
  nilo's rather than your call site. Both spellings work now, as the reference
  has said since lists landed. Nothing to change.

- **Sixteen `named` routes on one group exceeded the comptime branch budget**
  ([ADR 0157](./docs/adr/0157-a-check-pays-for-its-own-branches.md)).
  `evaluation exceeded 1000 backwards branches`, pointing at a line in `app.zig`
  and at whichever route the walk stopped on. `checkName` sizes its own quota
  now. **What you have to change:** delete the `@setEvalBranchQuota` you added
  to your own `register` to get round it.

- **A shard count clamped to something other than a power of two made part of
  `nilo_cache`'s memory budget unreachable**
  ([ADR 0187](./docs/adr/0187-a-cache-that-admits-everything-forgets-what-mattered.md)).
  `shard_mask` is `shards.len - 1` used as a bitmask, which is a true modulo
  only when the shard count is a power of two. `Store.open` rounded the
  requested count up to a power of two and then clamped it down to
  `total_cap / 4096`, which can land on any number at all. At the 64 KiB
  minimum budget on the old default `shards`, 33% of the memory was never
  reachable; at 192 KiB with `shards = 64` it was 78%. `bytesHeld()` counted
  all of it, so the number the module's own headline promise is made of was
  counting memory that could never hold anything. Fixed by flooring the clamp
  to a power of two; the property is now a test.

### Documentation

- **Every module has a guide page now.** `nilo_fetch`, `nilo_s3`, `nilo_cache`,
  `nilo_jwt` and `nilo_id` used to be reachable only through the reference;
  each has a page under [`docs/guide/`](./docs/guide/) that says what it is
  for, the whole of it in one example, every option with its default, what it
  answers instead of a value, what it costs and what it will not do. Every
  `zig` block on them that could be compiled is marked and is.

- **The SQL guide is a folder.** `docs/guide/sql.md` had reached 1,825 lines;
  it is [`docs/guide/sql/`](./docs/guide/sql/README.md) now, nine pages read
  in order, with the same 48 checked snippets and one more on the front page.
  A link to the old path is a link to the front page. `zig build snippets`
  learned to carry one page's declarations in front of the next, which is what
  let the guide keep showing each struct once.

- **Five places the guide disagreed with itself are settled.** The cookies
  page said sessions were entirely yours while the sessions page shipped
  `Session(T)`; the handlers page's argument table had no `Form(T)`,
  `Bound(…)` or `Session(T)` and its return table no `Redirect` or `FileBody`;
  the errors page's table of statuses nilo writes for you was missing the
  403, 408, 422, 429 and 500 that other pages described; the testing page
  quoted build timings from before ADR 0170; `c.streamWith` was shown with
  one argument on the page about it. The README's badges said 218 refusals
  and 174 decisions where there are 231 and 190.

- **The reference says a v7 is not ordered inside one millisecond.** The fact
  was already in `Uuid.v7`'s doc comment and nowhere a reader meets first. The
  trap is not that ids are unordered — it is that they *look* ordered until two
  rows share a timestamp, which is exactly what `now()` inside a transaction
  gives every row one command writes. No code changed; `v7` is still stateless
  and still takes no counter (ADR 0042).

- **The transaction type is spelled `sql.Db.Tx`**, and the reference says so.
  Every example infers it from `db.begin`, so the name never had to be written
  until a function of yours took one — `fn append(self: *Bus, tx: *sql.Db.Tx, …)`.
  Documentation only; `sql.Tx` never existed.

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.3.0](https://github.com/nevindra/nilo/releases/tag/v0.3.0)** — the
  release a real port wrote: migrations as a diff against a snapshot and the
  `db` command, deadlines and an allowance per route, a metrics page, sessions
  that expire, and eleven things to read before deploying, listed there.
- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
