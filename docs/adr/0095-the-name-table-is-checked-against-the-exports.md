# 0095 — the name table is checked against the exports

**Status:** accepted

## Context

`http/names.zig` exists because `@typeName` spells a type with the file it was
declared in, and nilo's files are not files anybody using nilo has opened. A
resolver handed back the wrong type was told it returned `str.Str` — a true
sentence about a source tree the reader does not have, and one that sends them
looking for a `str` module they never imported. Their import line says `nilo`, so
`nilo.Str` is the name the message uses.

The table is hand-kept, and it had fallen **fifteen** types behind `http.zig`'s
exports: `Bound`, `Session`, `FileBody`, `Dir`, `Stream`, `Events`, `Event`,
`Body`, `Socket`, `Room`, `Limits`, `Gate`, `Options`, `Run`, `Scope` and
`SameSite`. Three files ask the table (`session.zig`, `resolve.zig`,
`service.zig`); four did not, and between them carried twenty-five `@typeName`
calls inside `@compileError` text. So a WebSocket loop whose first argument was
wrong was told it should be `*nilo.Socket` and that what it had was a `*ctx.Ctx`
— one sentence naming the same kind of thing two different ways, one of them
pointing at a file the reader has never seen.

`ours`' own doc said what should have caught this: *"A type missing from here is
not a bug that hides: it prints its file name, which is wrong in the same visible
way `str.Str` was. `refusals/` is where that gets noticed."* Not one of the
fifteen was noticed. **A refusal only covers the message somebody thought to
write a refusal for**, and the four files with no refusal against them were
exactly the four nobody had looked at.

This is the shape [ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)
was written about, one level up: the error-message rule is held by a build step,
and the *table the messages read from* was held by a paragraph.

## Decision

**A test walks what the module actually exports and fails on any type that would
print a nilo file name.** It lives at the bottom of `http.zig`, which is the only
place that can see the exports without a second list to keep in step.

`names.covers(name)` is a new entry point beside `textOf`, answering "does this
table rewrite it" without paying for the rewrite. The rewrite builds a fresh
concatenated string per replacement; asking it once per export runs the comptime
branch budget out well before the module does.

Two things the test cannot see, and both are written into it rather than left to
be discovered:

- **Non-generic types only.** `Response(T)`, `Session(T)`, `Bound(T)` and the
  rest are functions until somebody applies them, so there is no `@typeName` to
  take. Their base names are in the table, because a generic is listed without
  its parentheses; what nothing checks is that they still are.
- **Exports that are somebody else's type.** `nilo.panic` is
  `std.debug.FullPanic`, which `@typeName` spells `debug.FullPanic(…)` with no
  `std.` in front of it, so no prefix test can see it for what it is. Renaming it
  would be a lie — it is not nilo's type to name — so it is a one-entry skip list
  with the reason next to it.

The four files now ask the table: `jsonmark.zig` (16 calls), `websocket.zig`
(7), and the two `@typeName` uses in `openapi.zig` and `typed.zig` that are *not*
compile errors are deliberately left alone. `openapi.nameOf` uses the raw name to
build a schema key, and `typed.zig`'s two are runtime messages naming a *service*
the reader declared — which already carries the name of the file they wrote it
in, which is exactly where they want to be sent.

Two rows of `build.zig`'s refusals table move with it, because the messages they
assert on are the two the change fixes.

## What was rejected

**Adding four more files to `refusals/`.** The obvious answer, and it is the one
that already failed. A refusal proves one message is right; it says nothing about
the twenty-four beside it, and it cannot notice a type added to `http.zig`
tomorrow. The refusals stay for what they are good at — that a wrong program
stops with nilo's words — and the completeness question moves to something that
enumerates.

**A comptime check inside `names.zig`.** Where it belongs by subject and cannot
go by structure: `names.zig` would have to import `http.zig`, which imports it.

**Listing the exports in `names.zig` as a second table.** Two lists to keep in
step instead of one, and the failure mode is the one being fixed.

## What it costs

Nothing on any axis. The walk is comptime, in a test, in a file no binary links;
`covers` is called nowhere but there. The name rewriting itself was already
comptime and already on the compile-error path, which never reaches a binary.

**One live consequence, and it is worth the paragraph.** `textOf` set its own
branch quota as `64 * (name.len + 1) + 4_000` — tracking the input, with a doc
saying so approvingly: *"The quota tracks the input rather than being a number
that happened to be enough once."* It tracked the input and not the table. Every
row scans the whole name, so the work is length times rows, and taking `ours`
from 20 rows to 35 broke callers in three files that had not changed a character.
The failure landed inside `std.mem` with nothing naming `names.zig`. The quota is
now `64 * (name.len + 1) * ours.len + 8_000`.

**A number that grows with a table has to name the table.** That is the same
mistake as the paragraph above it, one layer down: something was written to track
what would obviously grow, and the other thing that would obviously grow was not
in the formula.
