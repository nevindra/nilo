# Roadmap input for nilo, from nodeflux-os

Findings from porting a working 59-table Postgres schema to `sql.migrate`
(ADR 123), so that the Zig port of **nodeflux-os** owns its schema instead of
borrowing the Go binary's goose migrations.

nodeflux-os is an internal ERP: Go + TimescaleDB, 30 goose migrations totalling
5,165 lines of SQL, 59 tables, 96 foreign keys, 85 CHECK constraints, 126
column defaults, 92 indexes of which 34 are partial, 31 `updated_at` triggers,
one view, one hypertable and 113 rows of reference data. A Zig port
(`backend-zig/`) has been serving the same API on nilo for some time, with every
context Row declared `.managed = false` (ADR 130) and checked at boot.

Three rounds so far. The first, against **v0.4.0** at `eb545fa`, filed ten
findings; nilo answered nine of them in ADRs 180, 181 and 123. The second re-did
the whole port on `636d7b6` and found three more. The third read every raw
statement of the port against the query surface of v0.6.0 at `de37265` and
filed items 81–94, which have [a section of their own](#the-query-surface-items-8194). This file is what is still
open, with the settled items kept to a paragraph each at the end so a number
cited from an ADR or a commit still resolves. The files are under
`nodeflux-os/backend-zig/src/schema/` and `nodeflux-os/backend-zig/migrations/`,
and every number here was measured on them.

Blunt on request. Where the design is wrong it says so, with the number that
shows it.

---

## Where this stands

| # | Finding | Status |
|---|---|---|
| 10 | A version is applicable only from Zig | Done, [ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md). `generate` writes the `.sql` twin, ledger row and all; `check` fails on a stale one. |
| 11 | `--baseline` parses the snapshot it is documented to ignore, and dies with a stack trace on an older one | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md). Both halves fixed, and an older snapshot is now read and upgraded rather than refused. |
| 12 | An enum column's `CHECK` cannot be named | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md), as `.check = .{ .<name> = .{ .words_of = .<column> } }`. |
| 13 | A `text[]` column has no default | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md). |
| 14 | The second kind of word: `.check`, `.trigger`, and functions, views and extensions at schema level | **Two of five done**, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md). `.check` and `.trigger` ship. Functions, views and extensions wait on a `sql.Schema` that does not exist; see below. |
| 1, 2, 3, 5 | `.default`, an enum column's `CHECK`, partial and ordered `.index`, `.name` on any constraint and the 63-byte guard | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md) |
| 4, 6 | Composite `.references`, and a target named as text | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md) |
| 7 | `--baseline`, and the generated block in a version file | Done, [ADR 123](./adr/123-a-migration-is-a-diff-against-a-snapshot.md) |
| 8 | `app.start(io)` then `listen()` never exits | Done, [ADR 180](./adr/180-work-that-needs-the-services-runs-on-their-loop.md) |
| 9 | `Date`, `Decimal` and `Jsonb` as `AsText` | Done in ADR 181: `sql.Date` is a type; `Decimal` stays `AsText` on purpose |

**Every item in this file is answered.** The order was 11, then 13, then 14
with 12 folded into it, then 10 — which is the order recommended below, with 13
taken on the way past because it is two lines of the same `literalText`.

What is left is one piece, and it is named rather than open: **functions, views
and extensions have nowhere to be written until there is a `sql.Schema`.** The
vocabulary is settled and the seam is not — `sql.Schema` replaces the
`&.{ Row, Row }` list that `cli.Tool`, `db.checking` and `migrate.tablesOf` all
take, so it is either a second spelling beside the list or a break. That choice
is its own ADR and its own round.

Three spellings landed differently from what was proposed, and all three for the
same reason — nilo has to write something in the middle:

- **A trigger is two words, `.when` and `.run`**, not one string. nilo writes
  `ON "work_items"` between them. Finding where that goes inside one string is
  parsing SQL; asking the marker to write it means the table is written twice,
  and the second copy stops matching the day it is renamed.
- **An enum column's check is named through `.check`**, as
  `.{ .words_of = .kind }`, rather than beside the column in `.default`. One
  word with two key rules is how a reader ends up sure they know which one they
  are looking at, and the name is what both spellings are about.
- **The `.sql` twin is written from the compiled manifest**, because a version's
  hash is chained onto the one before it. One case writes nothing and says so:
  `--baseline` rewriting a version 1 whose `before` or `after` hold hand-written
  steps, since those are Zig nothing has compiled yet.

---

## The query surface, items 81–94

Filed in `nodeflux-os/docs/nilo-feedback.md` from reading all 171 raw call
sites of the port against ADR 218, `rawPage` and `rawExactlyOne`. The numbers
are that file's, so an item cited from either side resolves. Answered on the
branch `sql-improvements`.

| # | Finding | Status |
|---|---|---|
| 81 | `sql.given` on `.in`: an absent list filter is not an empty one | Done, [ADR 149](./adr/149-a-filter-that-is-absent-is-not-a-filter-that-is-null.md). Null drops the term, a present empty list is still the list. |
| 82 | `rawPage` takes no `{order}` hole | Done, [ADR 205](./adr/205-a-raw-statement-can-carry-its-total.md), as `db.rawPageOrdered`. |
| 83 | A parent cannot be spelled flat on the wire | **Open.** Not taken up; it moves the JSON shape, not the query. |
| 84 | `.ieq` is named in a refusal and is not an operator | Done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md) and [ADR 052](./adr/052-a-set-operation-over-one-table-is-a-condition.md): `.ieq` and `.not_ieq`, the expression an `.ignoring_case` unique indexes. |
| 85 | An aggregate cannot carry a filter | Done, [ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md): a `.where` on the entry is `FILTER (WHERE …)`, and follows a `.references` into the row it points at, joined once. |
| 86 | A narrower Row cannot be ordered by a column it does not carry | Done, [ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md). Refused on a grouped Row, by name. |
| 87 | Children: an order, a condition, and a count | Done, [ADR 218](./adr/218-a-row-may-carry-its-parent-its-children-or-a-sum.md), as `nilo_children`: `.order` and `.where` on a list, and `.{ .count = C }` read by a correlated subquery. |
| 88 | A `numeric` that is not money, read as `f64` | Answered in the documentation, the answer the item said was enough: a `Quantity` column type in [the tables guide](./guide/sql/tables.md#a-numeric-that-is-not-money), and a line in [decided](./decided.md). |
| 89 | An aggregate over a product of two columns | Not an ask. Stays `db.raw`, written down in ADR 218's *What is still refused*. |
| 90 | No `INNER JOIN` over a nullable reference | Not an ask. `?P` with `.{ .ne = null }` in the condition stands. |
| 91 | The date, not only the instant, and a column on the right of a condition | `.today` done, [ADR 181](./adr/181-the-marker-has-two-kinds-of-word.md), in `.set` and in a condition. A column on the right, the larger ask, is not taken up. |
| 92 | Docs: `.exists` through a column no reference covers | Done: the reference and the guide say `.via` names such a column. |
| 93 | A slow query, from the route down to the plan | Done: `sql.Sent.route` ([ADR 108](./adr/108-a-statement-can-be-watched.md)) and `db.explain` ([ADR 232](./adr/232-a-read-can-show-its-plan.md)); a raw statement already had a plan name, and only the doc said otherwise. Open: a stable name for a statement whose `ORDER BY` a `sql.Ordering` chose, and counts per statement on the metrics page. |
| 94 | Where the bugs are now: the statements nilo tells us to write raw | **Open.** A question rather than an ask; not taken up. |

---

## The port on `636d7b6`

The fourteen section files under `src/schema/` were rewritten onto ADRs 181
and 123, `db generate --name schema --baseline` re-derived version 1,
and a fresh database migrated from it was diffed against the goose-migrated
reference: `pg_dump --schema-only` of both, split into facts (a column with
its type, nullability and default; a constraint with its name and body; an
index with its name, columns and predicate; a trigger; the view), compared as
sets.

**875 facts on each side, 875 in common, zero apart.** Round one ended with
50 names apart (42 indexes, 8 uniques), because nilo derived them and Go had
named them; `.name` on `.index` and `.unique` closes all 50. The suite is
481 of 481 on a database migrated from the new baseline, the full stack comes
up under process-compose against the dev data (97 deals, 32 staff, 447
events), and SIGINT brings the API down in two seconds through
`db.expecting(manifest.head)`, which replaced the gate `Db` item 8 had to
describe.

| | Round one (`eb545fa`) | Round two (`636d7b6`) |
|---|---|---|
| Steps `generate` wrote | 149 | 186 |
| Steps written by hand | 141 | 73, of which 10 are reference data |
| `ALTER TABLE … SET DEFAULT` clauses by hand | 126 | 2 (both `text[]`, item 13) |
| `CHECK (col IN (…))` by hand | 29 | 1 (item 12) |
| `CREATE INDEX` by hand | 39 | 1 (over `lower(btrim(site))`, by design) |
| Composite foreign keys as `.data` | 2 | 0 |
| Lines in `src/schema/` | 3,876 | 3,444 |
| Tables split between a Row and a step | 56 of 59 | 46 of 59 |
| Names differing from the reference | 50 | 0 |

What is still by hand is exactly item 14: 31 `updated_at` triggers and their
one function, 59 `CHECK` clauses over an expression or two columns (in 27
steps), one index over an expression, the view, the hypertable, the extension
and the seed rows. On 18 of the 46 split tables the only thing left in the
step is the trigger.

### What worked

- **The tool is 40 lines.** `src/db.zig` is `sql.cli.Tool(sql.Db,
  schema.tables)`, argument parsing, and a `Settings` read so `DATABASE_URL`
  is spelled once. All six commands worked the first time they were run, on
  both rounds.
- **Errors are sentences, and the vocabulary is learnable from one example.**
  The 63-byte guard fired on the first build of round two, naming the table,
  the derived name, its length and what to do. Thirteen section files were
  then converted in parallel by nine assistants working from one converted
  file and a one-page recipe; the first build afterwards compiled, and the
  one wrong default in 875 facts was the recipe's own mistake. A rebuild of
  the tool after editing one section file is 1.7 s.
- **`generate` and `check` need no database**, and `verify` catches a
  version that ran and was then edited, naming the version, the hash it ran
  as and the hash it has now, with "put that version back and write what you
  meant as a new one". That is the right sentence.
- **The two boot guards are the best part of the design**, and both work:
  `expect` refused the goose-migrated database with

  > `nilo_sql: this binary was built for schema version 1, and the database is at 0. 1 migration(s) have not been applied. Run them before serving: a request that reads a column the database does not have is a 500, and the first one arrives the moment this process accepts a connection.`

  and `db.checking` holds the 57 context Rows against the live schema on the
  same boot.
- **`.managed = false` is the right default for a port.** Every context kept
  its Row as a projection and nothing about reading changed.
- **One transaction per version behind an advisory lock, no `down`,
  `destructive` named in the header.** No complaints; ADR 123's argument
  for each holds.
- **Each section file is self-contained**, its Rows and the steps that
  complete them in one file, and both rounds took one working session each
  because of it. That property is worth keeping whatever else changes.

---

## The five that were open

Kept as they were written, because the argument in each is what the ADR answering
it was decided against. The status table above says which ADR that is; where a
spelling landed differently from what is proposed here, the ADR says why and a
note in the section below says so too.

### 10. A version is applicable only from Zig

This is not a gap in the design; it is the design. The source is a Zig type,
the diff runs at comptime and `manifest.zig` is a module the server imports,
so nothing about *authoring* a version can happen without a Zig compiler.
dbmate, goose and flyway are language-agnostic because their unit is a `.sql`
file and a ledger table, and that is exactly the trade ADR 123 makes the
other way, for the reasons it gives. Prisma, Django, Ecto and Drizzle make the
same trade; Atlas is the one tool that diffs *and* stays language-agnostic,
and it pays with a full SQL parser, which this design rightly refuses.

What does not have to be Zig-only is **applying** a version, and today it is:

- `status --sql` prints the waiting versions' statements, but it opens a
  database to know which are waiting, so a person with `psql` and no Zig
  cannot get the SQL at all.
- What it prints has no ledger row. A DBA who applies it by hand leaves
  `nilo_migrations` behind, and the next boot refuses with "the database is
  at 6" while every table is at 7.
- The ledger's shape (`version`, `name`, `hash`, `applied_at`, `ms`) is
  nowhere a non-Zig program can read it from.

The cheap half: **`generate` writes a `.sql` twin beside every version**,

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

containing the version's statements in order, wrapped in `BEGIN`/`COMMIT`,
ending with the ledger row `generate` already knows every field of
(`INSERT INTO nilo_migrations (version, name, hash, applied_at, ms) VALUES
(7, 'work_items_get_a_priority', '<hash>', now(), 0)`), and regenerated
whenever the `.zig` is. `check` compares the two so a `.sql` cannot go stale.
Then `psql -f`, dbmate, a CI job with no toolchain, or a DBA on a jump host
can bring a database to head, `expect` accepts it, and `verify` still holds
the hash. The ledger's columns go in `reference.md` as a contract.

What that does not give: a version written in SQL by somebody else and
picked up by nilo. That is authoring, it stays Zig, and it should; the
`.sql` twin is an output, never an input.

For nodeflux-os this does not bite, since the Go binary and its goose
migrations are the thing being replaced. It bites the first program whose
database is shared with a service in another language, and the first
deployment where migrations are run by somebody who is not shipping the
binary. Of everything in this file it is the one most likely to make a team
outside this one say no, and it is not about the vocabulary at all.

### 11. `--baseline` reads the snapshot before it ignores it

`guide/sql/migrations.md` says `--baseline` "ignores `snapshot.zon`
entirely", and ADR 181 says a snapshot in the older shape "is refused with a
parse diagnostic naming `column`". From the CLI, neither is what happens. On
the round-one snapshot (`.column`/`.target` on every reference):

```
$ zig build db -- generate --name schema --baseline
error: ParseZon
/…/lib/std/zon/parse.zig:1043:9: 0x1351d9a in failTokenFmtNote__anon_179448 (std.zig)
        return error.ParseZon;
        ^
… forty more lines of stack …
```

`migrations.generate` calls `read()` first and branches on `opts.baseline`
second (`sql/migrations.zig:293-294`), and `read()` parses the snapshot with
`snapshot.parse(gpa, text, null)` (`:173`), so the diagnostic the ADR
promises is thrown away before it reaches anybody. This is the one path
where the old snapshot is guaranteed to be present, because re-deriving is
what you do after a shape change. The workaround is `rm
migrations/snapshot.zon` first, which is the shell script ADR 123 set out
to retire. Two fixes, both small: skip `read()`'s snapshot half when
`opts.baseline` is set, and pass a `Diagnostics` so the non-baseline
`generate` and `check` print the sentence rather than the trace.

### 12. An enum column's `CHECK` cannot be named

`sku_product_types.kind` is `text CHECK (kind IN ('product', 'other'))`, and
the Go schema named it `sku_product_types_kind_is_known`. nilo names an
enum's check `<table>_<col>_check` and offers no `.name` for it, so the
derived `sku_product_types_kind_check` would be a second name for a
constraint a test reads out of `pg_constraint` by the first one
(`src/product/product_test.zig:524`). The column stays a `nilo.Str` with its
`CHECK` in a step, which is the round-one shape for exactly one column.

It is one column here, but the reason it is one is that Postgres's own
default happens to be `<table>_<col>_check` and Go let Postgres name 28 of
the 29. A schema written by hand names them all. Whatever spelling item 14
gives `.check`, the enum's check should take the same `.name`, and the
natural place is beside the column's default, which already keys on the
column.

### 13. A `text[]` column has no default

`agents.read_tags text[] NOT NULL DEFAULT '{}'` and `write_capabilities`
beside it. `literalText` takes text, a number, a bool or an enum word, and
`[]const Str` is none of them, so the two `SET DEFAULT '{}'` clauses are the
last two defaults written by hand. `&.{}` is the obvious spelling and `'{}'`
is what both databases would want written; anything non-empty can stay a
step.

### 14. The second kind of word

ADR 181 accepted the principle and built none of it. The principle: a
`CHECK` body is a string the compiler cannot read, and it is also a **named
object with a text**, which a diff owns completely. Same name and same hash,
nothing to do; same name and a new hash, replace; name gone, drop. The
compiler checks the name and where it hangs, the database checks the body
inside the version's transaction, which is the same moment a `.data` step is
checked today, so nothing is lost against the present design.

The ADR left it open on one question: what closes the kind is the list of
object kinds whose replace is mechanical. From this schema, that list is
five and nothing else in 59 tables asked for a sixth:

| Object | Replace |
|---|---|
| a `CHECK` | `DROP CONSTRAINT` then `ADD CONSTRAINT` |
| a trigger | `DROP TRIGGER` then `CREATE TRIGGER` |
| a function | `CREATE OR REPLACE FUNCTION` |
| a view | `CREATE OR REPLACE VIEW` |
| an extension | `CREATE EXTENSION IF NOT EXISTS`, and it is never dropped |

A generated column, a collation, a rule, a policy, a Postgres `ENUM` type:
still a `.data` step until somebody brings a case, which is ADR 123's own
rule.

**What a table looks like.** Every fact about `work_items` in one place. The
first five words are what landed; `.check` and `.trigger` are the proposal:

```zig
pub const WorkItem = struct {
    pub const nilo_table = .{
        .name = "work_items",
        .key = .id,
        .default = .{ .created_at = .now, .updated_at = .now, .priority = .normal },
        .index = .{
            .{ .columns = .{.assignee_staff_id}, .where = .{ .assignee_staff_id = .{ .ne = null } },
               .name = "work_items_assignee_idx" },
        },
        .references = .{
            .department_id = .{ "departments", .id },
            .epic = .{ .columns = .{ .epic_id, .department_id },
                       .to = .{ "work_epics", .{ .id, .department_id } },
                       .name = "work_items_epic_is_on_the_same_board" },
        },
        .check = .{
            .work_items_sku_product_and_deal_are_exclusive =
                "sku_product_id IS NULL OR deal_id IS NULL",
            .work_items_range_runs_forwards =
                "start_date IS NULL OR target_date IS NULL OR start_date <= target_date",
        },
        .trigger = .{
            // What shipped is two halves, because nilo writes `ON "work_items"`
            // between them (ADR 181).
            .work_items_updated_at = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
    };

    id: sql.Uuid,
    department_id: sql.Uuid,
    priority: Priority,
    start_date: ?sql.Date,
    target_date: ?sql.Date,
    created_at: sql.Timestamp,
    updated_at: sql.Timestamp,
    // …
};
```

The key of each entry is the object's name, so the 63-byte guard and the
two-entries-one-name refusal apply as they do to a `.unique`; the value is
the text. `generate` emits them after the table's `CREATE`, a changed body in
a later version emits the replace, and the snapshot records name and hash.

**What the schema looks like.** The objects that hang off no table:

```zig
pub const schema = sql.Schema{
    .extensions = &.{"timescaledb"},
    .functions = .{ .set_updated_at = @embedFile("sql/set_updated_at.sql") },
    .tables = &.{ org.Department, org.Staff, work.WorkItem, … },
    .views = .{ .sku_catalogue = @embedFile("sql/sku_catalogue.sql") },
};
```

Order is fixed by kind and the tool owns it: extensions, functions, tables
in reference order, each table's checks and triggers, views, then the
version file's `after`. That puts a 60-line view in a `.sql` file with
highlighting rather than in sixty `\\` lines, and it retires the `before`
slot's only use in this port.

**What it does to this port:**

| | `636d7b6` | With item 14 |
|---|---|---|
| Hand-written steps | 73 | 11: ten seed inserts and `create_hypertable` |
| Tables split between a Row and a step | 46 | 0 |
| A changed `CHECK` body | a hand-written `ALTER TABLE` | diffed |
| A renamed trigger | `DROP`, `CREATE`, by hand, in the right order | diffed |

**What it deliberately does not do:** parse SQL. A named text is opaque to
nilo and compared by hash, which is what keeps the vocabulary closed while
being larger than three.

---

## Two notes rather than items

**A default on an `AsText` column is text on the way in.** `quantity
numeric(14,3) DEFAULT 1` is written `.quantity = "1"` and Postgres stores it
as `'1'::numeric` where Go's is `1`. The two are the same default and
`pg_dump` prints them differently; the comparison above normalises that one
spelling and nothing else. Not worth a word in the marker.

**ADR 181's "the context declares its own Row managed" is right, and it has
a cost this port has not paid yet.** The contexts' Rows double as responses,
so a managed one carries every column the table has, and 8 of the 59 do not:
`work.WorkItem`, `sales.Deal` and six others leave out `created_at` and
`updated_at` because nothing they answer reads them. Adding the columns is
the whole of the work for those 8 (47 already carry every column; the 4
reimbursement tables have no Row outside the schema module at all), but it
changes the JSON those Rows serialise to, which is the contract the Go API
still serves. So `src/schema/` stays for now, 3,444 lines, and its header
says why. The migration path is one context at a time, which is what the
by-name `.references` was for. This is ours to do, not nilo's.

---

## Settled

One paragraph each, kept so a number cited from an ADR or a commit still
resolves. The full arguments are in the ADRs that answered them.

**1, 2, 3. `.default`, an enum column's `CHECK`, partial and ordered
`.index`.** The argument was that ADR 123's bar ("a word gets into the
marker if the compiler can check it") was right and its line was drawn short
of it: 126 defaults, 29 `IN (…)` lists and 34 partial indexes were all
decidable while compiling and all ended up in strings, so the schema was
*less* checked than the vocabulary would have been. Of the 126 defaults not
one was the "NOT NULL added to a table with rows" case the ADR reserved the
word for; 86 were `now()` and 40 were literals every insert relies on. ADR
181 accepted it in those words. Two spellings landed differently from what
was proposed, both better: `.{ .ne = null }` for `IS NOT NULL`, because that
is how the where walker already spells it, and `.priority = .normal` rather
than `"normal"`, because a column that holds an enum's word takes one.

**4. Composite `.references`.** Two keys in this schema, both the same-board
rule, both written as `.data` beside a `.unique` they needed. ADR 181:
`.columns`/`.to` keyed by a label, written as a table constraint so
one-column keys are byte-identical to before, and `.exists` joins on every
column of the key.

**5. `.name` on `.unique`, and 63 bytes.** Six derived names had lost their
meaning and two were cut down by Postgres at 63 bytes in a `NOTICE` nothing
reads. ADR 181: `.name` on any entry, the guard on both dialects, and two
entries deriving one name refused. Round two used it 50 times.

**6. `.references` named a type, so a context-per-directory program declared
every table twice.** ADR 181: a target may be the table's name, and the
type check moved to `orderOf`, where every Row is in one comptime list, so a
name no Row claims is still a compile error. The port has not folded its
schema module yet; see the note above for why.

**7. `generate` could not re-derive, and the version file had no slot for a
hand-written step.** ADR 123: `before ++ generated ++ after` with the
generated block between two marker lines, `--baseline` rewriting version 1
in place, three refusals. Item 11 is the one hole in it.

**8. `app.start(io)` then `listen()` never exited with a Postgres pool.**
ADR 180: refused with `error.StartedOnAnotherLoop`; `app.before(f, args)`
is the phase, inside `listen()`; `db.expecting(version)` is the guard, a
call rather than a field because the field cost 17,296 bytes in every
program with a `Db`. The port's gate `Db` is deleted.

**9. `Date`, `Decimal` and `Jsonb` were `AsText`.** `sql.Date` landed, read
as the column on both databases. `Decimal` stays `sql.AsText("numeric(14,3)")`
on purpose (`numeric`'s binary form is a base-10000 digit vector and the text
round-trips every digit), `Json(T)` already existed. Accepted.

**What the round-one numbers said.** 149 generated steps beside 141
hand-written; 56 `ALTER TABLE` statements carrying 126 defaults and 85
CHECKs; 39 `CREATE INDEX`; 637 lines of SQL inside Zig strings; 3,876 lines
against the Go baseline's 1,483; `work_items` a Row at line 138 of
`work.zig` and eight steps from line 418. On those numbers the
recommendation for this codebase was to let SQL own the schema and nilo own
only the ledger, because half the schema was outside the diff. Round two
puts 186 of 259 steps inside it, the Rows own the schema, and that
recommendation is withdrawn.
