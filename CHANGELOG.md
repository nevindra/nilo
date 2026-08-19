# Changelog

What changed between one tag and the next, not what changed between commits.
What was measured and what was got wrong on the way is in
[`docs/history.md`](./docs/history.md); what is coming is in
[`docs/roadmap.md`](./docs/roadmap.md).

## Unreleased

### A reaped connection is retried whichever way the peer dropped it

`fetch` retries a call once when the pooled connection it was handed had
already been reaped by the peer. It only recognised half of what that looks
like ([ADR 0088](./docs/adr/0088-a-reaped-connection-arrives-two-ways.md)).

If the peer's close lands first, the socket carries a FIN and `std.http` says
`HttpConnectionClosing`. If your request lands first, the peer closes a socket
with an unread request in it, the kernel sends an RST instead, and `std.http`
says `ReadFailed`. Same reaped connection, same nothing answered, and only the
first was retried. Which one you get is a race nobody runs.

**What to change:** nothing. A call that used to fail on a coin toss against a
service that reaps idle connections now retries, under the same bounds as
before: only a replayable body, only inside the same permit and deadline, and
at most one attempt per connection the pool could hold. A reset partway through
a response head is still a failure, because something did come back.

### A response header can no longer forge a second one

`Ctx.setHeader` refuses a value carrying `\r`, `\n` or `\0` with
`error.BadHeaderValue`, and a name that is empty or carries any of those or
`:`, a space or a tab with `error.BadHeaderName`
([ADR 0086](./docs/adr/0086-a-response-header-cannot-forge-a-second-one.md)).

Until now the value went to the wire exactly as handed over, so a header built
out of request data did not stay inside its header. It ended the header block
and wrote the rest of the response itself. The path is the one `Redirect.to`
takes: a shortening service that stores a URL somebody submitted, and a
`Location` that sets a cookie no line in the application sets.

**What to change:** nothing, unless a header value of yours legitimately holds
one of those bytes, which no header value does. `Redirect`, `Response.headers`,
`FileBody.headers` and `cors` all go through `setHeader` and are covered by it.
A handler that lets the error out sends a 500.

Checked in every optimize mode, not only `Debug`. It costs 3 to 8ns of a 192ns
request, and nothing at all on a response that sets no header
([`bench/result/http.md`](./bench/result/http.md)).

### A request whose body is framed twice is refused

Four ways a `Content-Length` could disagree with the reverse proxy in front of
nilo, all now `400`
([ADR 0087](./docs/adr/0087-a-body-framed-twice-is-refused.md)):

- a value that is not plain digits (`+5` used to read as 5, `1_0` as 10, `-0`
  as 0)
- a repeated `Content-Length` with a different value (the same value is fine)
- `Content-Length` beside `Transfer-Encoding: chunked`, in either order
- a second `Transfer-Encoding` line once chunked has been seen

`chunked` is also read as the last coding in the list rather than as a substring
anywhere in it, so `xchunked` is no longer taken for chunked framing.

**What to change:** nothing. Every request refused here is one a proxy in front
would very likely have refused already.

### `Vary` is repeated rather than replaced

`Ctx.setHeader("Vary", …)` twice now sends two `Vary` lines instead of the
second replacing the first. That is what RFC 9110 §5.3 says a recipient joins
with a comma, so `Vary: Origin` plus `Vary: Accept-Encoding` is
`Vary: Origin, Accept-Encoding`.

**What this fixes:** a compressed static file served behind `cors.with(.{
.origin = … })` sent only `Vary: Accept-Encoding`. A shared cache reading that
is entitled to hand one origin's response to another. `cors.permissive` was
never affected, so this bit the careful configuration and not the loose one.

### Two ceilings that were reached in silence now say so

Both are [ADR 0081](./docs/adr/0081-a-ceiling-that-is-reached-is-said-out-loud.md)
applied where it had not been.

A multipart form with more than `form.max_parts` (256) parts is a `400` naming
the ceiling. It used to read the first 256 and walk past the rest, which a
handler cannot tell apart from fields the browser never sent.

A `422` from `Bound(T)` that runs out of `fail.max_message` ends with
`; and N more` instead of stopping mid-word.

### `Message.data`'s documented lifetime was backwards

Documentation only, and worth reading if you hold a WebSocket message past the
`receive` that produced it. The type said the bytes were "the caller's memory
and lives exactly as long as the caller decides". They are borrowed from the
executor's free list and the loan ends at the next `receive`, sooner if the
connection falls quiet, at which point another connection may be filling the
same pages. `docs/reference.md` always had this right. Copy before you keep.

### A type can say how its JSON is spelled

`std.json` writes a union one way — `{"metrics":{…}}`, one object with one key.
Most REST APIs use the other one, and there was no way to ask for it short of a
hand-written `jsonStringify` and `jsonParse` per type. Now there is
([ADR 0085](./docs/adr/0085-a-type-says-how-its-json-is-spelled.md)):

```zig
const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .rename_all = .lowercase };
    pub const jsonParse = nilo.jsonParseFor(@This());

    metrics: MetricCondition,
    logs: LogCondition,
};
```

```json
{"signal":"metrics","metric_name":"system.cpu.utilization","threshold":0.9}
```

`.tag` is the discriminator's key. `.rename_all` spells a variant's name or an
enum's tag the way the wire wants it, and takes `.lowercase`, `.UPPERCASE`,
`.camelCase`, `.PascalCase`, `.SCREAMING_SNAKE_CASE` and `.@"kebab-case"`. It
does not touch field names. A variant carrying nothing is the tag on its own.

The second line is only needed for a type that *arrives* in a request. Sending
needs nothing, because nilo makes that call and reads the marker itself; reading
is `std.json`'s call, and nothing can add a declaration to a type you wrote.

A `union(enum)` as a request body used to be a compile error, on the grounds
that nothing in the type said which arm arrived. `.tag` is the type saying it,
so that shape now works.

The generated API description follows whichever encoding the type asked for, so
a client generated from it reads what the server actually sends. A tagged union
is `oneOf` with `discriminator`; an untagged union is still `{}`.

### Responses carrying a union got two to three times faster

Not a new feature and nothing to change. `covers` decides while compiling which
types nilo's own JSON writer may touch, it is answered for the **whole** value,
and it did not recognise a `union(enum)` at all — so one union field anywhere
sent the entire response to `std.json`, every string in it included.

On a 374-byte payload with a union in it that is **2.8× to 3.2×**, and 3.4× to
3.5× on a 104-byte one. The bytes are unchanged: an unmarked union is still
written externally tagged, and the tests hold nilo's output against `std.json`'s
value by value. [`bench/result/http.md`](./bench/result/http.md) has the run and
the controls.

### Also

Twelve new refusals cover the ways of writing the marker wrong, taking the
framework's table from 63 to 75 and the five tables from 129 to 141. The one
worth knowing is a `.tag` whose name a variant already uses as a field: that is
the only mistake here that would corrupt the wire rather than fail.

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
