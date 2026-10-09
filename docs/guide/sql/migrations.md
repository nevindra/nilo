# Migrations

**The same Row that reads a table can also create it, change it, and tell you at startup whether the database is behind the code.**

**Reference:** [migrations](../../reference/sql.md#migrations), [the schema](../../reference/sql.md#the-schema), [the commands](../../reference/sql.md#the-commands) · **Design:** [Migrations](../../design/sql-migrations.md)

Migrations are the one part of [Talking to a database](./README.md) that is not a query.

## Declaring a table

**Everything about a table is declared in one place, the Row's `nilo_table` marker, and every part of it is checked while you compile:**

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

### Defaults (`.default`, `.filled`)

**`.default` is what the database writes when your insert leaves the column out.** `.now` is the only special value, and it only goes on a `sql.Timestamp`; everything else is a literal your column's own Zig type can hold. A column holding one of an enum's values takes that value written as an enum literal: `.free`, not `"free"`. A default the database has to compute, such as `DEFAULT (lower(x))`, is SQL you write in a step.

A column whose default is written in a step, or filled by a trigger, also goes in `.filled = .{ … }`, so an insert may leave it out: nilo rejects an insert that leaves out a column nothing fills ([writing rows](./writing.md)). `.filled` adds nothing to the table definition.

### Enum columns

**An enum field needs no extra declaration.** `plan: Plan` becomes a `text` column with `CHECK ("plan" IN ('free', 'team', 'enterprise'))` next to it, and the values are recorded in the snapshot, so adding a value to the enum produces a migration instead of an insert your database rejects. (An enum that names its own database type with `pub const nilo_column = "user_role"` belongs to the database, and nilo leaves its values alone.)

### Unique constraints and indexes

**`.unique` and `.index` take one column (`.email`), several columns as one constraint (`.{ .org_id, .created_at }`), or the named form when there is more to say.** `.ignoring_case` becomes `lower("email")` on Postgres and `COLLATE NOCASE` on SQLite. It covers the case where two people sign up as `Wati@` and `wati@` and a plain unique accepts both. On Postgres the index is built over `lower("email") text_pattern_ops`, so `.istarts_with` reads it as a range; one made by an earlier release keeps its old index until it is dropped and made again.

**Give a constraint a `.name` when somebody will have to read the violation.** Postgres reports a violation by the constraint's name and nothing else, so `members_one_account_per_address` is something your support engineer can act on, where `members_email_key` is a column list they have to look up. A name over 63 bytes is a compile error on both databases, because Postgres silently shortens a longer one with a `NOTICE` nobody reads.

An index can sort a column descending (`.{ .created_at = .desc }`) and can cover part of the table (`.where`). The condition uses the same syntax as a `db.select` condition, not a string: `null` is `IS NULL`, `.{ .ne = null }` is `IS NOT NULL`, a literal is `=`, and `.{ .ne = lit }` is `<>`. An index over an expression, such as `lower(btrim(site))`, is SQL you write in a step.

### Foreign keys (`.references`)

**`.references` is keyed by the column that points, and it names the Row rather than a table**, so renaming the table moves the key with it. A third entry says what happens on delete: `.cascade`, `.restrict` or `.set_null`. Both sides must have the same type, and a `.set_null` on a column that cannot hold a null is a compile error. Otherwise the database would only find either mistake at the first insert, in a message about a cast.

### Referring to a table by name

**Name the table as text when you cannot import its Row.** Some programs are laid out so that one file may not `@import` another (for example, one context per directory, where contexts never import each other), and `.{ Org, .id }` needs the type in scope. `.{ "orgs", .id, .cascade }` declares the same key without it:

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

You do not lose the type check by naming the table; it just happens elsewhere. A table name that no Row in the schema claims is a compile error naming both spellings ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)). `.managed = false` is how a table this program only reads gets into the schema without the tool offering to create it.

### A key across two columns

**A key can span two columns**, which is how a rule like "the Epic has to be on the same board" goes into the schema instead of a comment:

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

The entry is keyed by a label (`.epic`) rather than by a column, because a Zig field name cannot be a tuple. `.to` takes a Row or a name, the columns match up by position, and a mismatched count is a compile error. `.exists` joins on every column of the key, not just the first.

### Generated keys

**You do not declare whether the key is generated.** An integer key is `GENERATED BY DEFAULT AS IDENTITY` on Postgres and `INTEGER PRIMARY KEY AUTOINCREMENT` on SQLite. Any other key (a `sql.Uuid`, a slug) is filled by your insert. This is a fixed rule rather than an option, because there is no case where you want the other behaviour.

### Array defaults

**An array column takes a default like any other column**, and `&.{}` is the default every `NOT NULL` array column in a hand-written schema has:

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

Each element is checked against the column's element type, so a number where a string belongs does not compile. A comma, a brace, a quote, a backslash or an apostrophe inside an element is escaped, so the array Postgres stores has exactly as many elements as you wrote ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

## Check constraints and triggers

**A `CHECK` body and a trigger are SQL, which nilo does not parse; instead it owns their names and stores a hash of their bodies** ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)). Everything above is checked by the compiler. These two are not, on purpose, because reading them would mean shipping a SQL parser:

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

**The key is the name the object gets in the database.** A `.unique` can derive a name from its columns, but a check has no columns, and Postgres reports an unnamed constraint under a name it made up. The name is also all Postgres says when a row breaks the constraint, so it is worth writing well.

The diff has three cases and no fourth:

- same name and same hash: nothing to do;
- same name and a different hash: drop and create;
- a name your Rows no longer have: drop.

The snapshot records the name and sixteen hex characters, not the body. A view can be sixty lines, and a `.zon` file full of them would stop being readable.

**A trigger has two halves because nilo writes `ON "invoices"` between them.** The table is the one thing the marker already knows. A second copy of the table name would stop matching the day you rename the table, and a trigger left on the old table quietly stops running. `.when` is what goes before, `.run` is what goes after.

`.{ .words_of = .kind }` uses the same `.check` field for a different job: it names the `CHECK` that an enum column already generates, instead of leaving it as `invoices_kind_check`. Changing that name is a migration, because the constraint in your database still has the old one.

**nilo does not check your SQL.** The database does, inside the version's transaction, at the same moment a `.data` step is checked. A `CHECK` is part of the `CREATE TABLE`, so SQLite accepts it too; *changing* one there needs the four-statement table rebuild every other table constraint needs, and the diff writes it out. A trigger is a statement of its own, and both databases handle all three cases.

## The schema value (`sql.Schema`)

**Every call on this page takes the same `sql.Schema` value: every Row, plus the extensions, functions and views that belong to the schema rather than to a table** ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

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

Write it once and pass it to `db.checking(schema)`, `sql.cli.Tool(Db, schema)` and `createMissing(&db, &run, schema)`. That is why it is one value rather than three lists: the tool, the startup check and the startup code cannot disagree about what the database is. A program with only tables writes `.{ .tables = &.{ User, Order } }` and is done.

`@embedFile` is why functions and views are separate named lists. A sixty-line view belongs in `sql/open_orders.sql` with syntax highlighting, not in sixty `\\` lines, and `.body = @embedFile("sql/open_orders.sql")` puts it there. The snapshot records a function or a view as its name and a hash, the same way it records a check, so the snapshot stays readable however long the SQL is.

### Functions, views and extensions

Functions and views have a required form, and breaking it is a compile error rather than a failed apply:

- A **function** is the whole `CREATE OR REPLACE FUNCTION <name> …` statement, and it must start with those words and that name. That makes applying it twice the same as applying it once, and lets a changed body be one step in the diff rather than a drop and a create.
- A **view** is just the `SELECT`. nilo writes `CREATE VIEW "name" AS` in front of it, for the same reason a trigger has two halves: the name is already in the schema, and a second copy would stop matching the day it is renamed. A view whose text changed is dropped before any table changes and recreated after all tables have, so a view reading a column that is about to be removed is never in the way.

An extension is just a name: `CREATE EXTENSION IF NOT EXISTS` when it is added to the list, and `DROP EXTENSION` when it is removed. The drop is marked destructive, because dropping an extension drops every object it created. SQLite has no extensions and no `CREATE FUNCTION`, so both lists are rejected there; views work on both.

**The tool decides the order**: extensions, functions, tables in reference order, each table's indexes and triggers, then views. Anything else (a backfill, a seed row, a `create_hypertable`) goes in a version file's `before` and `after` lists.

## Creating tables (`createMissing`)

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{User} });
```

**`createMissing` runs one `CREATE TABLE IF NOT EXISTS` per Row, plus its indexes, all in one transaction.** **The order comes from the references, not from your list**: foreign keys are written inline (the only form SQLite supports), so `orgs` is created before `members` whichever order you wrote them in. Two tables that point at each other are a compile error naming both, with the way out in the message. A unique or index on a field the table does not have yet waits for `addMissingColumns`, which adds the column and then the index.

Running it again does nothing, which is what startup code needs. It is for a test, a fixture, or a single-file SQLite application: it creates what is missing and never changes what is there.

In a server, it belongs in startup, and startup happens inside `listen()`: register it with `app.before` and it runs once the pool is open, on the server's own event loop, before the first request ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

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

**Use `db.checking` and `createMissing` together**, and they run in this order: the pool opens, `before` creates the tables, then the schema check runs and reads what was created. A first start on an empty file is clean, and a Row that has drifted from an existing table (which `createMissing` will not change) is still rejected at startup. The check is a `nilo_check`, which the App runs after the work `before` registered; `app.start(io)` runs the same three steps in a test ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)). [`examples/sqlite/`](../../../examples/sqlite/main.zig) is this program.

### Adding new columns (`addMissingColumns`)

**`addMissingColumns` adds the columns a Row has and its table lacks, for a program too small to need versioned migrations** ([ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md)). A single-file program that shipped `downloads` with five columns and now has a Row with eight does not want a ledger and version files for three `ADD COLUMN`s. Writing the three by hand would copy a type mapping that drifts the next time nilo's changes.

<!-- compiles: body -->
```zig
try sql.migrate.createMissing(&db, &run, .{ .tables = &.{User} });
_ = try sql.migrate.addMissingColumns(&db, &run, .{ .tables = &.{User} });
```

It runs one `ALTER TABLE … ADD COLUMN` per missing field, typed from the same `Desc` that `createMissing` reads (`pragma_table_info` on SQLite, `pg_catalog` on Postgres), in one transaction. It returns how many columns it added: three the first time, zero on every start after.

**A new column comes with its foreign key**, written inline, and with every unique and index the Row declares over it, created right after. On SQLite a new column inside a foreign key of several columns is `error.NeedsVersion`, because SQLite writes that key only when it creates the table; write a version that rebuilds it.

**A required column with no default is rejected** with `error.NeedsBackfill`; the statement it would have sent is logged, and nothing is sent. SQLite rejects that `ALTER` outright and Postgres rejects it on a table with rows, so nilo cannot send it safely. Give the field a `.default` in the marker (the existing rows get it and there is nothing to backfill), make it optional, or write a version. A table that does not exist is skipped, because creating it is `createMissing`'s job. Nothing else changes: a column the table has and the Row does not is left alone, a changed type is left alone, and `db.checking` is what reports them.

## Changing tables: the diff

**A migration is a diff between your types and a snapshot file, and computing it needs no database:**

<!-- compiles: body -->
```zig
const before = sql.snapshot.empty(sql.Db.Dialect);   // or snapshot.zon, read back
const desired = comptime sql.migrate.desiredOf(sql.Db.Dialect, .{ .tables = &.{User} });

const change = try sql.migrate.plan(gpa, sql.Db.Dialect, desired, before);
```

`desired` is your types. `before` is `migrations/snapshot.zon`, a file you commit, which records what the schema was at the last diff. With two files and no database, this runs on a plane, and two branches that both generate a migration conflict in **git**, which is a conflict worth having, instead of at deploy time.

`change.steps` is what to run, each step with its `sql` and a one-line `why`. `change.problems` is what the diff will not write, and **all problems come back at once, not just the first**:

- a column that changed in a way SQLite cannot follow: its type, nullability, default or an enum's values (SQLite has no `ALTER COLUMN` and no way to replace a constraint);
- any foreign-key change on a table that already exists, except a key of one column on a column the table did not have, which the diff writes with the column (`ADD COLUMN … REFERENCES …`; on SQLite only while the column defaults to NULL, so a `.default` beside it is a problem). For the rest the one-statement form takes an `ACCESS EXCLUSIVE` lock and scans the table. The problem spells out the `ADD CONSTRAINT … NOT VALID` then `VALIDATE CONSTRAINT` pair to write instead.

A column that changed in three ways gets one problem naming all three, because what it needs is one rewrite.

### A problem you handled yourself (`--accept`)

**A problem is not a step, so the diff cannot write it; you write the step, and `--accept` tells the snapshot you did.** While one stands, `db generate` writes nothing, and it lists each problem with a name:

```console
$ db generate --name key_posts
Nothing written. The diff will not write these:

  posts.org_id
    the foreign key posts_org_id_fkey is new or changed, and the table already exists. …
    accept as: posts.org_id@1a2b3c4d

Write the step for each yourself, as a step of your own in the `before` or `after` of the version this writes. …

  db generate --name key_posts --accept posts.org_id@1a2b3c4d
```

Run the command it prints. It writes a version, with the step you did not get in `before` or `after` still to be written by you, and moves `snapshot.zon` past the problem, so the next `db generate` and `db check` do not raise it again. The file says which problems it was written for, above the generated block:

```zig
// Written with `--accept` for the problems below. The diff has no step for
// any of them: the step is yours, in `before` or `after` above, and this
// version is only right once it is there. Nothing checks that it is.
//
// posts.org_id@1a2b3c4d
//   the foreign key posts_org_id_fkey is new or changed, …
```

**It cannot accept what you did not read.** The name is the table, the column and eight hex digits of a hash over what the problem said, so it names that problem as it was printed: when a change to your types makes the problem say something else (the key points at another table, say), it has a new name, and the old one is refused as naming nothing. Every standing problem has to be named in one run, because the snapshot becomes your types as they are now, and a problem left out would be one the diff then never raises. There is no `--accept-all`. The one problem that cannot be named is the snapshot having been written in another dialect, which a step cannot fix.

Accepting is a promise, and nilo cannot check it: if the step is not in the version, the database does not have the change, and the types and the database disagree with a green `db check`. A `ForeignKeyViolated` or a startup check that refuses a Row is how that shows. On SQLite, where the answer to most of them is a table rebuild, the step is the four statements the problem spells out.

### Renaming a column (`.was`)

**A renamed column is declared in the type, not answered at a prompt:**

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

Other tools guess that a dropped `handle` and a new `email` are the same column, then ask you at a prompt. The answer is in your head; putting it in the type means the same code produces the same migration for you, for CI, and for the next person.

An index, a unique or a foreign key over the column goes with it, since `RENAME COLUMN` carries them. On Postgres, one named after the old column (`members_handle_key`) is renamed to match the new one in the same version; on SQLite, which cannot rename an index, the index is dropped and made again.

## Applying migrations

<!-- compiles: body -->
```zig
const chain = try sql.migrate.chainOf(run.arena(), &.{});
const ran = try sql.migrate.applyPending(&db, &run, chain);
```

**`applyPending` runs each version that has not run yet, one transaction per version, under an advisory lock.** `nilo_migrations` is an ordinary Row, and `applyPending` creates it if it is not there. It reads this ledger once and skips any version already in it, so a start with nothing to do is one query. Each version that has not run is one transaction, begun `READ COMMITTED` on Postgres whatever the role's default is: take the advisory lock, check again whether the version is there, run every step, write the ledger row, commit. The second check is what matters when nine out of ten replicas start at the same time. **The lock is essential**, and it is the part a hand-written migration runner usually leaves out. It is asked for and not waited for: a replica that finds it taken checks again every fifth of a second, because a statement that waits for it would deadlock with an index build running beside it ([ADR 269](../../adr/269-an-index-on-a-big-table-is-built-outside-a-transaction.md)).

**On Postgres, a step gives up after five seconds waiting for its table.** An `ALTER TABLE` needs a lock nothing else can share, and while it waits for one, every read and write to that table waits behind it. So a report or a forgotten `psql` session holding the table open would stall your whole app for as long as it stays open. After five seconds the version fails with `error.Locked`, the log names the step, and nothing is kept; start again once whatever held the table is done. A version that should wait longer says so in its file:

```zig
pub const version: migrate.Version = .{
    .number = 7,
    .name = "widen_counts",
    .steps = before ++ generated ++ after,
    .lock_timeout_ms = 30_000, // 0 waits for as long as it takes
};
```

The comment above each generated step also says when it reads or rewrites the whole table while holding it: `SET NOT NULL`, a new `CHECK`, and a type change like `int4` to `int8`. On a big table, that line is the one to read before you deploy.

Each version's hash covers its own steps chained onto the hash of the version before it, so editing a migration that has already run changes that version's hash and every later one. `applyPending` refuses to run anything when it finds such an edit (`error.SchemaDrift`), because the later versions were written against what the edited one used to say. `sql.migrate.drift` lists them.

**On SQLite, a version that drops a table runs with foreign keys off**, and they are checked once before its COMMIT. Any other version keeps them on, so a `DELETE` of a parent in it cascades as the schema says. Changing a column on SQLite means rebuilding the table, and the `DROP TABLE` in a rebuild deletes the old table's rows first. With foreign keys on, every `ON DELETE CASCADE` pointing at that table would fire, and the child rows would be gone when the version commits. With them off, the children stay. A row left pointing at nothing (for example, after a copy that skipped some rows) causes `error.ForeignKeyViolated`, and the version is rolled back.

The hash is not a field you write on the version. `chainOf` computes the whole list in one pass, because a hash somebody can type in is a hash somebody can type wrong, and a wrong one would make the drift check look like it works when it does not.

A version is a *list* of steps, and some of them can be SQL you wrote. That is what the expand-and-contract pattern needs: add the column, backfill it, then make it `NOT NULL`, all in one version and one transaction. An `up`/`down` pair has nowhere to put the middle step.

**There is no `down`; migrations only go forward.** A migration that has run against production data cannot be undone by a statement written before anybody knew what the data was: dropping the column you just added does not bring back what was in it. On a laptop, the way back is to drop the database and migrate again, and while you are still on version 1, `db generate --baseline` regenerates it in place.

A program that applies its own migrations at startup puts the three lines above in a function and passes it to `app.before`, like `makeTables` above. If it fails, the server does not start: a database the migration could not bring up to date is one this binary must not serve. Do not open the pool yourself with `app.start(io)` and then call `listen()`: that would give the pool one event loop and the requests another, and it is rejected ([ADR 180](../../adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

## Refusing to start on an old schema (`db.expecting`)

<!-- compiles: body -->
```zig
db.expecting(7);
```

**`db.expecting(n)` stops the server from starting when the database has not had migration `n` applied yet.** It is one query, run by `listen()` on the pool it just opened. It catches a common incident: the code was deployed before the migration, and every request touching the new column answers 500 until somebody notices. The number is the generated manifest's head, `manifest.head`, so the check moves with the migrations and nobody types the number by hand.

A database *ahead* of the binary is allowed and only logged, since that is the normal middle state of a two-stage deploy. If the database cannot be asked, the server starts with a warning, the same way `db.checking` does. `sql.migrate.expect(&db, &run, 7)` is the same check as a function call, for a script that has a `Run`, and `sql.migrate.standing` returns the answer as a value if you would rather decide yourself.

## The `db` command-line tool

**`sql.cli` provides the migration commands, so your project's migration tool is one small file.** Everything above can be called directly, but nobody wants to:

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

nilo owns the argument parsing, the dispatch and every message printed. You own the allocator, the connection string and the `Db` type, because those are the three things nilo cannot guess.

Add it to your `build.zig` as an executable and you have these commands:

```console
$ db check                       # do the Rows, the migrations and the .sql twins agree?
$ db generate --name add_nickname
$ db generate --name add_index --concurrently orders_org_id_idx   # a big table: no write stops
$ db generate --name key_orders --accept orders.org_id@1a2b3c4d   # a problem you wrote the step for
$ db generate --name schema --baseline   # re-derive version 1, keeping your own steps
$ db status                      # what this database has, and what is waiting
$ db migrate                     # apply it
$ db verify                      # has an applied version been edited since?
```

`generate` and `check` never open the database. They diff your Rows against `migrations/snapshot.zon`, which is why they run on a laptop with nothing installed, and in CI with no database container.

**A foreign key with no index behind it is a note under the result, and never a failure.** Neither database indexes the column that points, so deleting a row of the parent reads every row of the child. `check` (and `generate`, when it wrote a version) names each such key with the line that adds the index, say `.index = .{ .customer_id }` in the Row. Nothing is added for you, because the index slows every insert into that table and a small table does not need it. It reads your Rows and not a database, so it runs in CI too.

**The exit code is all CI needs.** `0` means it did what was asked, `1` means you have something to do, and `2` means the command line was wrong. `db check` in a pipeline needs no output parsing.

### Dropping data needs a name

**`generate` never loses data silently.** A dropped field, a dropped Row, and a column type change that might not fit are only written once you name them:

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

**Naming them is the safeguard.** A field you renamed but forgot `.was` on shows up in this list as a dropped column, next to the one you meant to drop. A bare `--drop` used to write both. A name that matches nothing is rejected too, because it is usually a typo for the one you meant.

A column type change counts as a loss unless it widens: `i32` to `i64` goes through, but `i64` to `i32` has to be named, and so does anything that could round or reinterpret a value. The list is in [ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md#forward-only).

The generated file is Zig you can read, and it is exactly what runs: those steps, in that order, in one transaction.

### An index on a big table (`--concurrently`)

**A new index on a table that already has rows stops every write to it until the build ends, and on a big table that is an outage.** A version is one transaction, and Postgres refuses `CREATE INDEX CONCURRENTLY` inside one, so the step `generate` writes takes the lock that makes inserts and updates wait. On a table of a few thousand rows that is milliseconds. On fifty million it is not. Whether yours is that big is a fact about your database, so you name the index:

```console
$ db generate --name index_readings --concurrently readings_sensor_idx
Wrote migrations/0008_index_readings.zig, 1 step(s):

  create_index  unique readings_tag_key; writes to readings wait while it builds. …

And migrations/0009_index_readings_concurrently.zig, 1 step(s), which runs outside a transaction so that writes to the table carry on while each index is built:

  create_index  index readings_sensor_idx; …
    CREATE INDEX CONCURRENTLY IF NOT EXISTS "readings_sensor_idx" ON "readings" ("sensor")
```

The named indexes go in a version of their own after the rest, marked `.transactional = false`: its steps run one at a time with no transaction around them, and the ledger row is written after the last. Every ordinary step's comment says how to ask for this, and the name is the one in it. Only an index on a table that exists can be named, and only on Postgres; on SQLite a write holds the whole file whatever it is, there is nothing to ask for, and a name given there is refused.

**A build that fails halfway leaves an index behind that is invalid and does nothing.** A unique index over rows that repeat is the usual way: Postgres reports the duplicate, keeps the index in the catalog marked invalid, and refuses to make another of that name. nilo drops it before it builds again, with a line in the log saying so, and builds it again. It is dropped rather than refused, because there is nothing in an invalid index to keep, and refusing would make the next boot fail the same way until somebody connected by hand. A valid index of the same name is left alone.

**A version outside a transaction is run whole again when it failed**, since it has no ledger row, so the steps in `before` and `after` that you add to it have to be safe to run twice. The generated ones are: `IF NOT EXISTS`, and the invalid index dropped first. The steps before the one that failed stay built. The version before it, in its transaction, is already committed, so after a failure the database is at one version behind the binary, and `db.expecting` keeps refusing to serve until the build has finished.

**Run it from `db migrate` in your release step rather than at boot.** The build holds the migration lock for as long as it takes, so a replica that starts meanwhile waits for it. The lock is asked for and not waited for (a statement that waits for it and a `CONCURRENTLY` build deadlock, and Postgres ends one of them), so a replica waiting checks again every fifth of a second.

The build waits for every transaction that began before it, so a long-running query delays it, and it is not given up on: the version runs without `lock_timeout` (writes and reads carry on meanwhile). Bound it with `statement_timeout` if you want it to fail instead. A redefined index (same name, different columns) is dropped in the first version and built in the second, so queries that used it go without it while the second runs. A key you add in the same run that points at a unique index you build this way would be applied before the index exists: leave that unique out of `--concurrently`.

### The version file and your own steps

**Only one declaration in a version file is generated; the other three are yours:**

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

The generated block is at the bottom because on a ported schema it can be four thousand lines, and a `version` below that would never be read. Put your own `.kind = .data` steps in `before` or `after`, or change the concatenation to pull them from another file, which a program that keeps its steps next to its Rows will want:

```zig
.steps = before ++ generated ++ billing.steps ++ work.steps,
```

Everything outside the two `// nilo:generated` lines is kept when the file is regenerated. Do not move or edit either line: a version file that has lost one is rejected rather than rewritten, because the only other reading would be that the whole file is generated.

### The `.sql` twin file

**Every version file has a `.sql` twin, written by the same `generate` and committed next to it, for applying migrations where no Zig can run:**

```
migrations/0007_work_items_get_a_priority.zig
migrations/0007_work_items_get_a_priority.sql
```

It holds the same steps in the same order, each with its `why` as a comment above it, wrapped in `BEGIN`/`COMMIT`, with the ledger table created if missing and the ledger row at the end:

```sql
\set ON_ERROR_STOP on

BEGIN;

CREATE TABLE IF NOT EXISTS "nilo_migrations" ( … );

-- add work_items.priority
ALTER TABLE "work_items" ADD COLUMN "priority" text NOT NULL DEFAULT 'normal';

INSERT INTO "nilo_migrations" ("version", "name", "hash", "applied_at", "ms")
VALUES (7, 'work_items_get_a_priority', '9f3c…', now(), 0);

COMMIT;
```

That last row is what makes it useful. `psql -f`, a CI job with no Zig toolchain, or somebody on a jump host can bring a database up to date, and `db.expecting(manifest.head)` still accepts it and `db verify` still checks it against the hash. Without the row, the database would be at 7 while the ledger says 6, and the next start would refuse to serve.

**The first line stops the shell at the first failed step**, `\set ON_ERROR_STOP on` for `psql` and `.bail on` for `sqlite3`. Without it `sqlite3` carries on past the failure and the `COMMIT` keeps the steps that ran together with the ledger row, and `psql` rolls back but exits 0, so a deploy script reads a failed version as applied. That line makes the file a script for the database's own shell: a driver that sends it as SQL refuses the first line.

**It is an output only.** nilo reads the `.zig` file and never this one, and a version somebody else wrote in SQL is not picked up: migrations are written in Zig, for the reasons [ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) gives. `db check` fails when a twin no longer matches its version file, so it cannot go stale on a branch nobody rebuilt, and any `db generate` rewrites it ([ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md)).

One case writes no twin and says so: `--baseline` rewriting a version 1 whose `before` or `after` contain steps of your own. Those are Zig that has not been compiled yet, so the twin's hash cannot be computed. Build, then run `db check`, which names the file, and any `db generate` writes it.

### Porting an existing schema

**Porting a schema means regenerating version 1 again and again until it matches the original, and `--baseline` makes that a loop:**

```console
$ db generate --name schema --baseline
Rewrote migrations/0001_schema.zig, 59 step(s):
  …
The generated block is new; everything else in the file is as you left it.
```

It ignores `snapshot.zon` entirely, diffs your Rows against an empty database, and rewrites version 1 in place, along with the manifest and the snapshot. So `db check` straight afterwards passes, once the `.sql` twin has been rewritten too. Run it as many times as the port takes.

**A snapshot written by an older nilo is read, not rejected.** If you upgrade nilo and the file is in a format this version no longer writes, `generate` prints one line about it, diffs against it anyway, and writes the current format. You do not have to delete anything. That matters, because deleting the snapshot at version 7 would make the next `generate` write a version 8 that creates every table you already have ([ADR 181](../../adr/181-the-marker-has-two-kinds-of-word.md)).

It refuses, rather than doing something you cannot undo, in three cases: when the directory holds a version it is not regenerating (version 2 is a diff against what version 1 produced), when `--name` differs from the existing version 1, and when the file it would rewrite has no generated block. Each message names the files. [ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) explains why the file has this layout.

### Starting a migrations directory

**Create one file before the first run.** The tool imports `migrations/manifest.zig`, and `generate` is what writes it, so it has to exist before the first build. Create it with `head` at 0 and an empty list ([the reference](../../reference/sql.md#starting-a-migrations-directory) has the seven lines), and from then on the tool maintains it.

[ADR 123](../../adr/123-a-migration-is-a-diff-against-a-snapshot.md) is the design, including why a version is one `.zig` file and not a `.sql` one.
