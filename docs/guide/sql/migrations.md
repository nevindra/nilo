# Making the tables

The same Row that reads a table can create it, change it, and say whether
the database it is about to serve is behind. Migrations are the one thing in
[Talking to a database](./README.md) that is not a query.

Everything the marker says, it says in one place, and every word of it is
checked while you compile:

<!-- compiles -->
```zig
const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: nilo.Str,
};

const Plan = enum { free, team, enterprise };

const Member = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .default = .{ .created_at = .now, .plan = .free, .seats = 1 },
        .unique = .{
            .{ .columns = .{.email}, .ignoring_case = true,
               .name = "members_one_account_per_address" },
        },
        .index = .{
            .created_at,
            .{ .columns = .{ .org_id, .{ .created_at = .desc } },
               .where = .{ .left_on = null } },
        },
        .references = .{ .org_id = .{ Org, .id, .cascade } },
    };

    id: i64,
    org_id: i64,
    email: nilo.Str,
    plan: Plan,
    seats: i32,
    created_at: sql.Timestamp,
    left_on: ?sql.Date,
};

comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{ Org, Member } });
}
```

`.default` is what the database writes when your insert leaves the column out.
`.now` is the one word it has and it only goes on a `sql.Timestamp`; everything
else is a literal your column's own Zig type can hold. A column that holds one
of an enum's words takes one of them written the way a column is — `.free`, not
`"free"`. A default the database has to work out, `DEFAULT (lower(x))`, is SQL
you write in a step.

A column whose default is written in a step, or filled by a trigger, goes in `.filled = .{ … }` as well, so an insert may leave it out: nilo refuses an insert that leaves out a column nothing fills ([writing rows](./writing.md)). `.filled` renders nothing into the table.

`plan: Plan` needs nothing said about it: it is a `text` column with
`CHECK ("plan" IN ('free', 'team', 'enterprise'))` beside it, and the words are
in the snapshot — so adding a word to the enum is a migration, rather than an
insert your database refuses. (An enum that names its own database type with
`pub const nilo_column = "user_role"` is the database's, and nilo leaves its
words alone.)

`.unique` and `.index` take one column (`.email`), several as one constraint
(`.{ .org_id, .created_at }`), or the named form when there is something to say
about it. `.ignoring_case` is `lower("email")` on Postgres and `COLLATE NOCASE`
on SQLite — the case where two people sign up as `Wati@` and `wati@` and the
plain unique takes both.

**Give a constraint a `.name` when the violation is a sentence somebody has to
read.** Postgres reports one by name and nothing else, so
`members_one_account_per_address` is something your support engineer can act on
where `members_email_key` is a column list they have to go and look up. Any
name over 63 bytes is a compile error on both databases, because Postgres cuts
a longer one down in a `NOTICE` nobody reads.

An index can read a column downwards (`.{ .created_at = .desc }`) and can cover
part of the table (`.where`). The predicate is the same grammar a `db.select`
condition uses, not a string: `null` is `IS NULL`, `.{ .ne = null }` is
`IS NOT NULL`, a literal is `=` and `.{ .ne = lit }` is `<>`. An index over an
expression — `lower(btrim(site))` — is SQL you write in a step.

`.references` is keyed by the column doing the pointing and it names the **Row**
rather than a table, so renaming the table moves the key with it. A third entry
says what happens on delete: `.cascade`, `.restrict` or `.set_null`. The two
sides have to hold the same type, and a `.set_null` on a column the Row cannot
hold a null in is a compile error — both are things the database would find at
the first insert, in a message about a cast.

**Name the table as text when you cannot import its Row.** Some programs are
laid out so that one file may not `@import` another — a context per directory,
where contexts never import each other — and `.{ Org, .id }` needs the type in
scope. `.{ "orgs", .id, .cascade }` says the same key without it:

<!-- compiles -->
```zig
const Comment = struct {
    pub const nilo_table = .{
        .name = "comments",
        .key = .id,
        .references = .{ .author_staff_id = .{ "staff", .id } },
    };

    id: i64,
    author_staff_id: i64,
    body: Str,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff", .managed = false };

    id: i64,
    email: Str,
};

// The schema `sql.cli.Tool` and `db.checking` are given, and the one place every
// Row is together — so it is where `"staff"` is resolved and where the two
// columns' types are compared. Written `comptime` here because that is what
// makes this page's own check run; in a program it is `Tool(Db, schema)`.
comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{ Comment, Staff } });
}
```

You do not lose the type check by naming the table; it moves. A table no Row in
that list claims is a compile error naming both spellings
([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)), and
`.managed = false` is how a table this program only reads gets into the list
without the tool offering to create it.

**A key can span two columns**, which is how a rule like "the Epic has to be on
the same board" gets said in the schema instead of in a comment:

<!-- compiles -->
```zig
const Epic = struct {
    pub const nilo_table = .{ .name = "epics", .key = .{ .id, .board_id } };

    id: i64,
    board_id: i64,
    title: Str,
};

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .references = .{
            .epic = .{
                .columns = .{ .epic_id, .board_id },
                .to = .{ Epic, .{ .id, .board_id } },
                .on_delete = .cascade,
            },
        },
    };

    id: i64,
    epic_id: i64,
    board_id: i64,
    title: Str,
};

comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{ Task, Epic } });
}
```

The entry is keyed by a label (`.epic`) rather than by a column, because a Zig
field name cannot be a tuple. `.to` takes a Row or a name, the columns line up
by position, and a mismatched count is a compile error. `.exists` joins on every
column of it, not just the first.

You do not say whether the key is generated. An integer key is
`GENERATED BY DEFAULT AS IDENTITY` on Postgres and
`INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite; anything else — a `sql.Uuid`, a
slug — is a key your insert fills. That is a rule rather than a word, because
there is no case where you want the other one.

**An array column takes a default like any other**, and `&.{}` is the one every
`NOT NULL` array column in a hand-written schema has:

<!-- compiles -->
```zig
const Agent = struct {
    pub const nilo_table = .{
        .name = "agents",
        .key = .id,
        .default = .{ .read_tags = &.{}, .write_capabilities = &.{ "deals", "work" } },
    };

    id: i64,
    read_tags: []const Str,
    write_capabilities: []const Str,
};

comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{Agent} });
}
```

Each element goes through the column's own element type, so a number where a
word goes does not compile. A comma, a brace, a quote, a backslash or an
apostrophe inside an element is escaped, so the array Postgres stores has as
many elements as you wrote
([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

## The two words nilo does not read

Everything above is checked by the compiler. Two words are not, on purpose: a
`CHECK` body and a trigger are SQL, and reading them means shipping a SQL
parser. What nilo does instead is **own the name and hash the body**
([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)):

<!-- compiles -->
```zig
const Invoice = struct {
    pub const nilo_table = .{
        .name = "invoices",
        .key = .id,
        .check = .{
            .invoices_amount_is_positive = "amount > 0",
            .invoices_dates_run_forwards =
                "sent_on IS NULL OR paid_on IS NULL OR sent_on <= paid_on",
            .invoices_kind_is_known = .{ .words_of = .kind },
        },
        .trigger = .{
            .invoices_touch = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
            },
        },
    };

    id: i64,
    amount: i64,
    kind: enum { sale, refund },
    sent_on: ?sql.Date,
    paid_on: ?sql.Date,
};

comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{Invoice} });
}
```

**The key is the name the object goes into the database under.** A `.unique` can
derive one from its columns; a check has no columns, and a constraint nobody
named is reported by Postgres under a name it made up. It is also the whole of
what Postgres says when a row breaks it, so it is worth writing.

The diff has three cases and no fourth: same name and same hash, nothing to do;
same name and a different hash, drop and create; a name your Rows no longer
have, drop. The snapshot records the name and sixteen hex characters, not the
body — a view is sixty lines, and a `.zon` file carrying them stops being
readable.

**A trigger is two halves because nilo writes `ON "invoices"` between them.**
The table is the one thing the marker already knows, and a second copy of it
stops matching the day you rename the table — a trigger left on the old table is
a trigger that quietly stops running. `.when` is what goes before, `.run` is
what goes after.

`.{ .words_of = .kind }` is the same `.check` word doing a different job: it
names the `CHECK` an enum column already generates, instead of letting it be
`invoices_kind_check`. Moving that name is a migration, because the constraint
in your database still has the old one.

What this does not do is check your SQL. The database does, inside the version's
transaction, which is the same moment a `.data` step is checked. A `CHECK` rides
inside the `CREATE TABLE`, so SQLite takes it too; *changing* one there is the
four-statement rebuild every other table constraint needs, and the diff spells
it out. A trigger is a statement of its own and both databases do all three
cases.

## The schema is one value

Every call on this page is given the same thing: a `sql.Schema`, which is
every Row and the three kinds of object that hang off the schema rather than
off a table
([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

<!-- compiles -->
```zig
pub const schema = sql.Schema{
    .extensions = &.{"pgcrypto"},
    .functions = &.{
        .{ .name = "set_updated_at", .body = 
            \\CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
            \\BEGIN NEW.updated_at = now(); RETURN NEW; END
            \\$$ LANGUAGE plpgsql
        },
    },
    .tables = &.{ User, Order },
    .views = &.{
        .{ .name = "open_orders", .body = "SELECT id, user_id, total FROM orders WHERE status = 'open'" },
    },
};
```

Write it once and hand it to `db.checking(schema)`, `sql.cli.Tool(Db, schema)`
and `createMissing(&db, &run, schema)`. That is the whole reason it is a value
rather than three lists: the tool, the startup check and the boot cannot
disagree about what the database is. A program with tables and nothing else
writes `.{ .tables = &.{ User, Order } }` and is done.

`@embedFile` is the point of the two named lists. A sixty-line view belongs in
`sql/open_orders.sql` with highlighting, not in sixty `\\` lines, and
`.body = @embedFile("sql/open_orders.sql")` puts it there. The snapshot
records a function or a view as its name and a hash, the way it records a
check, so the file stays readable however long the SQL is.

Two of the three have a shape nilo holds you to, and both are compile errors
rather than a failed apply:

- A **function** is the whole `CREATE OR REPLACE FUNCTION <name> …`
  statement, and it has to open with those words and that name. That is what
  makes applying it twice applying it once, and what lets a changed body be
  one step in the diff rather than a drop and a create.
- A **view** is the `SELECT`. nilo writes `CREATE VIEW "name" AS` in front of
  it, for the reason a trigger is two words: the name is the thing the schema
  already knows, and a second copy of it stops matching the day it is renamed.
  A view whose text moved is dropped before any table moves and remade after
  every table has, so a view reading a column about to go is never in the way.

An extension is a name. `CREATE EXTENSION IF NOT EXISTS` when it arrives, and
`DROP EXTENSION` when it leaves the list — marked destructive, because dropping
one drops every object it made. SQLite has neither extensions nor
`CREATE FUNCTION` as statements, so both lists are refused there; views it has.

**The tool owns the order**: extensions, functions, tables by reference, each
table's indexes and triggers, then views. What is none of these — a backfill,
a seed row, a `create_hypertable` — is what a version file's `before` and
`after` slots are for.

## Creating them

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{User} });
```

One `CREATE TABLE IF NOT EXISTS` per Row plus its indexes, all in one
transaction. **The order comes from the references, not from your list**:
foreign keys are written inline, which is the only shape SQLite has, so `orgs`
is created before `members` whichever way round you wrote them. Two tables
pointing at each other is a compile error naming both, with the way out in it.

Run it again and nothing happens, which is what a boot needs. This is for a
test, a fixture, or a single-file SQLite application — it creates what is
missing and never alters what is there.

In a program that serves, the boot is where it goes, and the boot is inside
`listen()`: register it with `app.before` and it runs once the pool is open,
on the server's own loop, before the first request
([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

<!-- compiles -->
```zig
fn makeTables(run: *nilo.Run, db: *sql.Db) !void {
    try sql.migrate.createMissing(db, run, .{ .tables = &.{User} });
}
```

<!-- compiles: body -->
```zig
db.checking(.{ .tables = &.{User} });
try app.provide(&db);
try app.before(makeTables, .{&db});
try app.listen(.{ .port = 8080 });
```

**`db.checking` and `createMissing` go together**, and in that order of
events: the pool opens, `before` makes the tables, and then the schema check
runs and reads what it made. A first boot on an empty file is clean, and a
Row that has drifted from a table `createMissing` will not alter is still
refused at boot. The check is a `nilo_check`, which the App runs after the
work `before` registered, and `app.start(io)` runs the same three steps for
a test ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).
[`examples/sqlite/`](../../../examples/sqlite/main.zig) is this program.

### A column the shipped file has not got

A single-file program that shipped `downloads` with five columns and now has
a Row with eight does not want a ledger and version files for three `ADD
COLUMN`s, and writing the three by hand copies a type mapping that drifts
the next time nilo's moves. `addMissingColumns` is the step after
`createMissing` for exactly that program
([ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md)):

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{User} });
_ = try sql.migrate.addMissingColumns(&db, &run, .{ .tables = &.{User} });
```

One `ALTER TABLE … ADD COLUMN` per field the table lacks, typed from the same
`Desc` the create reads — `pragma_table_info` on SQLite, `pg_catalog` on
Postgres — in one transaction, and the answer is how many were added: three
the first time, zero at every boot after.

**A required column with no default is refused**, `error.NeedsBackfill`, with
the statement it would have sent in the log, and nothing is sent. SQLite
refuses that `ALTER` outright and Postgres refuses it on a table with rows,
so it is not a statement nilo can send and mean. Give the field a `.default`
in the marker — the rows already there get it and there is nothing to
backfill — or make it optional, or write the version. A table that is not
there is skipped, because it is `createMissing`'s. Nothing else moves: a
column the table has and the Row does not is left, a type that changed is
left, and `db.checking` is what says so.

## Changing them

The other half is a diff, and **it needs no database on either side**:

<!-- compiles: body -->
```zig
const before = sql.snapshot.empty(sql.Db.Dialect);   // or snapshot.zon, read back
const desired = comptime sql.migrate.desiredOf(sql.Db.Dialect, .{ .tables = &.{User} });

const change = try sql.migrate.plan(gpa, sql.Db.Dialect, desired, before);
```

`desired` is your types. `before` is `migrations/snapshot.zon`, a file you
commit, which is what the last diff believed the schema was. Two files, so this
runs on a plane — and two branches that both generate conflict in **git**,
which is a conflict worth having, rather than at deploy.

`change.steps` is what to run, each with its `sql` and a line of `why`.
`change.problems` is what the diff will not write, and **all of them come back
rather than the first**: a column that moved in a way SQLite cannot follow — its
type, its nullability, its default or an enum's words, since SQLite has neither
`ALTER COLUMN` nor a way to replace a constraint — and any foreign-key change on
a table that already exists, because the one-statement form takes an
`ACCESS EXCLUSIVE` lock and scans the table. The problem spells out the
`ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT` pair to write instead. A
column that moved three ways gets one problem naming all three, because what it
needs is one rewrite.

A renamed column is written in the type, not asked at a prompt:

<!-- compiles -->
```zig
const Renamed = struct {
    pub const nilo_table = .{
        .name = "members",
        .key = .id,
        .was = .{ .email = "handle" },
    };

    id: i64,
    email: nilo.Str,
};

comptime {
    _ = sql.migrate.desiredOf(sql.Postgres, .{ .tables = &.{Renamed} });
}
```

Every other tool guesses that a dropped `handle` and a new `email` are the same
column, then asks you at a prompt. The answer is in your head; putting it in the
type means the same code produces the same migration for you, for CI and for the
next person.

## Applying them

<!-- compiles: body -->
```zig
const chain = try sql.migrate.chainOf(run.arena(), &.{});
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

`nilo_migrations` is an ordinary Row, and `applyPending` makes it if it is not
there. It reads the ledger once. A version already in it is skipped, so a boot
with nothing to do is one query. One version that is not is one transaction:
take the advisory lock, check again whether it is there, run every step, write
the row, commit. That second check is what nine of ten replicas booting
together hit. **The lock is not decoration**, and it is the part a hand-written
runner usually leaves out.

Each version's hash is taken over its own steps chained onto the one before it,
so editing a migration that has already run moves that version and every version
after it. `applyPending` refuses to run anything when it finds one,
`error.SchemaDrift`, because the versions after it were written against what it
used to say. `sql.migrate.drift` lists them.

**On SQLite each version runs with foreign keys off**, and they are checked
once before its COMMIT. Changing a column there means rebuilding the table, and
the `DROP TABLE` in a rebuild deletes the old table's rows first. With foreign
keys on, every `ON DELETE CASCADE` pointing at it fires, and the child rows are
gone when the version commits. With them off the children stay. A row left
pointing at nothing, such as a copy that skipped some rows, answers
`error.ForeignKeyViolated`, and the version is rolled back.

The hash is not a field on the version. `chainOf` works the whole list out in
one pass, because a hash somebody can type in is a hash somebody can type in
wrong, and a wrong one makes the drift check look like it is working.

A version is a *list* of steps, and one of them can be SQL you wrote. That is
the shape expand and contract needs: add the column, backfill it, tighten it to
`NOT NULL`, all in one version and one transaction. An `up`/`down` pair has
nowhere to put the middle one.

There is no `down`. A migration that has run against production data cannot be
undone by a statement written before anybody knew what the data was: dropping
the column you just added does not bring back what was in it. Forward-only. On a
laptop, the way back is to drop the database and migrate again, and while you
are still on version 1, `db generate --baseline` re-derives it in place.

A program that applies its own migrations at boot puts the three lines above
in a function and hands it to `app.before`, the way `makeTables` is above. If
it fails, the server does not start: a migration that could not run is a
database this binary must not serve. Do not open the pool yourself with
`app.start(io)` and then call `listen()` — that hands the pool one loop and
the requests another, and it is refused
([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

## Refusing to serve a database that is behind

<!-- compiles: body -->
```zig
db.expecting(7);
```

One query, run by `listen()` on the pool it just opened. This catches one
incident shape and it is a common one: the code went out before the migration
did, and every request touching the new column answers 500 until somebody
notices. The number is the generated manifest's head — `manifest.head` — so
the guard moves with the migrations and nobody types it.

A database *ahead* of the binary is allowed and only logged — that is the
ordinary middle of a two-stage deploy. A database that cannot be asked starts
with a warning, the way `db.checking` does. `sql.migrate.expect(&db, &run, 7)`
is the same check as a call, for a script that has a `Run` in hand, and
`sql.migrate.standing` is the same question as a value if you would rather
decide yourself.

## Your own `db` command

Everything above is callable, but nobody wants to call it. `sql.cli` is the
commands, so your project's migration tool is one small file:

```zig
const std = @import("std");
const sql = @import("nilo_sql");
const manifest = @import("migrations/manifest.zig");

const Db = sql.Sqlite(.{ .threading = .in_fiber });
const Tool = sql.cli.Tool(Db, .{ .tables = &.{ User, Org } });

pub fn main(init: std.process.Init) !u8 {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    const out = &fw.interface;
    defer out.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const req = sql.cli.parse(argv[1..]) catch |err| return sql.cli.explain(out, err);

    var db = Db.init(init.gpa, "app.db", .{ .size = 1 });
    defer db.deinit();
    try db.nilo_start(init.io, .none);

    return Tool.run(init.gpa, init.io, out, req, &db, manifest.versions);
}
```

nilo owns the parsing, the dispatch and every sentence that comes back. You own
the allocator, the connection string and the `Db` type, because those are the
three things nilo cannot guess.

Add it to your `build.zig` as an executable and you have five commands:

```console
$ db check                       # do the Rows, the migrations and the .sql twins agree?
$ db generate --name add_nickname
$ db generate --name schema --baseline   # re-derive version 1, keeping your own steps
$ db status                      # what this database has, and what is waiting
$ db migrate                     # apply it
$ db verify                      # has an applied version been edited since?
```

`generate` and `check` never open the database. They diff your Rows against
`migrations/snapshot.zon`, which is why they run on a laptop with nothing
installed and in CI with no service container.

**The exit code is the whole API for CI.** `0` did what was asked. `1` you have
something to do. `2` the command line was wrong. `db check` in a pipeline needs
no output parsing at all.

Losing data is the one thing `generate` will not do quietly. A dropped field,
a dropped Row and a column type that may not fit are each written only once
you name them:

```console
$ db generate --name drop_nickname
Nothing written. Some of this loses data that nothing brings back:

  users.nickname  drop users.nickname, which no field reads
    ALTER TABLE "users" DROP COLUMN "nickname"

The rest of the version is fine. When you have read the above, name each one to write it:

  db generate --name drop_nickname --drop users.nickname

A column you meant to rename is one of these too: give the field `.was` instead,
and it is a rename. The generated file in migrations/ says which names you gave.
```

**The names are the point.** A field you renamed and forgot `.was` on shows up
in this list as a dropped column, next to the one you meant to drop. A bare
`--drop` used to write both. A name that matches nothing is refused too,
because it is usually a typo for the one you meant.

A column's type counts as a loss unless it widens: `i32` to `i64` goes
through, `i64` to `i32` has to be named, and so does anything that could round
or reinterpret a value. The list is in
[ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md#forward-only).

The generated file is Zig you can read, and it is exactly what runs: those
steps, in that order, in one transaction.

### What a version file looks like, and where your own steps go

Only one declaration in it is generated. The other three are yours:

```zig
const migrate = @import("nilo_sql").migrate;

/// Steps of your own that have to run *before* the generated ones — what is
/// not an extension, a function, a table or a view, since those four the
/// schema already orders.
pub const before: []const migrate.Step = &.{};

/// And the ones that run after: a backfill, a seed row, a `create_hypertable`.
pub const after: []const migrate.Step = &.{};

pub const version: migrate.Version = .{
    .number = 1,
    .name = "schema",
    .steps = before ++ generated ++ after,
};

// nilo:generated begin
const generated: []const migrate.Step = &.{ … };
// nilo:generated end
```

The generated block is at the bottom because on a ported schema it is four
thousand lines, and a `version` under that is a `version` nobody ever reads.
Put your own `.kind = .data` steps in `before` or `after` — or change the
concatenation to pull them from another file, which is what a program that keeps
its steps beside its Rows will want:

```zig
.steps = before ++ generated ++ billing.steps ++ work.steps,
```

Everything outside the two `// nilo:generated` lines is kept when the file is
written again. Do not move or edit either line: a version file that has lost one
is refused rather than rewritten, because the only other reading is that all of
it is generated.

### The `.sql` beside it, for a database no Zig can reach

Every version file has a twin, written by the same `generate` and committed
beside it:

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

It is the same steps in the same order, each with its `why` above it as a
comment, wrapped in `BEGIN`/`COMMIT`, with the ledger table created if it is not
there and the ledger row on the end:

```sql
BEGIN;

CREATE TABLE IF NOT EXISTS "nilo_migrations" ( … );

-- add work_items.priority
ALTER TABLE "work_items" ADD COLUMN "priority" text NOT NULL DEFAULT 'normal';

INSERT INTO "nilo_migrations" ("version", "name", "hash", "applied_at", "ms")
VALUES (7, 'work_items_get_a_priority', '9f3c…', now(), 0);

COMMIT;
```

That last row is what makes it worth having. `psql -f`, a CI job with no
toolchain, dbmate, or somebody on a jump host can bring a database to head, and
`db.expecting(manifest.head)` still serves it and `db verify` still holds it to
the hash. Without the row the database is at 7 and the ledger says 6, and the
next boot refuses to serve.

**It is an output.** nilo reads the `.zig` and never this, and a version written
in SQL by somebody else is not picked up — authoring stays Zig, for the reasons
[ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) gives.
`db check` fails when a twin no longer matches the version beside it, so it
cannot go stale in a branch nobody rebuilt, and any `db generate` writes it
again ([ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md)).

One case writes nothing and says so: `--baseline` rewriting a version 1 whose
`before` or `after` hold steps of your own. Those are Zig nothing has compiled
yet, so the twin's hash cannot be worked out. Build, then run `db check`, which
names the file, and any `db generate` writes it.

### Porting an existing schema

Porting is not "add a column". It is one version written over and over until it
matches the reference, and `--baseline` is what makes that a loop rather than a
shell script:

```console
$ db generate --name schema --baseline
Rewrote migrations/0001_schema.zig, 59 step(s):
  …
The generated block is new; everything else in the file is as you left it.
```

It ignores `snapshot.zon` entirely, diffs your Rows against nothing, and
rewrites version 1 where it stands, along with the manifest and the snapshot —
so `db check` straight afterwards is green, once the `.sql` twin has caught up.
Run it as many times as the port takes.

**A snapshot an older nilo wrote is read, not refused.** If you upgrade nilo and
the file is in a shape this version no longer writes, `generate` says one line
about it, diffs against it anyway and writes the current shape out. You do not
have to delete anything, which matters because deleting the snapshot at version
7 makes the next `generate` write a version 8 that creates every table you
already have
([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

It refuses in three places rather than doing something you cannot undo: when the
directory holds a version it is not re-deriving (version 2 is a diff against
what version 1 left behind), when `--name` disagrees with the version 1 already
there, and when the file it would rewrite has no generated block. Each message
names the files.

[ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
is why the file is shaped that way.

**One file to write before the first run.** The tool imports
`migrations/manifest.zig` and `generate` is what writes it, so it needs to exist
before the first build. Create it with `head` at 0 and an empty list — the
reference has the seven lines — and from then on the tool owns it.

[ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) is the
design, including why a version is one `.zig` file and not a `.sql` one.
