# A numeric is digits, and it leaves as a string

`nilo_sql` could not read a `numeric` column at all. `dialect.accepts` had no
entry for one, so a Row carrying money either did not compile or read the
column as `f64` — which is the mistake the column type exists to prevent, made
by the code that was supposed to prevent it.

The roadmap called this the one that matters: *money in an `f64` is wrong, and
a service that bills anybody needs it before it needs anything else on this
list.*

## What was decided

**`sql.Decimal`, and it holds text.**

```zig
const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};
```

`total.text` is the digits exactly as Postgres printed them. There is no
`.add`, no `.mul` and no `.round`.

**It does not calculate**, which is the line `sql/types.zig` already holds for
`Timestamp` and holds here for the same reason. Arbitrary-precision decimal
arithmetic is a library, and a larger one than it looks: rounding modes alone
are a standard with named variants that disagree about money. What a database
module owes is that the digits which went in are the digits that come out.
Whoever wants to add two of them can build on this; it is the floor for that
work rather than a refusal of it.

**It writes itself into JSON as a string.**

```json
{ "id": 1, "total": "1234.56" }
```

A bare JSON number was the alternative and it is exact *on the wire* — JSON
numbers have no width limit. It stops being exact one line later, in the
consumer: `JSON.parse` answers a `double`, so a client would silently receive
the `f64` the column type was chosen to avoid. **The failure is silent and it
happens on the far side of the network**, which is the worst place to put it.
A string arrives intact and makes the reader decide what to do with it. It is
also the only representation that can carry what Postgres allows and JSON has
no syntax for: `nan`, `inf`, `-inf`.

The precedent was already in the file: `Timestamp` writes as an RFC 3339
string for the same shape of reason — a value with a canonical text form and
no native JSON type.

**The Dialect writes the casts.** `"total"::text` in every `SELECT` list, and
`$1::numeric` wherever a `Decimal` is bound — a new pair on the Dialect,
`readAs` and `bindAs`. Both are comptime and decided by the Row's field type,
so nothing about ADR 0039 moves: the statement is still a constant settled
while compiling.

## Why not the alternatives

**Read it through pg.zig's `Numeric`.** That is the obvious route and it fails
on the write half. `Numeric.encode` takes a **float** — it calls
`math.isNan(v)` and prints with `{d}` — so every value inserted would make the
round trip through binary floating point that the column exists to avoid. The
string encoder beside it, `encodeValidString`, is private and takes pg.zig's
own buffer type. Reading would also have needed a decoded struct whose digits
are borrowed from the row, and a place to render them with no allocator in
hand.

**Decode the binary form here.** Sign, weight, scale and base-10000 limbs is a
wire format, and putting one in `db.zig` would move knowledge across the seam
`dialect`/`wire` exists to hold: a Dialect writes SQL, a Wire speaks a
protocol, and neither is supposed to leak into the layer that fills a struct.
Casting in SQL is the same conversion asked for on the side that already
knows how to do it.

**`{ units: i128, scale: u8 }`.** A real representation and a better one to
compute with, and it buys nothing here because nothing here computes. It also
cannot hold `nan` or `inf`, which Postgres will hand over, so it would need a
tag beside it and would still be converting on the way in and out.

**Leave the column as `f64`.** This is what a caller has today, and the whole
of the case against it is that it is quietly wrong. A cent per invoice is
invisible in a test and a headline in an audit.

**A separate `format: decimal` in the API description and a bare number in the
body.** Two things to keep in step, and the document would be promising
something the body contradicts.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none new.** A `Decimal` is copied out of the read buffer by the same `arena().dupe` a text column has always cost, so a `numeric` adds no class of allocation the row was not already paying for — and unlike `Json(T)`, none per row that a scalar would not have. |
| Memory per idle connection | **none.** Nothing new is held between requests. |
| Throughput and p99 | **none** for a Row with no `Decimal` in it: `readAs` and `bindAs` are comptime and return their argument unchanged. For one that has a column, the cast is Postgres's own and the digits are text either way. |
| Binary size | **zero** on every measured binary. No example and no benchmark imports `nilo_sql`, and pg.zig is `.lazy = true`. |

**It stays streamable**, which the shape it replaced would not have. A
`Decimal` in a `Borrowed` row is a `[]const u8` — `row.Borrowed` maps it the
way it maps `Str`, so the digits point into the read buffer and the type says
so. `db.stream` therefore still allocates nothing per row, where `Json(T)` had
to be refused outright.

## What the measurement corrected

**The read cast is not load-bearing, and it is kept anyway.** With `::text`
removed, the live round trip still returns all twenty-nine significant digits
— pg.zig is handing the column over as text already, whatever its result-format
logic intends. The cast was written on the assumption that it would arrive
binary, and that assumption was not checked until afterwards.

It stays because what it removes is a dependency rather than a bug: without
it, the correctness of every money column rests on a driver's choice of result
format, which nilo does not make, did not design, and would discover was
different by getting limbs where it expected digits. The comment in
`dialect.zig` says the number was measured, so nobody has to re-derive it to
decide whether the line can go.

The write cast is load-bearing and was verified the same way.

## Consequences

- A service that bills somebody can read and write the column that exists for
  it, and the digits survive the round trip — checked against a real Postgres
  with a value twenty-nine significant digits wide.
- `numeric` comparisons are numeric. `"100.00" > "9.99"` is false as text and
  true as a number; the `::numeric` on the placeholder is what settles it, and
  a live test pins it.
- The Dialect grew `readAs` and `bindAs`, which is the first time the seam has
  had to express something Postgres and another database would spell
  differently — SQLite would write `CAST($1 AS NUMERIC)`. That is a small
  piece of evidence that the seam is in the right place, and the first this
  repository has had ([roadmap](../roadmap.md), `nilo_sql` Next).
- Arrays, `interval` and `inet` are still unread. They were the rest of the
  same roadmap item and none of them has this one's argument behind it.
