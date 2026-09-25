# Migrations

**A program's types are its schema, and a migration is the diff between those types and a snapshot in git.** This page is the whole rule as it stands, and where each part of it was decided. How to use it is the guide ([`guide/sql/migrations.md`](../guide/sql/migrations.md)); every name and signature is the reference ([`reference/sql.md`](../reference/sql.md#migrations)). The code is `sql/migrate.zig` (plan, apply, `createMissing`), `sql/migrations.zig` (the files on disk), `sql/snapshot.zig`, `sql/ddl.zig`, the marker in `sql/table.zig`, and `sql/cli.zig` (`db generate`, `check`, `status`, `migrate`, `verify`).

## How the pieces fit

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

A program that wants no ledger and no version files stays on the left edge of this: `createMissing` makes what is not there, and `addMissingColumns` adds a field a shipped table lacks.

## The rule in force

1. **`generate` opens no connection.** The diff is the Schema against `snapshot.zon`; the database's own record, `nilo_migrations`, answers only which versions ran there. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
2. **Nothing the compiler could check is taken as a string.** A word gets into the marker if the compiler can check it (typed words), or if the diff can own it by name and hash without reading it (named text: `.check`, `.trigger`, functions, views, extensions). [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
3. **The schema is one value.** `sql.Schema` is what the tool, the boot check and `createMissing` take, and the tool owns the order objects are made and dropped in. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
4. **A foreign key's two sides are one Zig type**, whether the target is a Row or a table named as text; the check for the second runs where every Row is, in the Schema. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)
5. **A rename is written in the type** (`.was`), never asked at a prompt. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
6. **A version is steps in one Zig file**, generated block between two markers, hand-written `before` and `after` around it; no hash in the file, a chained hash computed by `chainOf`. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
7. **Forward only.** No `down`; a destructive step is written only when `--drop` names it, and a type that does not widen is destructive. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
8. **Authoring is Zig, applying need not be.** Every version has a `.sql` twin with the ledger row in it, and `check` fails on a stale one. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
9. **The binary knows its schema version** and refuses a database behind it; a database ahead is allowed. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
10. **An older snapshot is read, not refused.** A new marker word is a snapshot field with a default and costs nothing; a renamed field costs a mirror struct until 1.0. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)
11. **A table this program only reads is `.managed = false`**: checked at boot, never built or dropped. [ADR 130](../adr/130-a-table-this-program-reads-and-does-not-build.md)
12. **An insert that leaves out a column nothing fills does not compile.** `.default`, `.filled` or an optional field says who fills it. [ADR 181](../adr/181-the-marker-has-two-kinds-of-word.md)

13. **A run refuses edited history, and on SQLite runs with foreign keys off.** `applyPending` reads the ledger once, stops on a version recorded under another hash, and begins each SQLite version with `.rebuilding`, so the `DROP` in a table rebuild cascades into nothing and the COMMIT checks every reference. [ADR 123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md)

## Decisions

| ADR | What it decides |
|---|---|
| [123](../adr/123-a-migration-is-a-diff-against-a-snapshot.md) | What a migration is, how a version file is written, how it reaches a database with or without Zig |
| [181](../adr/181-the-marker-has-two-kinds-of-word.md) | What the marker and the Schema may say, and how each word is checked |
| [130](../adr/130-a-table-this-program-reads-and-does-not-build.md) | A Row for a table somebody else builds |

Beside this topic: where the boot phase runs is [ADR 180](../adr/180-work-that-needs-the-services-runs-on-their-loop.md) (lifecycle); every statement being prepared, which is why a version is not a `.sql` file, is [ADR 051](../adr/051-a-statement-that-is-a-constant-can-be-prepared-once.md); why the code is in `sql/` and not a module of its own is [ADR 038](../adr/038-a-module-sits-where-the-loop-puts-it.md).

## Open

- **`reset` and `squash`**, the debt forward-only creates; in [the roadmap](../roadmap.md).
- **A `rebase`** that writes a conflicting version again on top of the merged snapshot. Done by hand today.
- **A step that runs Zig**, such as re-hashing passwords with `nilo_pw`. `Step.sql` is text.
- **The manifest written by a build step** instead of seven lines by hand.
- **What `applyPending` costs a server that calls it**, unmeasured.
