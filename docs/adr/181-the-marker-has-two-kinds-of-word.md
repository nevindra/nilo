# The marker has two kinds of word: one the compiler checks, one the database does

**Status:** accepted
**Topic:** [sql-migrations](../design/sql-migrations.md). How a diff becomes a version and reaches a database is [ADR 123](./123-a-migration-is-a-diff-against-a-snapshot.md); this one is what a Row's `nilo_table` and a program's `sql.Schema` may say, which is what that diff reads.

## Context

A migration is a diff of the program's types against a snapshot, so what the types can say is what the tool can generate, and everything else is SQL somebody writes by hand in a step. The bar was set with the tool: **a word gets into the marker if the compiler can check it**, which is this repository's thesis applied to a schema. The first line drawn from it was three words, `.unique`, `.index` and `.references`, with a default, a check constraint and a partial index left as SQL in a step.

A 59-table port ([`docs/input_from_nodeflux.md`](../input_from_nodeflux.md)) showed the line was drawn short of the bar. Its generated schema was right, a `pg_dump --schema-only` differing from the goose-migrated one in six constraint names, and what it had to write by hand beside the Rows to get there was this:

| Written by hand | How much |
|---|---|
| `ALTER TABLE … SET DEFAULT` | 126, on 53 of 59 tables: 86 are `now()` on a `created_at`, 40 are literals every insert relies on |
| `CHECK (col IN (…))` | 29, each beside a Zig enum holding the same words |
| `CREATE INDEX` | 39 of 92: 34 partial, 18 ordering a column downwards |
| Constraint names | 6 lost their meaning to the derived spelling, **2 silently truncated by Postgres at 63 bytes** |
| Foreign keys | 2 spanning two columns, as steps, with the uniques they need declared separately |
| A second declaration of every table | 3,876 lines, because `.references` named a Zig type and a program whose contexts may not import each other cannot name a sibling's Row |
| `CHECK` bodies and triggers | 73 steps, and 46 tables described in two places |

Every row but the last is decidable while compiling. The last is not, and it showed the bar has a second half: a migration tool also **diffs**, and a `CHECK` body the compiler cannot read is still a named object with a text, which a diff owns completely without reading a token of it.

## Decision

**The marker has two kinds of word, and a program's whole schema is one value.**

| Kind | Checked by | Diffed by | Words |
|---|---|---|---|
| Typed | the compiler | the snapshot, by value | columns, `.key`, `.unique`, `.index` (with `.where` and a direction), `.references`, `.default`, an enum column's `CHECK`, `.filled`, a `.name` on any constraint |
| Named text | the compiler checks the name and where it hangs; the database checks the body, inside the version's transaction | the snapshot, by name and hash | `.check` and `.trigger` on a table; functions, views and extensions on the `Schema` |

The refusal that held from the start still holds: **nothing the compiler could check is taken as a string.** `.where = "deleted_at IS NULL"` stays refused, and so does `.default = "'draft'::text"`.

### The schema is one value, and the tool owns the order

```zig
pub const schema = sql.Schema{
    .extensions = &.{"pgcrypto"},
    .functions = &.{
        .{ .name = "set_updated_at", .body = @embedFile("sql/set_updated_at.sql") },
    },
    .tables = &.{ Org, User, Post },
    .views = &.{
        .{ .name = "sku_catalogue", .body = @embedFile("sql/sku_catalogue.sql") },
    },
};

db.checking(schema);
const Tool = sql.cli.Tool(Db, schema);
try sql.migrate.createMissing(&db, &run, schema);
```

**`sql.Schema` is the only spelling** that `cli.Tool`, `db.checking`, `createMissing`, `addMissingColumns` and the plan take. A program with tables and nothing else writes `.{ .tables = &.{ … } }`. One value is the point: the tool, the startup check and the boot cannot be handed different lists, and every Row being in one place is what lets a foreign key name a table as text and still be type-checked (below).

**The tool owns the order**: extensions, functions, tables sorted by reference, each table's indexes and triggers, then views. In a diff a stale or moved view is dropped first, because a view reading a column about to go makes `DROP COLUMN` refuse, and made last, after every table is in its final shape; a function nobody names any more is dropped after the tables whose triggers named it, and an extension last of all.

### The typed words

```zig
pub const nilo_table = .{
    .name = "work_items",
    .key = .id,
    .default = .{ .created_at = .now, .priority = .normal, .position = 0 },
    .filled = .number,
    .unique = .{
        .{ .columns = .{ .department_id, .number },
           .name = "work_items_number_is_unique_per_board" },
    },
    .index = .{
        .{ .columns = .{.assignee_id}, .where = .{ .assignee_id = .{ .ne = null } } },
        .{ .columns = .{ .department_id, .{ .created_at = .desc } } },
    },
    .references = .{
        .department_id = .{ Department, .id, .cascade },
        .assignee_staff_id = .{ "staff", .id },
        .epic = .{
            .columns = .{ .epic_id, .department_id },
            .to = .{ "work_epics", .{ .id, .department_id } },
        },
    },
};
```

**`.unique` and `.index`** are checked against the Row's own columns. The tuple shape is the one `conflictColumns` already reads for an upsert target. `.ignoring_case` is a modifier rather than a word, and it is where the Dialect earns its seam: SQLite writes `(email COLLATE NOCASE)`, Postgres `(lower(email))`. An index takes a direction per column and a `.where`, and **the predicate is the where walker's own grammar**, four terms and every shape the port's 34 partial indexes needed: `.x = null`, `.x = .{ .ne = null }`, `.x = .word`, `.x = .{ .ne = "draft" }`. A name that is not a column is a Refusal naming the near miss, and a literal of another type does not compile. An index over an expression, `lower(btrim(site))`, is a step.

**`.default`** takes `.now`, refused on anything but a `sql.Timestamp`, or a literal of the column's own Zig type: a number, text, a bool, an enum's word written as the word (`.priority = .normal`), or a list for an array column (`&.{}`, `&.{ "deals", "work" }`). Each list element goes through the element type, and every element is quoted with `\` and `"` escaped inside it, because a Postgres array literal is its own grammar where `,` separates and `{` nests; the whole literal then goes through `quoteLiteral`. A default the database has to work out, `DEFAULT (lower(x))` or `ARRAY(SELECT …)`, is a step. When a `NOT NULL` column is added to a table with rows, `add_column` asks for a backfill only when there is no default, which is the one moment a default was once thought to matter. The same word in an update's `.set`, `.set = .{ .updated_at = .now }`, writes the same expression with nothing bound: the database's clock rather than the server's, because rows stamped by two servers whose clocks disagree sort in an order neither wrote, and on Postgres the start of the transaction, so everything one `Tx` stamps carries one instant. A column whose type is an enum keeps `.now` as that enum's value; any other column refuses it.

**A Zig enum read as a column** is `text` with `CHECK ("col" IN (…))`, named `<table>_<column>_check` unless `.check` names it (below). The words go in the snapshot, so adding a tag to the enum is a migration rather than an insert refused at run time. An enum that declares `pub const nilo_column = "user_role"` names a Postgres `ENUM` whose words are the database's, and nilo neither writes nor judges them; that is what lets the boot check judge an enum column **only on a Row this program builds**, and decline a `.managed = false` one ([ADR 130](./130-a-table-this-program-reads-and-does-not-build.md)).

**`.name`, and 63 bytes checked on both databases.** Postgres reports a violation by constraint name and nothing else, so a name is how a violation becomes a sentence. Postgres also cuts an identifier at 63 bytes and says so in a `NOTICE` nothing reads, leaving a snapshot holding a name the database does not have, so every name, given or derived, is checked at 63 whatever the Dialect: a schema that compiles for one database and quietly loses a name on the other is the opposite of what one type describing both is for. Two entries deriving one name are a Refusal.

**`.filled`** names a column the database fills by a means the marker cannot say: a `DEFAULT` in a step, `gen_random_uuid()` on a key, a trigger. It renders no DDL and no diff. It exists for one check: **an insert that leaves out a column nothing fills is a Refusal naming every such column**. A column that is not optional, not the integer key a sequence fills, not given a `.default` and not in `.filled` has nothing to fill it, and leaving it out was a `NotNullViolated` the first time the insert ran; `insert`, `insertMany` and both upserts ask. The check is read off the Row that owns the table, so a narrow Row borrowing it cannot hide a column it has no field for, and it skips a `.managed = false` table, whose defaults were never the marker's.

**`.references` names a Row type or a table, and the type check runs on both.** The short form, `.org_id = .{ Org, .id }`, is checked inside the Row: `.id` is a column of `Org`, and **`org_id`'s Zig type is `Org.id`'s**, so a foreign key whose sides disagree does not compile rather than failing at the first insert in production. A target written as text, `.{ "staff", .id }`, is for a table whose Row this file may not import, and it is checked one level up: every Row is in the `Schema`, so `table.assertTargetsResolve` resolves each name against that list and runs the same two checks. A name no Row in the list declares is a compile error saying to add the Row, with `.managed = false` if the program only reads it, or to point at its type. A key over several columns is labelled and written `.columns`/`.to`, and is a `CONSTRAINT … FOREIGN KEY` at the end of `CREATE TABLE`; a one-column key keeps its inline `REFERENCES`, so no table written before the long form arrived changed. `.exists` joins on every column of the key, because joining a composite key on its first column answers a wider question than the schema asked.

**Only a Row that owns a `.name` may carry these words.** A Row that borrows another (`nilo_table = User`) is a query type, and a query type declaring schema is a Refusal.

### Rendered while compiling, so the DDL and the diff cannot disagree

A `Column.default` holds `now()` or `'normal'`, the text as this Dialect spells it, not the value it was written from; it is the arrangement `sql_type` has always had, one string both what `CREATE` writes and what the diff compares. The checking happens before the rendering. It also keeps the two databases' answers honest rather than averaged: `.now` on SQLite renders milliseconds where Postgres has microseconds, a stated cost, because SQLite has no microsecond clock and a default pretending otherwise would disagree with the values nilo writes.

**What SQLite cannot do it says in one sentence.** It cannot alter a column's default or replace a constraint (`Dialect.can_alter_column` and `can_alter_constraint` are false), so a column that moved in ways SQLite cannot follow raises one Problem naming everything that moved, because a column that changed three ways needs one rewrite, not three.

### The named-text words

```zig
.check = .{
    .work_items_sku_product_and_deal_are_exclusive = "sku_product_id IS NULL OR deal_id IS NULL",
    .work_items_priority_is_known = .{ .words_of = .priority },
},
.trigger = .{
    .work_items_updated_at = .{
        .when = "BEFORE UPDATE",
        .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
    },
},
```

**The diff owns a named text without reading it**: same name and hash, nothing; same name and a new hash, drop and create; a name the types no longer have, drop. The object kinds are the five whose replace is that mechanical, a `CHECK`, a trigger, a function, a view and an extension, and nothing in 59 tables asked for a sixth.

- **The key is the name.** A check or a trigger has no columns to derive a name from, and an unnamed one is reported under a name the database made up, which is the whole of what Postgres says when a row breaks it. Keying by name also gets the 63-byte guard and a duplicate refused as a duplicate struct field, before `sql/table.zig` is reached.
- **A trigger is two halves and the table is not one of them.** nilo writes `ON "work_items"` between `.when` and `.run`, because finding the middle of one string means parsing SQL and writing the table twice leaves a trigger on the old table the day it is renamed. The hash puts a `\x00` between the halves.
- **`.{ .words_of = .kind }` names the check an enum column already generates**; it is not a second check. `Column.check` carries the name into the snapshot, so moving it is a migration.
- **A function is the whole statement and must open `CREATE OR REPLACE FUNCTION <name>`**, because its signature is part of it and nilo does not compose one; the head is what makes applying it twice applying it once. **A view is its `SELECT`**, and nilo writes `CREATE VIEW "name" AS`, for the trigger's reason. **SQLite refuses `.extensions` and `.functions`**: there a function is a callback on the connection and an extension a shared library, neither a statement. Views it has.
- **The snapshot records a name and a hash**, sixteen hex characters of SHA-256, and an extension by name. A view is sixty lines, and a `.zon` document carrying them stops being readable and becomes what two branches merge. One type, `table.NamedText` (`Schema.Text`), holds every named text, so the hash is computed in one place.
- **Where each goes is the database's doing.** A `CHECK` is a table constraint inside `CREATE TABLE`, because SQLite has no `ADD CONSTRAINT` and a constraint not written at creation cannot be written at all. A trigger is a statement after the table and its indexes.

### An older snapshot still parses

Every field any of these words added to the snapshot has a default, and `std.zon` omits a field equal to its default when writing and fills it when reading, so a snapshot written before a word existed reads as one without it, and a program using none of them writes the file it always did. The one exception was a renamed field, and [ADR 123](./123-a-migration-is-a-diff-against-a-snapshot.md) says how it is read.

### `sql.Date`

The port declared `sql.AsText("date")` in four files, and every query reading one carried a `::text`. **`sql.Date` is read out of the column as itself.** On Postgres a `date` is a day count from 2000-01-01 and the Wire shifts it by 10,957 days, one shift and not a parse; on SQLite it is ten ISO characters in `TEXT`, what SQLite's date functions read; writing is those ten characters on both, with `::date` on Postgres because pg.zig has no encoder to bind one. It carries a value and does not calculate (no `.addDays`), and its two conversions are named for the zone they assume (`utcOf`, `atMidnightUtc`). It walks the calendar both ways over four digits, because the first thing put in a `date` column is a date of birth, which `Timestamp` refuses as before the epoch. `Decimal` stays `sql.AsText("numeric")`: its binary form is a digit vector that needs a parser, and the text form round-trips every digit.

## What was rejected

**A full DDL vocabulary in the marker**, text defaults and a string `.where` included. It fails the compiler test at its second entry, a vocabulary that stops being checked starts growing, and every disagreement between two databases then becomes a decision here.

**A default belongs to the step, not the type.** The first position: a default looks load-bearing only when a `NOT NULL` column is added to a table with rows. Of the port's 126, not one was that case; the moment is now handled by the same field.

**A typed grammar for `CHECK` bodies.** The where walker's four terms would type `CHECK (deleted_at IS NULL)` and close almost nothing: the port's checks need `OR`, and the next one a function call. A vocabulary grown to meet arbitrary SQL is a SQL parser arrived at one word at a time. **A fourth kind of word** for a generated column, a collation, a rule or a policy: each is a step until somebody brings a case.

**Reading `pg_constraint.conbin` back at boot**, so the startup check could say the database's `CHECK` has a word the enum does not. It parses a normalised expression tree per enum column per boot; the migration owns the words, and a database that disagrees with the snapshot is `verify`'s.

**Keeping `.references` to Row types and documenting the second declaration.** The port's own fallback, and it works; what decided against it is 3,876 lines no query names and two declarations of a column that can disagree until somebody boots the reading side. A rule that a program has to be laid out a particular way to use a module is what this repository refuses elsewhere. **Naming the table and checking it at boot against `pg_constraint`** instead: a compile error traded for a runtime one that needs a migrated database to find a typo, when the check did not have to be given up at all.

**A tuple of tuples for a composite key**, three nesting levels with no word saying which side is which. **A `by_name: bool` on `Reference`**, which puts a fact about the Zig source into the value the snapshot serialises.

**A second spelling beside `Schema`**, the list of Rows still accepted through `anytype`: two ways to say one thing, and the way to say it wrong is to hand the tool one and the check the other. **The roadmap's literal, `.functions = .{ .set_updated_at = … }`**: a struct field cannot be `anytype`, so a `Schema` taking it would be a different type per program and could not be named in a refusal. **Composing a function's head** from fields: a second grammar for `CREATE FUNCTION`.

**Comparing the body rather than a hash**: hundreds of lines of SQL in the `.zon` two branches merge. **`CREATE OR REPLACE` for a moved trigger or view**: a replace keeps the old definition if the new one fails halfway, and Postgres refuses `CREATE OR REPLACE VIEW` when a column went away, which is the common reason a view moves; a drop and a create is always right. **Sending a body to a database to validate it**: `generate` needs no database. **Sending an extension or function on SQLite and letting it fail**: it would fail at boot, in a program that compiled.

**An enum default as text** (`.priority = "normal"`), which puts the column's type and the default's out of step. **`.not_null` as a `.where` term**, as the port proposed: `where.zig` already spells it `.{ .ne = null }` in every `select`. **An array default as `"{}"`**, which on a `[]const Str` is one element holding two braces, or **`.empty`**, a word for the common case and a cliff at the first `&.{"a"}`. **An array default in the driver's binary array format**: pg.zig can bind an array as a parameter, and a `DEFAULT` has nowhere to put one, because the database stores the text.

**An insert variant that checks for a left-out column beside one that does not**: the insert that was missed is the one nobody thought to switch over. **Making the column optional as the only way out**: a `gen_random_uuid()` key is not null once read, and a `?` on it lies to every reader to satisfy one insert.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0: nothing here is reachable from a request |
| Memory per idle connection | 0 |
| Throughput and p99 | 0 |
| Binary size, the server | 0 bytes, measured |

Every word is comptime, the DDL and the diff are reachable only from a program that names `migrate`, and a `createMissing` with no extensions, functions or views loops over empty comptime lists the compiler folds away. The size row was measured each time a word arrived, `zig build size-sql` against `git archive HEAD`, both pairs `cmp`-identical ([`bench/result/sql.md`](../../bench/result/sql.md)); the `date` branches in both Wires sit inside a comptime test a Row with no `Date` never takes.

What it spends is compile time and Refusals, one for each mistake a word can be handed; the files are under `sql/refusals/` and the rows in `sql_refusals` in `build.zig`. By word: `.default` (`.now` on a number, an unknown word, a literal of another type, a word the enum lacks, an enum default as text, a default on a generated key); `.index` (a bad direction, a direction on a `.unique`, a `.where` term or literal that does not fit); names (an enum literal where text goes, a name past 63 bytes given or derived, two constraints deriving one name, a misspelled word in an entry, such as `.ignorng_case`, which once compiled into a unique that folded no case); `.references` (a table no Row declares, a type mismatch through a name, uneven column lists, `.columns` without `.to`, an unknown word such as `.on_dlete`, which would compile into a key with no `ON DELETE`); `.check` and `.trigger` (eleven shapes around the body, never the body); the `Schema` (a function not opening `CREATE OR REPLACE FUNCTION`, a view opening `CREATE`, and extensions or functions on SQLite); and the left-out column on insert.

Postgres 14 is a floor this puts under the module: `createMissing` sends one statement per object and there is no `CREATE TRIGGER IF NOT EXISTS`, so it uses `CREATE OR REPLACE TRIGGER`, which arrived in 14.

The proof that a body means anything is Postgres's: `sql/live.zig` creates tables from the marker's own `CREATE TABLE`, watches a check refuse an insert, reads both constraint names out of `pg_constraint`, fires the trigger, and round-trips five awkward array elements and a `date` through real columns.
