# A raw parameter is converted the way a Row's is

Every statement this module writes takes a `sql.Uuid` without complaint. The
Row says what the column is, `valuesOf` looks the parameter up against it, and
`forWire` turns the value into the shape the driver binds.

`db.raw` and `db.exec` have no Row. So the tuple went to the driver exactly as
the caller wrote it, and a `Uuid` arrived as a Zig struct:

```zig
_ = try db.exec(c,
    \\INSERT INTO partner_capabilities (partner_id, capability)
    \\VALUES ($1, $2)
    \\ON CONFLICT DO NOTHING
, .{ partner_id, tag });        // partner_id: sql.Uuid
```

It compiles. On Postgres it is `error.QueryFailed` at run time with nothing
logged anywhere ([ADR 0146](0146-a-statement-that-failed-says-what-the-database-said.md)
is the other half of that afternoon). On SQLite it is a `@compileError` from
inside zqlite. Adding `::uuid` changes nothing, because the value never reached
the server to be cast.

The workaround is to send the thirty-six characters and cast them back:

```zig
var text = partner_id.toText();
const id_text: []const u8 = &text;
_ = try db.exec(c, "… VALUES ($1::text::uuid, $2) …", .{ id_text, tag });
```

That costs an arena allocation per id and thirty-six bytes on the wire where
sixteen would do, and it is written at every call site. On a schema with 145
uuid columns, a bare `$1` id is most of what a hand-written statement binds.

## No Row was ever needed

This is the part worth writing down, because it is why the fix is four
functions rather than a design.

`forWire` switches on the **value's** type, and `WireWrite` takes a Dialect and
a bare type. Neither has ever consulted a Row. The mapping a Row's parameter
goes through was already available on the raw path; the only thing missing was
somebody calling it.

So `rawValuesOf(values, c)` walks the tuple and runs each field through the
same `forWire`. `RawValues(D, V)` answers `V` itself when nothing needs
converting, which is most calls, and `rawValuesOf` then hands the caller's own
tuple straight to the driver the way it always did. Nothing is allocated and
nothing is copied on a statement that binds integers and text.

## Three things only a hand-written call carries

A column's type is declared. A `db.raw` parameter is whatever somebody typed at
the call site, and three shapes turn up there that never reach `WireWrite`.

**A list written where it is used is `&.{ … }`** — a pointer to an array rather
than the slice a column is declared as. `WireWrite` answers about columns and
does not see one. `= ANY($1)` is the whole reason anybody writes a list into a
raw statement, so this is not an edge.

**A value with no runtime representation cannot be a tuple field.**
`.{ 1, 1.5, null }` is three comptime fields and the tuple built here is read
at run time. Each becomes the type both drivers already bind identically:
`comptime_int` to `i64`, `comptime_float` to `f64`, `null` to `?u8`. Nothing
about the bytes changes — pg.zig's `.comptime_int` and `.int` arms are the same
switch, and its `.null` and `.optional`-holding-null arms write the same four
bytes whatever the column is.

**An enum literal** is the fourth, and it gets better rather than merely
surviving: zqlite refuses one while compiling, and `@tagName` is how both
drivers send an enum anyway.

## It stays a tuple, and that is a fact about the drivers

pg.zig binds with `inline for (values)`, which takes a tuple and nothing else.
zqlite branches on `is_tuple` and binds a plain struct's fields **by name**, so
a rebuilt non-tuple would silently bind nothing to `?1`.

A named struct is therefore left exactly as it arrived, which is what it was
before this existed. `RawValues` answers `V` for anything that is not a tuple.

## The array of uuids, in both directions

`.in` is the spelling of `WHERE x = ANY($1)`, and it is what stops an N+1 on
every list that attaches children to its rows. Neither form of a uuid list
compiled:

```
sql/db.zig:2273: error: expected type '…![]const [16]u8', found '[]uuid.Uuid'
pg.zig src/types.zig:1586: error: cannot bind value of type *const []const [16]u8
```

The first is Zig's from inside this module. The second is a `@compileError`
from a dependency the reader never chose. Neither names a nilo concept.

A `Uuid` inside an array is `[]const u8`, not the `[16]u8` a scalar one binds
as, and there are two independent reasons. A scalar binds as the array because
the parameter tuple is all the driver has to read from and a slice would point
at a copy `where.valueAt` just returned; an array parameter has somewhere
better to point, the caller's own list, alive for the whole call. And pg.zig's
`UUIDArray` encoder reads `[]const u8` elements and takes either sixteen bytes
or thirty-six characters, while `[]const [16]u8` is `cannot bind value of type`
four frames inside the driver.

`BatchWrite` had already reached that answer, for those two reasons, when
batches landed. It is now `ArrayElement`, because it has a second caller: a
batch sends one array per column and an `.in` sends one array of the values
being matched, and both are `= ANY($1)`-shaped as far as the driver cares. The
batch's `Uuid` was fixed when batches landed and the `.in`'s was not, which is
what a name that says *batch* costs.

Reading is the other direction and it needed the same answer. `WireList` maps
a `Uuid` element to `[]const u8` and `keptList` takes a second walk to rebuild
the type from the sixteen bytes — the driver hands back the bytes and the bytes
are not the type. That walk allocates nothing beyond the `[]Uuid` itself,
because a `Uuid` is a value rather than a view of a buffer.

And `dialect.Postgres.accepts` had no case for `[]const Uuid` at all: it fell
to the `else`, answered null, and `schema.Expectation.accepted` reads an empty
list as *accept anything*. So a Row with a `uuid[]` column passed the startup
check without anything having looked at the column, and failed on the first
read. It answers `_uuid` now, which is Postgres's own name for the type.

## The alternative that was rejected

**A Refusal instead of a conversion.** The feedback offered it as the fallback:
if `raw` cannot take a `Uuid`, say so while compiling rather than at run time.
That is right about the symptom and wrong about the cause. A Refusal here would
be this module declining to do something it already knows how to do, four
frames from the code that does it for `db.select`, and the message would have
to end by telling the caller to write `$1::text::uuid` — a refusal whose remedy
is a workaround is a bug with a nicer error message.

The rule the module runs on is that a type means one thing. A `Uuid` bound to
`db.select` and a `Uuid` bound to `db.raw` meaning different things is two
rules for one type, and the second one is only there because nobody called the
converter.

**Requiring a Row for `raw`** was not considered for long. `db.raw` exists for
the 156 statements out of 398 that a condition cannot express, and most of them
answer something no Row describes.

## What it costs

Against [ADR 0018](0018-the-trade-budget-has-three-axes.md)'s axes:

- **Allocations per request: none added.** `RawValues` answers the caller's own
  type when no field moves, so a statement binding integers and text builds
  nothing. A statement that does bind a `Uuid` now allocates *less* than the
  workaround it replaces: the arena copy of the thirty-six characters is gone.
- **Bytes on the wire: 16 rather than 36** per uuid parameter.
- **Throughput:** unmeasured and expected to be nil. The walk is `inline for`
  over a tuple whose length is comptime, and the branch that skips it is a
  comptime type comparison.
- **Binary size:** nothing in a program that binds no type this module has a
  word for, because `RawValues` answers `V` and no code is generated.

## Consequences

- `RawValues`, `RawWrite` and `rawValuesOf` in `db.zig`; `BatchWrite` renamed
  to `ArrayElement` and called from two places.
- `WireList` and `keptList` handle a `Uuid` element, so a `[]const Uuid` column
  reads.
- `dialect.Postgres.accepts` answers `_uuid`, and three assertions in its test
  say so.
- No new Refusal. Nothing here is a mistake somebody makes while compiling any
  more — the shapes that used to fail now work.
