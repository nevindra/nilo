# 0083 — the guide is the source of its own snippets

**Status:** accepted
**Extends:** [ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md)

## Context

`refusals/` holds programs written wrong on purpose, and a build step checks
that each fails to compile with a message nilo wrote. There was nothing on the
other side. Every `zig` block in the guide, the reference and the README was
prose, and prose is what nobody runs.

An application written against the published pages found three one-liners that
do not compile, each the *first* thing somebody types on reaching that page:

| Where | What it said | Why it stops |
|---|---|---|
| `guide/sessions.md`, `docs/reference.md`, `http/ctx.zig` | `c.hashPassword(pw.huge_pages, form.password)` | `form.password` is a `Str` and the parameter is `[]const u8` |
| `docs/reference.md` | `id.v7(entropy, nilo.nowMillis())` | `nowMillis` answers `i64`, `v7` takes `u64` |
| `docs/reference.md` | `nilo.fail(401, "…")` | `fail` is a namespace, not a function |

Writing this step found four more in the same five-line sign-in example, and
they are worse than typos, because a reader cannot tell them from an API they
have misunderstood:

- **`db.acquire()` / `conn.release()`** — neither has ever existed on a `Db`.
  The pool acquires per statement; there is nothing to hold.
- **`db.find(Account, conn, .{ .email = … })`** — `find` takes a *key*, and a
  condition there is a Refusal pointing at `one`. The Scope slot had a
  connection in it, which is not a Scope.
- **`form.email`** — a `Form(T)` argument is `.value.email`. The whole page had
  dropped the `.value`.
- **`Session(User)` set with `.{ .id = … }`** — the page's own session type is
  `Signed`, three screens up.

And the same run found a **real gap in `nilo_sql`**: `.where = .{ .email =
form.email }` with a `Str` did not compile at all. A text column reads back as
a `Str`, and the most ordinary thing anybody does with request text is look a
row up by it. That is fixed here — `forWire` takes a `Str` and binds its view —
and it was not found by anybody reading the code.

## Decision

**A `zig` block with `<!-- compiles -->` above it is extracted while
`build.zig` runs, put behind a prelude, and compiled. `zig build snippets` is
that, and `zig build test` depends on it.**

The marker is an HTML comment, so it is invisible where the page is read. The
snippet has **one copy and it is the one in the page** — a `docs/snippets/`
directory of Zig files that mirror the guide would be a second copy, and the
whole lesson of this repository is that a second copy drifts (`connect_on_init`,
the 8,767 bytes, the three modules "blocked" on an open seam).

Two shapes, because a page has two kinds of block:

- `<!-- compiles -->` — the block declares functions. It gets
  `docs/snippets/types.zig` in front of it and a generated `export fn` that
  takes the address of each function, which is what drags the bodies in. An
  unreferenced private function is never analysed, so without that the check
  would be a syntax check wearing a compiler.
- `<!-- compiles: body -->` — the block is a run of statements. It gets
  `values.zig` as well — the `c`, `db` and `form` such a snippet says without
  introducing — and a function wrapped around it.

The two prelude files are split for one reason: a parameter named `c` cannot
shadow a declaration named `c`, so the request in flight cannot be in front of
a block that declares `fn signIn(c: *nilo.Ctx, …)`.

A snippet's own `const pw = @import("nilo_pw");` line is dropped on the way in.
The page should show it — that is half of what the snippet teaches — and
keeping it would be a second declaration of a name the prelude has already
made.

**The prelude is the documentation's running example, written once**: a `User`,
an `Account`, a `Signed`, a sign-in form, a `Doc` with a generated key. Nothing
in it stands in for a nilo type. The `Ctx`, the `Db`, the `Form` and the
`Session` are the real ones, which is the entire point.

## What was rejected

**A `docs/snippets/` directory of complete programs, cited by the guide.** The
mirror image of `refusals/`, and the shape the report that found this
suggested. It checks a copy. The moment somebody edits the page and not the
file, the build stays green and the reader stays wrong — which is the failure
mode this repository has hit four times and written an ADR about each time.

**Checking every `zig` block automatically.** Most of them are fragments with a
`…` in the middle, deliberately, because a fragment is easier to read than a
program. Marking is the decision that a block is a program, and it is a
decision somebody makes rather than one a walker guesses.

**A doctest runner of our own** — extracting, running, comparing output. The
mistakes found here are all *type* mistakes, and compiling catches every one of
them for a tenth of the machinery. Running a snippet needs a database.

**Scanning `///` doc comments in `.zig` files too.** `http/ctx.zig` carried one
of the three broken lines. It is a real gap and it stays open: a doc comment
is not markdown, has no fence, and would need its own extractor. The line
itself is fixed.

## What it costs

Nothing at run time — no snippet is in the shipped library. On `zig build test`
it is six object compilations, and **they cache**, which is the whole
difference from `refusals/`: a compilation that succeeds leaves something
behind, so a warm run is ~30ms each and only a changed page is re-analysed. All
46 refusals cost ~12.8s every run because a failed compilation leaves nothing.

That asymmetry is why this can afford to grow and why the refusals cannot.
`-Dsql=false` skips the step, because the running example has a database in it.
