# A problem is accepted by name

**Status:** accepted
**Topic:** [sql-migrations](../design/sql-migrations.md)
**Extends:** [ADR 123](./123-a-migration-is-a-diff-against-a-snapshot.md) (what `generate` does while a Problem stands)

## Context

The diff refuses what it cannot write safely, and says so as a `Problem`: a key added to a column the table had, a key of several columns on SQLite, a foreign key column with a default on SQLite, a column SQLite cannot change in place, and the rest. While one stands `generate` writes nothing, so the person writes the step by hand. But the snapshot is only ever rewritten by `generate`, so after the step the snapshot still said the old schema, the diff raised the same Problem again, and the only way out was editing `snapshot.zon` by hand. Two further faults sat next to it: a plan with a Problem and no step counted as empty, so `generate` printed "Nothing to do" and `check` printed "Up to date" over a standing Problem; and nothing tied the hand-written step to the version that carries it.

## Decision

**`db generate --accept <name>,…` records the named Problems as handled: it writes a version, and the snapshot becomes the types as they are.** The diff has no step for a Problem, so the version holds the steps it could write (possibly none) and the person's own step goes in its `before` or `after`. The next run diffs against the new snapshot and finds nothing.

**A Problem is named by its table, its column and a hash of what it said** (`Problem.key`: `orders.customer_id@1a2b3c4d`, eight hex digits of SHA-256 over table, column and text). `generate` prints the name beside each Problem and the whole command that accepts them, as it does for `--drop`. That makes four things hold:

- **Nothing is accepted that was not printed.** There is no `--accept-all`, and a bare `--accept` accepts nothing and says what it wants.
- **A changed schema re-raises it.** A change that alters what a Problem says gives it another name, and the old name matches nothing and holds the version back (`Outcome.stray_accept`), as a `--drop` that names nothing does. A Problem accepted and then changed again is diffed against the snapshot the acceptance wrote, so it is raised as the new Problem it is.
- **All or none.** The snapshot is the whole schema, so accepting some and not others would record the rest as handled. While any Problem is unnamed nothing is written, as before.
- **The one Problem that cannot be named is the snapshot's dialect** (a Problem with no table): accepting it would write a snapshot in a dialect the types are not read in.

The version file records what was accepted, with each Problem's text, above the generated block, and says the step is the person's. **Nothing checks that the step is there**; this is the weak part and is stated in the file, in the output and in the guide. A version with no steps applies as a ledger row.

**`Plan.isEmpty` is no steps and no Problems.** A Problem is not "nothing to do": `generate` reports it held, and `check` fails with the accept command.

## What it costs

Boot, request and memory axes: none (command line only). Binary: `Problem.key`, a hash and a few strings in a program that links the tool.

## What was rejected

- **Editing `snapshot.zon`**, which was the way out. It is accepting without the name, the text or the version file.
- **`--accept` without a hash**, by `table.column` alone. It would accept a Problem that changed between reading and typing, and a person who did not read the new text.
- **A record of accepted Problems in the snapshot or a second file**, consulted by every diff. A second record to merge and to go stale; moving the snapshot is the same effect with one file.
- **Accepting some Problems and taking the rest from the old snapshot.** It needs per-table surgery on the snapshot and leaves a half-moved schema that no types describe.
- **Writing the Problem's step.** The rebuild and the two-statement key are the Problem's own advice, and generating them is a different feature (the SQLite rebuild is in the todo list); this is the record that the step exists.
- **A marker in the Row** (`.accepted`). Migration state in the type, permanently.
