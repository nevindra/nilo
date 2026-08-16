# An array is a slice, and a slice is one deep

`nilo_sql` could not read a `text[]` or an `int4[]`. A Row that declared one
stopped with pg.zig's own `compileHaltGetError` four frames inside the driver,
which is the failure mode ADR 0027 exists to keep out of this project.

Arrays are also what an `insertMany` is built on: Postgres inserts many rows in
one statement by taking one array per column and calling `unnest` on them. So
this is the entry in the roadmap that two others were waiting behind.

## What was decided

**A list column is a plain Zig slice, with no wrapper around it.**

```zig
const Ticket = struct {
    pub const nilo_table = .{ .name = "tickets", .key = .id };

    id: i64,
    tags: []const Str,
    scores: ?[]const i32,
};
```

`Str` in a list for the same reason `Str` is text everywhere else: the bytes
belong to the request. `?[]const i32` is a **nullable column**; `[]const ?i32`
is a column whose **elements** may be null, and the two are different things
Postgres tells apart.

Reading one costs one allocation per row — the slice, and for text the bytes
in it — and `readList` is the only call in `wire.zig` that takes an allocator.
Writing one is a value like any other: `.tags = &.{ "urgent", "billing" }`.

## Why not the alternatives

**`Array(T)`, beside `Json(T)`.** It would look consistent and it would be
noise. `Json(T)` earns its parentheses twice over: a bare struct field cannot
say "this is a `jsonb`", and its `jsonStringify` has to unwrap so the response
body is not `{"value":…}`. `[]const i32` can only mean one thing, and it
already writes itself into JSON as an array. The one slice with a second
meaning is `[]const u8`, which is text and was spoken for long before arrays
were — so that one is *not* a list, and a list of text is written out as
`[]const []const u8` or `[]const Str`.

**Widening `accepts`, the way a scalar does.** A scalar `i32` column names
`int4` *and* `int8`, because an `int4` reads into an `i64` happily. An array
does not: pg.zig picks its element decoder off the array's own OID and refuses
a mismatch. Naming `_int8` for a `[]const i32` would have moved that refusal
from `checking` at startup to the first request that touched the column, which
is the trade the schema check exists to make in the other direction. **Array
`accepts` is exact.**

**Letting the driver assert.** pg.zig reads the array header and asserts two
things: that the array is one-dimensional, and that it has no NULLs unless the
element type is optional. Both are `std.debug.assert` — a panic in Debug and
ReleaseSafe, a read past the end of the buffer in ReleaseFast. Neither is a
malformed array: Postgres allows a NULL in any array and does not enforce the
dimensionality a column was declared with, so both are shapes an honest table
produces. `postgres.zig` reads the same header first and answers
`error.QueryFailed`, which is one failed request instead of every in-flight
one (ADR 0008). This is the same fix as the enum column's, one layer over.

**A `Str` built below `db.zig`.** It cannot be: the lifetime marker comes from
the Scope and a Wire has none. So a `[]const Str` column is walked twice — once
by the driver to build the slice and dupe the bytes, once by `keptList` to
attach the markers — and costs **two allocations per row** rather than one.
A Row that reads the column as `[]const []const u8` pays one. The asymmetry is
`Str`'s trap being worth an allocation, which is the same trade `Str` already
is everywhere else; it is stated here rather than discovered.

## What it costs

Against ADR 0018's four axes:

- **Allocations per request.** One per array column per row, two when the
  elements are `Str`. Paid only by a Row that reads one; no existing path
  gains an allocation, and the budget test in `http/app.zig` is unmoved.
- **Memory per idle connection.** Nothing. Everything here is per row and in
  the request arena.
- **Throughput and p99.** Unmeasurable on any path that does not read an
  array: the dispatch is `comptime types.listElement(F) != null`, which is a
  branch the compiler removes.
- **Binary size.** `readList` and `arrayFits` are instantiated per element
  type and only for the types a Row actually declares. A project that reads no
  arrays links none of it.

## The rule it makes shorter

A streamed row cannot hold a list column, and the Refusal says so. That was
already true of `Json(T)` for its own reason — parsing costs an allocation per
row — and having a second instance turns two special cases into one sentence:

> **A streamed row holds only what the read buffer already holds.**

An array does not qualify. It arrives as a header and a run of length-prefixed
elements, so there is no `[]T` in the buffer to point at, and building one per
row is exactly the unbounded growth `stream` exists not to do.

## Consequences

- `wire.zig` gains a tenth call, and it is the only one that takes an
  allocator. A second driver has to implement it.
- `postgres.zig` reaches past pg.zig's API for the second time, after
  `revive`. Both are marked to delete when the driver stops needing them; both
  are in the one file allowed to know pg.zig exists (ADR 0039).
- `dialect.accepts` now judges a scalar `Str` too, which it previously
  declined to do by accident — `Str` has no `nilo_column` and fell through to
  `null`. A `Str` over a `uuid` column is now caught at startup. That was not
  the point of this change; it was an inconsistency the list rule made visible,
  because judging `[]const Str` while declining `Str` is not a rule anybody
  could state.
- `insertMany` is now buildable, and is
  [ADR 0053](./0053-a-batch-is-one-array-per-column.md).
