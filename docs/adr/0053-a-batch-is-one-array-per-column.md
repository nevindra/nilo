# A batch is one array per column, not one placeholder per value

Inserting a thousand rows was a thousand round trips. Inside a transaction it
was a thousand round trips holding a connection, which is worse: the pool is
ten, so a batch import could starve every other request on the server for as
long as it ran.

The roadmap called this Next 1 alongside the upsert, and it was waiting behind
arrays ([ADR 0051](./0051-an-array-is-a-slice-and-a-slice-is-one-deep.md)) —
Postgres's own answer to a batch is an array per column.

## What was decided

**`db.insertMany(Row, c, rows)`, and the statement is a constant.**

```zig
const Line = struct { sku: []const u8, qty: i32 };

const stored = try db.insertMany(Item, c, lines);   // lines: []const Line
```

```sql
INSERT INTO "items" ("sku", "qty")
SELECT * FROM unnest($1::text[], $2::int4[])
RETURNING "id", "sku", "qty"
```

Two placeholders, whatever the batch size. `RETURNING` gives the stored rows
back in the order they were sent, because `unnest` walks the arrays in step.

The rows arrive as a slice of a **named** struct rather than a tuple of
literals, and that is not a limitation to apologise for: the statement is
compiled from the element type, so there has to be one.

## Why not `VALUES ($1,$2),($3,$4),…`

That is the shape most libraries generate, and it is the one shape this cannot
have. The placeholder count *is* the batch size, so:

- the SQL would be built per call, which is the whole of what
  [ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md) says
  does not happen here;
- Postgres would plan a different statement for every batch size, so a service
  importing 1, 7 and 200 rows keeps three plans warm and pays for the third
  the first time it sees it.

`unnest` costs one extra node in the plan and buys a statement that never
changes.

## Why not a comptime-sized batch

`db.insertMany(Item, c, .{ a, b, c })` with the count known while compiling
would let `VALUES` work and keep the constant. It also means a batch whose size
comes from a request body — the case a batch exists for — cannot use it, and
the statement is instantiated once per distinct count. The size of a batch is
data.

## The two column types that travel differently

Everything binds in a batch the way it binds alone, except two, and both are
pg.zig's shape rather than Postgres's:

- **`Uuid`** binds as a slice of its bytes rather than as `[16]u8`. Alone it
  has to be the array, because the parameter tuple is all the driver has to
  read from and a slice would point at the copy `where.valueAt` returned. A
  batch has somewhere better to point — the caller's own slice of rows, which
  is alive for the whole call by definition. pg.zig also has no encoder for an
  array of `[16]u8`, and does have one for `uuid[]` given bytes.
- **`Json(T)`** is written out into the arena rather than handed over whole,
  because pg.zig encodes a `jsonb[]` element from bytes and will not take a
  struct. **This is the one place a batch pays per row rather than per
  column**, and it is the same cost reading the column already has.

Two column types are cast twice on the way out — `$n::text[]::numeric[]` and
`$n::text[]::jsonb[]`. The first is the array form of what a single `numeric`
already does and is a design; the second is a **workaround for a pg.zig
defect** and is marked to delete: its `jsonb[]` encoder reserves five bytes of
prefix per element and writes four for a NULL — the version byte it counted is
never written — so an array with a NULL in it is one byte too long and
Postgres answers *incorrect binary data format*. Its `text[]` encoder gets the
same case right.

## What a column has to be able to say

Two columns cannot be batched, and both are refusals with the fix in them:

- **A list column.** A batch sends one array per column and `unnest` flattens
  what it is given, so a `text[]` column would come back one element per row.
  Those rows go in one at a time.
- **An enum that has not said what it is called.** `unnest($1)` with no cast is
  *could not determine data type of parameter $1* at run time, and a Postgres
  enum's type name lives in the database — nothing on the Zig side can derive
  it. So the enum declares it:

  ```zig
  const Role = enum {
      admin,
      member,

      pub const nilo_column = "user_role";
  };
  ```

  That declaration pays for itself twice: the schema check, which previously
  declined to judge any enum column, now judges this one at startup.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** One per column — the array a column's values are
  gathered into — plus one per row for a `Json` column, and nothing else scales
  with the batch. Against a loop of inserts, which allocates nothing extra and
  costs a round trip per row, this is the trade being made on purpose.
- **Memory per idle connection.** Nothing.
- **Throughput and p99.** The point. One round trip against N; the arrays are
  built with one pass over the caller's slice.
- **Binary size.** Instantiated per Row and per batch element type, and only
  where it is called.

`fill` in `db.zig` changed from a comptime `reserve` to a runtime one so that
the returned list is sized exactly once — a batch is the first caller that
knows its ceiling only when the slice arrives. That costs one branch per
statement everywhere else.

## Consequences

- A failed batch takes all of its rows with it, because it is one statement.
  That is usually what was wanted and it is the opposite of a loop of inserts
  without a transaction around it.
- `arrayOf` joins the Dialect's contract. A second dialect has to name the
  array form of every column type it accepts, or refuse the batch.
- `updateMany` is the same arrays joined against the table rather than
  selected into it, so it arrived as a second statement over this machinery
  rather than as a second design. Each row of the batch carries the Row's key
  and is found by it, which is why there is no `.where` to write and why a
  batch missing the key is a compile error. Two things a join will not
  promise and this call therefore does not either: the order rows come back
  in, and that a key named twice is applied twice. `db.update` in a loop is
  the shape where either matters.
