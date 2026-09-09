# Changelog

What changed between one tag and the next, not what changed between commits.
This file holds the release that has not been tagged yet;
[the releases page](https://github.com/nevindra/nilo/releases) holds the ones
that have, one page each. What was measured and what was got wrong on the way is
in [`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

Thirty things a real port hit, in the order they cost it the most. Needs Zig
0.16, as 0.3.0 does. Each entry says what you have to change; the account of why
is in the ADR it links.

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

- **`app.writeOpenApi(w)` — the API description, with no server**
  ([ADR 0167](./docs/adr/0167-the-document-is-a-build-artefact.md)). The
  document was reachable only from `GET /openapi.json` on a listening server,
  and `listen` runs `db.checking` — so producing the file a typed frontend
  client is generated from needed a **migrated database**. Called after the
  routes are registered and before `listen`, this needs no port, no database and
  no network, which makes `zig build openapi > openapi.json` an ordinary build
  step. The served copy goes through the same call, so a checked-in file and a
  running server cannot describe two different APIs.

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

- **`entropyInto(buf)` on `Ctx` and `Run`**
  ([ADR 0166](./docs/adr/0166-entropy-a-function-pointer-can-carry.md)).
  `entropy` answers `![n]u8` with `n` comptime, and a **function pointer** has to
  name one return type — so a Scope type-erased to cross one carries exactly one
  width. Zig has no closures, so erasing a Scope is what storing a callback comes
  to. Same bytes, same wait; `entropy` is now written in terms of it.

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

- **`Str.blank()` and `Str.trimmed()`**
  ([ADR 0175](./docs/adr/0175-required-text-arrives-as-two-spaces.md)).
  `std.mem.trim(u8, s.view(), " \t\r\n").len == 0` was written eight times in one
  context, with the charset spelled out in six of them. Required text arrives as
  `"  "` in the ordinary case rather than the rare one, and a copy that drops
  `\n` accepts a comment whose whole body is a newline — a required field that
  every screen renders as empty, with nothing failing. The set is
  `std.ascii.whitespace`. A read of the bytes, not a validation rule.

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

### Fixed

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

### New

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

- **`sql.Timestamp` reads RFC 3339 back**
  ([ADR 0159](./docs/adr/0159-what-a-server-prints-it-can-read.md)). It wrote
  one and could not read one, so every keyset cursor — a value the same server
  printed a request ago — needed a parser of the caller's own, and a parser that
  disagrees with the writer pages past rows silently. An offset and fractional
  seconds are accepted; **a time with no zone is refused**, because guessing UTC
  moves the page by hours at a customer who is not in it.

- **`nilo.Run` can mint a key**
  ([ADR 0160](./docs/adr/0160-a-scope-that-can-mint-a-key.md)). nilo's own
  refusal says *pass the `*Ctx` the handler was given, or a `nilo.Run` if there
  is no request* — and `entropy` was on `Ctx` alone, so every service function
  that creates something failed to compile under a `Run`.

  ```zig
  var run = nilo.Run.initIo(gpa, io);   // and `entropy` works
  ```

  `Run.init(gpa)` is unchanged and answers `error.NoIo` from `entropy`.

- **`nilo.testing.Refusals` — read a fail function's status and sentence outside
  a request**
  ([ADR 0161](./docs/adr/0161-a-refusal-outside-a-request-is-still-a-refusal.md)).
  With no request in flight the status and the message were dropped, so a
  service function refusing four ways was four identical `error.Failed`s. Driving
  the endpoint with `testing.Client` was the answer and is not one for a
  function a CLI or a seed calls.

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

## 0.3.0

Needs Zig 0.16, as 0.2.0 does. Each entry says what you have to change; the
account of why is in the ADR it links.

### New

- **Migrations: a schema is what your Rows already say, and `db` is the command
  that keeps a database matching them**
  ([ADR 0153](./docs/adr/0153-a-migration-is-a-diff-against-a-snapshot.md)).
  A Row's marker gained `.unique`, `.index`, `.references` and `.was`. That is
  the whole schema language — everything else is SQL you write, and nilo never
  touches a table it did not create. `sql.cli.Tool(Db, &.{ User, Org })` turns
  those types into five commands out of a `main` of ten lines:

  ```console
  $ db check                       # do the Rows and the migrations agree?
  $ db generate --name add_nickname
  $ db status
  $ db migrate
  $ db verify                      # has an applied version been edited since?
  ```

  `generate` and `check` **open no database**: both halves of the diff are files
  — your types against `migrations/snapshot.zon` — so CI needs no service
  container, and two branches conflict in git rather than at deploy. The exit
  code is the whole API for a pipeline: `0` did it, `1` you have something to
  do, `2` the command line was wrong.

  A version is one `.zig` file holding a list of steps, and it is exactly what
  runs: those steps, in one transaction, behind an advisory lock so ten replicas
  booting together run it once. Forward-only — there is no `down`, and `--drop`
  is required before anything that loses data is written. `sql.migrate` is the
  library under all of it, including `createMissing` for a fixture and `expect`
  for a server that must refuse a database behind its binary.

  Nothing to change. A program that never names `sql.migrate` links none of it:
  the two stripped `zig build size-sql` probes are byte for byte what they were
  before this landed ([`bench/result/sql.md` §10](./bench/result/sql.md)).

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
- **A server whose database never came up used to panic when it stopped.**
  The log said `info: nilo stopped` and the process crashed on the line after
  it — and so did a server that nilo itself refused to start, over a bad
  connection string or a Row that disagrees with its table. Both are fixed, and
  neither needs anything from you
  ([ADR 0151](./docs/adr/0151-a-service-is-stopped-before-the-loop-is.md),
  [ADR 0152](./docs/adr/0152-the-panic-under-the-panic.md)).
  **What does change: a `sql.Db` is closed when `listen()` returns**, because
  that is the only moment it can let go of the event loop it was built on. A
  program that used the `Db` after `listen()` came back has to stop doing that;
  `defer db.deinit()` is unchanged and still correct.
- **A Service of your own that puts work on the event loop should declare
  `pub fn nilo_stop(self: *T) void`.** It is the mirror of `nilo_start` and
  `listen()` calls it on the way out. Nothing to do if your service only holds
  data, or if it never touches the loop.
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

- **The process panicked on the way out whenever the pool never filled.**
  Two ways in, and the second was never reported because nobody expected it:
  nilo refusing to start (a schema mismatch, or credentials the database
  rejects), and an **ordinary shutdown of a server whose database was down the
  whole time**. The reported one was pg.zig returning from its reconnector
  while its mutex was unlocked, so the `defer` unlocked it twice — fixed
  upstream, and the pin is now past it. Underneath it was nilo's: a service was
  handed the event loop and never told to let go of it, so the loop was torn
  down with the pool's work still on it
  ([ADR 0151](./docs/adr/0151-a-service-is-stopped-before-the-loop-is.md),
  [ADR 0152](./docs/adr/0152-the-panic-under-the-panic.md)). Both exits are
  clean now, checked by two programs that used to panic and now return 0.

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

## Released

Every tagged release has its notes on its own page, which is where the whole
account of it lives:

- **[v0.2.0](https://github.com/nevindra/nilo/releases/tag/v0.2.0)** — 0.1.0 was
  an HTTP server called zfast. 0.2.0 is a toolkit called nilo, and that server
  is one of its eight modules. Includes what to change when upgrading from
  0.1.0.
- **[v0.1.0](https://github.com/nevindra/nilo/releases/tag/v0.1.0)** — the first
  release, published as zfast.
