# A column type can come from outside this module, and it travels as text

The schema half of a column type was open and the wire half was shut. A struct
or an enum carrying `pub const nilo_column = "money"` was judged at startup
like any other column — and then `db.zig` reached `WireRead`, matched nothing,
and the build failed several frames inside pg.zig. So a project could describe
a column it could not read.

The list that was closed is short and arbitrary in the way a chosen list always
is: `Str`, `Timestamp`, `Uuid`, `Decimal`, `Json(T)`, and a slice of the
scalars. Everything past it — `interval`, `inet`, `cidr`, `macaddr`, `money`,
`tsvector`, `xml`, every PostGIS type, every extension anybody installs — was
out, and each one would have been another branch in six places.

## What was decided

**A column type is a protocol, not a list, and the representation is text.**

Any struct or enum carrying three things is a column type, whoever wrote it:

```zig
pub const nilo_column = "money";
pub fn nilo_read(text: []const u8, arena: std.mem.Allocator) !Self
pub fn nilo_write(self: Self, arena: std.mem.Allocator) ![]const u8
```

The Dialect asks for it as `"col"::text` and binds it as `$1::money`; the type
turns those bytes into a value and back. That is one branch in `readAs`, one in
`bindAs`, one in `arrayOf`, one in `WireRead`, one in `WireWrite`, one in
`kept` and one in `forWire` — **the same seven places the old `isDecimal`
occupied**, which is the measure of what this cost: nothing, because the
special case was already there and was renamed into a rule.

`AsText(name)` is the protocol's smallest instance, for a type that is just the
text:

```zig
const Money = sql.AsText("money");
const Interval = sql.AsText("interval");   // shipped, as `sql.Interval`
const Inet = sql.AsText("inet");           // shipped, as `sql.Inet`
```

## Why text rather than a binary format

Text is the one representation Postgres guarantees for every type it has,
including the ones it does not ship. A binary protocol would be faster and
would need this module to know the format — which is exactly the knowledge it
is trying not to require, and the reason the closed list was closed.

The cost is honest and it is stated: a text column is a parse on the way in and
a print on the way out, where a type the driver decodes natively is neither.
For `numeric` that was already the deal ([ADR 0050](./0050-a-numeric-is-digits-and-a-string-in-json.md))
and it was the right one; for a type nobody has heard of, the alternative is
not a faster path, it is no path.

## `Decimal` is now an instance, and that is the argument

`Decimal` used to be a hand-written struct with a marker (`nilo_decimal`) that
existed for one reason: the Dialect had to know, while writing the SQL, that
this column casts. It is now `AsText("numeric")` — the same struct body, the
same `.text` field, the same JSON-as-a-string, and the marker is gone.

**The hardest column type this module ships turned out to be expressible in the
protocol without a special case.** That is the test a general mechanism has to
pass, and it is why the protocol is not four branches wider than it needs to
be. A protocol whose own author still needed an exception would have been a
list with extra steps.

One thing came free with it: the generated type name. A Refusal that prints a
column type used to say `Decimal`, and now says `types.AsText("numeric")` —
which says both what it is and which column, and is what a reader of the
message actually needs.

## Why `nilo_write` takes an allocator when nothing shipped uses one

Every text column this module ships holds its text, so `nilo_write` hands back
a field and never allocates. The allocator is there for the case that made the
protocol worth having: a type holding *structure*.

```zig
const Cents = struct {
    value: i64,
    pub const nilo_column = "numeric";
    pub fn nilo_read(raw: []const u8, arena: std.mem.Allocator) !Cents { … }
    pub fn nilo_write(self: Cents, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{d}.{d:0>2}", .{ … });
    }
};
```

Without it, a project's column type could only ever be a rename of `Str`, which
is not worth a protocol. With it, `valuesOf` grew a Scope parameter and became
fallible — and **for a Row with no text column the inferred error set is empty
and the `try` compiles to nothing**, which is what makes this free for everyone
who is not using it (ADR 0018's first axis).

## Half a protocol is a Refusal

Two mistakes are caught while compiling rather than at the first request:

- `nilo_read` without `nilo_write`, or the other way round. The pair is how a
  value gets there and back; half of it is a column that can be written and
  never read.
- Both, and no `nilo_column`. The name is what the casts on the two sides have
  to spell, so without it there is no statement to write.

Both are `sql/refusals/` files with rows in `build.zig`, the way every comptime
check in this repository is held ([ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)).

## What is still closed

**An array of a text column.** `[]const Decimal` is not judged by
`dialect.accepts` and is not read — the same boundary as before, unmoved.
Writing one *is* supported, because `arrayOf` casts through `text[]`, which is
how a batch insert of a `numeric` column already worked. Reading would mean
`readList` handing back `[]const []const u8` and a second pass to build the
values, which is a second allocation per row per column for a shape nobody has
asked for.

**A type whose text is not what Postgres prints.** `nilo_read` is handed the
output of `::text` and nothing else. A type wanting the binary form has to be
built into the driver, which is the closed list this replaces and is where the
next such type should stop and argue rather than being added quietly.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** Zero for a Row that has no text column — the
  error set is empty and the branch is comptime. One per value for a column
  type that builds its text, which is the caller's own `allocPrint` and is
  visible in their own code.
- **Memory per idle connection.** Nothing.
- **Throughput and p99.** Unchanged for everything that was already here: the
  branches replaced are the branches that were there, one predicate for
  another.
- **Binary size.** +0 stripped ReleaseFast on every example, because no example
  imports `nilo_sql`.

## Consequences

- `interval` and `inet` came off the checklist as two lines of `AsText` rather
  than as a column type each. They were Next 2 and they stopped being work.
- `types.isDecimal` is gone, replaced by `types.asText`, which answers *which*
  column rather than *whether* it is one particular column.
- A project can now read a PostGIS `geometry` without this module knowing PostGIS
  exists, which is the sentence the roadmap item was really asking for.
- The next column type this module is tempted to ship should be weighed against
  a project writing three lines. `Interval` and `Inet` are here because the
  checklist named them and because they cost one line each; a fourth wants an
  argument.
