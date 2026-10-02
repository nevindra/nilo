<!--
One decision per pull request. A branch that carries two gets reviewed as two, so open two.

The title is the commit subject: `type: imperative sentence about the effect`, with `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build` or `chore`, and a `!` for a break. Say what changed, not which files.

The sections below are what CONTRIBUTING.md asks every change to carry. A section that does not apply is one line saying why, not a blank.
-->

## What changes, and why

<!-- Two or three sentences: what a caller can do now that they could not, or what stopped being wrong. The long version belongs in the ADR, history or changelog, not here. -->

## The decision

<!-- A design change is an ADR, and an ADR names the alternative it rejected. Take the next free number on `main` at the moment you open this and write it here, so the reviewer can confirm it is still free at merge; a number taken twice has happened. If nothing about the design changed, say "none" and name the ADR that already covers this. -->

ADR:

## What it spends

<!-- ADR 017. Performance is four axes and they do not recover the same way. Fill the rows this change touches, with the number and what it was measured through (a Docker port and a unix socket are different figures). "Nothing" is an answer, once the allocation budget test in http/app.zig still passes and nothing per-connection moved. A `docs:` or `test:` change replaces the table with that one line. -->

| Axis | Before | After | Measured through |
|---|---|---|---|
| Throughput and p99 | | | |
| Allocations per request | | | |
| Memory per idle connection | | | |
| Binary size, stripped ReleaseFast | | | |

## Refusals

<!-- Every new comptime check: the file under the module's `refusals/` and the row in the matching table in `build.zig`, and which `refusals-*` step you ran to see it fail in nilo's words. A row added to one table while running another step is a check that never ran. Leave the `nilo: ` prefix off `.says`. -->

## Tests

<!-- Named as sentences about the behaviour, at the bottom of the file they test. A new file under `http/` needs its `_ = @import(...)` line in `http/http.zig` or it never runs. Anything that reaches a real database, socket or store needs a live test beside the unit tests. -->

- [ ] `zig build test-all` passes: Debug and ReleaseSafe, every module gate, `layering` and `snippets`
- [ ] `zig build examples` builds
- [ ] a live test, where a real service is involved

## Documentation

<!-- Tick what this change touched. Not what shipped in history (that is the changelog's job), and not a todo entry marked done (it leaves the file). -->

- [ ] `docs/adr/`: the decision, and the alternative it beat
- [ ] `docs/history.md`: a number measured, or a premise that turned out false
- [ ] `bench/result/`: a run that changed a decision, with machine, commit and transport
- [ ] `docs/todo.md`: the entry for what is now built, removed
- [ ] `docs/decided.md`: a question answered, or a feature refused with its reason
- [ ] `CHANGELOG.md`: what a user has to change, under `## Unreleased`
- [ ] `docs/reference/`: the API, and a new heading listed once on its `README.md`
- [ ] a `zig` block in a page, marked `<!-- compiles -->` so `zig build snippets` compiles it
- [ ] none of these, because:

## Before asking for review

- [ ] one decision in this pull request, and the title names it
- [ ] the words are CONTEXT.md's: Ctx not Context, Str not string, keep not dupe, Refusal not negative test
- [ ] a `Str` that outlives its request has a `.keep()`
- [ ] the branch is on the current `main`, and the ADR number above is still free there
