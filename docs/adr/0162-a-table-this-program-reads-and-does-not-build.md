# A table this program reads and does not build

[ADR 0153](./0153-a-migration-is-a-diff-against-a-snapshot.md) made the schema a
diff against the Rows. A port read it the week it landed and did not adopt it,
and the reason is one line in `table.zig`:

> A foreign key names the Row that owns the table, so that renaming that table
> moves this with it. A string would not.

That is right. It also means `comments.author_staff_id` cannot say it points at
`staff` without a `Staff` Row — and a `Staff` Row is part of the schema
`generate` diffs, so the tool emits `CREATE TABLE staff` for a table that has
existed for a year and whose real definition has twenty columns this program has
never needed. The same holds for `departments`, `deals`, `work_items` and
`projects`.

**So the tool was usable at 59 tables of 59 and unusable at 47 of 59.** Adopting
it meant declaring every table in one commit, which is the big-bang migration
that port exists to avoid.

## What it does now

```zig
pub const nilo_table = .{ .name = "staff", .managed = false };
```

Everything else about the Row is unchanged. `.references` may point at it,
`db.checking` still holds it against the live schema, and every statement reads
it the same way. What changes is only **who builds it**: `plan`, `createMissing`
and `generate` leave it alone.

One word, read in one place — `readSpec` — and carried on `Desc`, so the three
callers ask the same question the same way.

## The snapshot records it

`Desc.managed` is written to `migrations/snapshot.zon`, unlike `row` and
`renames`, which are not. `std.zon` omits a field equal to its default, so
`managed: true` is silence and `managed: false` is a line. **A program that
starts or stops building a table is then a visible change in a file under
review**, rather than a difference nobody can see.

That was the report's own ask, and it is the reason an external table stays in
the desired list rather than being filtered out before `plan` is called: the
drop loop reads the same list, so a Row that stops being managed would otherwise
look exactly like a Row that was deleted, and the plan would drop somebody
else's table.

## What the port did with it, which is more than this asked for

Every Row in it is `.managed = false`, not only the external ones, because that
is the truth: another tool owns all 59 tables and the binary builds none. That
much was expected. What was not is the table it then declared **for the first
time** — `staff`, two columns of ten, with no statement writing it and no
migration wanting it, purely so `db.checking` would hold them against the live
schema. `full_name` is read by name in seven statements and nothing had ever
checked it existed. They proved it by misspelling the column and watching the
boot refuse, naming the field and the table.

**So the word buys a check that could not previously exist.** Before it, a Row
was a claim to build a table, so declaring one for a table you only read meant
volunteering to create it; the only way to read a column safely was to not
declare it and hope. A Row that says it builds nothing is a way to say *these
columns must be there* about somebody else's table — which is a better argument
for this ADR than the one it was written with, and is recorded here in the
caller's terms rather than in the ones that were guessed.

## What adoption still costs

A table that goes from `.managed = false` to managed produces no `CREATE TABLE`
step, because the snapshot already describes it and the diff finds nothing to
do. That is correct — the table is already there — and it means **adopting an
existing table is not a migration nilo writes**. If the live table differs from
what the Row says, that is a step somebody writes by hand, which is what the
human review of a generated version is for.

## The alternatives that were rejected

**A string in `.references` instead of a Row.** It removes the need for the Row
entirely and gives up what the Row buys: renaming a table moves every reference
to it, checked while compiling. `table.zig` argues this already and the argument
is not weakened by a second use case.

**A separate list of external tables handed to the tool** —
`sql.cli.Tool(Db, &.{User, Org}, &.{"staff"})`. It keeps the knowledge out of
the type and puts it in a second place that has to agree with the first, which
is the annotation this framework does not have (ADR 0017).

**Leaving it, and telling a partial owner to write their own DDL.** That is the
state this came from, and it makes the tool an all-or-nothing bet on a schema
somebody else partly owns — which is most schemas that already exist.

## Consequences

- One word in the marker, one field on `Spec` and on `Desc`, two skips in
  `migrate.zig`.
- Old snapshots parse unchanged: a missing field takes its default, and the
  default is the behaviour every Row had before.
- `db.checking` is untouched, which is the half a partial owner needs most: the
  columns this program reads are still verified against the live schema,
  including on tables it will never create.
