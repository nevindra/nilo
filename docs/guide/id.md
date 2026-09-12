# Identifiers

`nilo_id` makes and reads UUIDs — v7 for a key that sorts by when it was
made, v4 for one that carries nothing but randomness. It is a tool module:
nothing here allocates, nothing here does IO, and it imports nothing, so
`zig test id/id.zig` runs the whole of it
([ADR 0042](../adr/0042-the-bottom-layer-holds-more-than-one-module.md)).

The `Uuid` here is the same type `nilo_sql` reads a `uuid` column into, so a
generated key goes straight into an insert, and it says what its JSON looks
like, so a Row holding one goes out as thirty-six characters rather than as
sixteen numbers.

```zig
const id = @import("nilo_id");
```

and in `build.zig`, beside `nilo_http`:

```zig
.{ .name = "nilo_id", .module = nilo.module("nilo_id") },
```

## A key for a new row

<!-- compiles: body -->
```zig
const id = @import("nilo_id");

const key = try id.v7Now(c);
_ = try db.insert(Doc, c, .{ .id = key, .title = nilo.Str.static("notes") });
```

where `Doc.id` is a `sql.Uuid`, which is this type under another name.

`v7Now` takes a Scope — the `*Ctx`, or a [`nilo.Run`](../reference.md#run)
built with `initIo` — because a key needs randomness and the clock, and both
are IO a module in the bottom layer has no Bulkhead to reach through
([ADR 0046](../adr/0046-entropy-belongs-to-the-loop.md)). Inside a request
that is `c.entropy(…)` and `nilo.nowMillis()`, which is the pair every
`create` was writing out by hand before, `@intCast` included
([ADR 0176](../adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)).
On a `Run` built by `init` rather than `initIo` it is `error.NoIo`.

| | |
|---|---|
| `id.v7Now(scope)` | `!Uuid` — sortable, from the Scope's randomness and its clock. **The call for a key** |
| `id.v7(entropy, ms)` | sortable — `ms` in the first six bytes, then the `[10]u8` you pass. The call for a key at a time you chose: a backfill, a row that existed before its id did |
| `id.v4(entropy)` | random — 122 bits of the `[16]u8` you pass in |

## Reading and writing one

| | |
|---|---|
| `u.toText()` | `[36]u8` by value: `550e8400-e29b-41d4-a716-446655440000` |
| `u.writeText(w)` | the same, into a `*std.Io.Writer` |
| `id.Uuid.parse(text)` | `!Uuid`, `error.InvalidUuid`. Hyphens optional, case ignored |
| `u.version()` | `u4` — `4`, `7`, or whatever the bytes claim |
| `u.millis()` | `?u64` — the millisecond a v7 carries, null for anything else |
| `u.eql(other)`, `u.isNil()`, `id.Uuid.nil` | |
| `id.Uuid.byte_len`, `.text_len`, `.v4_entropy`, `.v7_entropy` | 16, 36, 16, 10 |

**`{f}` prints one**, which is what a refusal naming the record it could not
find wants:

<!-- compiles -->
```zig
const id = @import("nilo_id");

fn document(db: *sql.Db, c: *nilo.Ctx, key: id.Uuid) !Doc {
    return try db.one(Doc, c, .{ .where = .{ .id = key } }) orelse
        nilo.fail.notFound("no document {f}", .{key});
}
```

`{s}` cannot be made to work — Zig reserves it for byte slices and a `Uuid`
is a struct — and `writeText` is a method, so it answers a writer you already
hold and answers nothing to a format string.

A `Uuid` as a path param converts on the way in: `fn document(db: *sql.Db,
key: id.Uuid)` against `/documents/:key` is a 400 saying so when the text is
not one, and the API description says the parameter is a string in `uuid`
format. In a returned struct it leaves as its text, and in a Row it is
written and read as the `uuid` column
([ADR 0078](../adr/0078-a-uuid-is-whatever-the-database-stores.md)).

## What a v7 orders, and what it does not

**A v7 is sortable across milliseconds and not within one.** Its first six
bytes are the clock and the other ten are the entropy you passed, with no
counter — so two keys minted in the same millisecond come back in random
order relative to each other. RFC 9562 allows a counter there, and it is
deliberately not taken: a counter is a threadlocal or an atomic, and having no
state is what lets `v7` be called from any fiber without a lock.

**The trap is not "the ids are unordered" — it is "they look ordered as long
as the timestamps differ".** The case that finds it is a row whose timestamp
comes from `now()` inside a transaction. That is Postgres behaviour rather
than nilo's: `now()` is the *transaction's* clock, so every row one command
writes carries the identical instant, and the whole of the ordering then
rests on ten random bytes. `ORDER BY occurred_at, id` looks right in every
test where the writes were a millisecond apart and reshuffles the rows
written together.

If the order rows were written in is something your product shows, store it:
an ordinal column the command fills, or a sequence. A v7 orders by *when*,
and two things that happened at the same instant have no *when* to be
ordered by.

## The randomness has to be unguessable

`v4` and `v7` take their entropy as an argument rather than fetching it,
because entropy is IO. Inside a request that is `c.entropy(n)`; outside one
it is `std.Io.randomSecure`, or a `Run` built with `initIo`. **A v4 built
from a seeded `std.Random.DefaultPrng` is fine in a test and is a session
token anybody can predict in production**, and nothing here can tell the
difference — the signature makes the choice yours so that it is visible.

## What it costs

Nothing per request: `v7Now` is one entropy read and one clock read, and the
text form is written into a `[36]u8` on the stack. A `Uuid` is sixteen bytes
by value, wherever it sits.

## Testing

Both constructors are pure functions of their arguments, so a test chooses
the bytes and the millisecond and asserts on the text:

```zig
test "a v7 carries its millisecond" {
    const u = id.v7([_]u8{0} ** 10, 1_700_000_000_000);
    try testing.expectEqual(@as(u4, 7), u.version());
    try testing.expectEqual(@as(?u64, 1_700_000_000_000), u.millis());
    try testing.expect((try id.Uuid.parse(&u.toText())).eql(u));
}
```

A handler that takes an `id.Uuid` is an ordinary function, and
`id.Uuid.parse("…")` is how a test hands it one.

## See also

- [The reference](../reference.md#nilo_id) — the surface as a list.
- [Talking to a database](./sql/README.md) — the `uuid` column a `Uuid` is written
  to, and the Row that carries it.
- [ADR 0176](../adr/0176-a-key-that-can-be-printed-and-a-key-that-can-be-made.md)
  — why `v7Now` and `{f}` exist.
