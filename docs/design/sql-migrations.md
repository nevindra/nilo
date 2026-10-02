# Migrations

**Your program's types are its database schema, and a migration is the difference between those types and a snapshot kept in git.**

**Guide:** [Making the tables](../guide/sql/migrations.md) · **Reference:** [Migrations](../reference/sql.md#migrations)

This page gives the whole rule as it stands, and where each part was decided. The code is `sql/migrate.zig` (plan, apply, `createMissing`), `sql/migrations.zig` (the files on disk), `sql/snapshot.zig`, `sql/ddl.zig`, the marker in `sql/table.zig`, and `sql/cli.zig` (`db generate`, `check`, `status`, `migrate`, `verify`).

## Overview

```
  sql.Schema ──────────────┐   Rows with their nilo_table markers, plus
  (the program's types)    │   extensions, functions, views
                           ▼
  snapshot.zon ────► db generate ────► 0007_x.zig      before ++ generated ++ after
  (what the last           │           0007_x.sql      the twin: an output, never read
   generate believed)      │           manifest.zig    the versions, as comptime constants
                           │           snapshot.zon    rewritten
                           ▼
                        db check        CI: the chain, the twins, the snapshot agree
                           │
          ┌────────────────┴────────────────┐
          ▼                                 ▼
  app.before(migrate)                 psql -f 0007_x.sql
  applyPending, then expect           (no Zig; the ledger row is in the file)
  at boot
```

A program that wants no ledger and no version files stays at the left edge of this: `createMissing` creates what is missing, and `addMissingColumns` adds a field a shipped table does not have yet.

## Rules

1. **`generate` never connects to a database.** The difference is computed between the Schema and `snapshot.zon`; the database's own table, `nilo_migrations`, only records which versions have run there. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
2. **Nothing the compiler could check is accepted as a string.** A word goes into the marker only if the compiler can check it (typed words), or if the diff can track it by name and hash without reading it (named text: `.check`, `.trigger`, functions, views, extensions). [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
3. **The schema is one value.** `sql.Schema` is what the tool, the startup check and `createMissing` all take, and the tool decides the order objects are created and dropped in. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
4. **Both sides of a foreign key are one Zig type**, whether the target is a Row or a table named as text. For a table named as text, the check runs in the Schema, where every Row is known. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
5. **A rename is written in the type** (`.was`), never asked at a prompt. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
6. **A version is a list of steps in one Zig file**: a generated block between two markers, with hand-written `before` and `after` around it. The file contains no hash; a chained hash is computed by `chainOf`. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
7. **Migrations only go forward.** There is no `down`. A destructive step is only written when `--drop` names it, and a type change that does not widen the column counts as destructive. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
8. **Migrations are written in Zig, but applying them does not need Zig.** Every version has a `.sql` twin that includes its ledger row, and `check` fails if a twin is out of date. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
9. **The binary knows its schema version** and refuses to run against a database that is behind it; a database that is ahead is allowed. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
10. **An older snapshot is still read, not rejected.** A new marker word is a snapshot field with a default and costs nothing; renaming a field costs a mirror struct until 1.0. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
11. **A table this program only reads is `.managed = false`**: checked at startup, never created or dropped. [ADR 130](../adr/130-a-table-this-program-reads-and-does-not-build.md)
12. **An insert that leaves out a column nothing fills does not compile.** `.default`, `.filled` or an optional field says who fills it. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
13. **A run refuses edited history, and on SQLite a version that drops a table runs with foreign keys off.** `applyPending` reads the ledger once and stops at a version recorded under a different hash. A SQLite version whose steps drop a table starts with `.rebuilding`, so the `DROP` in a table rebuild cannot cascade, and the COMMIT checks every foreign key once; any other version keeps them on, so a `DELETE` of a parent cascades. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
14. **A column the table's Row does not read is declared with `.unread`, with its type.** It is in the table, the diff and the startup check, can be named in `.where`, `.order` and `.set`, and is in no `SELECT` list of that Row. [ADR 234](../adr/234-a-table-row-may-declare-a-column-it-does-not-read.md)
15. **Each step goes where the database accepts it.** Views that read a table about to lose, rename or retype a column come down first and go back up last, in the order they read each other; a check or trigger over a column goes before the column; tables that are going go child first; what `RENAME COLUMN` carries (an index, a foreign key) is renamed with it on Postgres, not rebuilt. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
16. **A step waits five seconds for a table, and says when it holds one while reading every row.** `Version.lock_timeout_ms` (5,000; `0` waits for good) is set for the transaction after the advisory lock, and a step past it fails with `error.Locked` and nothing kept. The diff writes one-statement forms, because the two-statement ones only help across transactions and a version is one; the `why` names the whole-table read or rewrite instead. [ADR 240](../adr/240-a-migration-waits-five-seconds-for-a-table.md)

## Decisions

| ADR | What it decides |
|---|---|
| [123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md) | What a migration is, how a version file is written, and how it reaches a database with or without Zig |
| [181](../adr/181-the-marker-has-two-kinds-of-word.md) | What the marker and the Schema may say, and how each word is checked |
| [130](../adr/130-a-table-this-program-reads-and-does-not-build.md) | A Row for a table someone else creates |
| [234](../adr/234-a-table-row-may-declare-a-column-it-does-not-read.md) | `.unread`: a column the table has and its Row (often the response) does not read |
| [240](../adr/240-a-migration-waits-five-seconds-for-a-table.md) | How long a step waits for a table's lock, and what a step that holds one says |

Related topics: where the startup phase runs is [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) (lifecycle); every statement is prepared, which is why a version is not a `.sql` file, [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md); why the code is in `sql/` and not in a module of its own is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md).

## Open questions

- **`reset` and `squash`**, to pay down the debt that forward-only migrations build up; in [the todo list](../todo.md).
- **A `rebase`** that rewrites a conflicting version on top of the merged snapshot. Done by hand today.
- **A step that runs Zig code**, such as re-hashing passwords with `nilo_pw`. `Step.sql` is text only.
- **Having a build step write the manifest** instead of writing seven lines by hand.
- **What `applyPending` costs a server that calls it** has not been measured.
