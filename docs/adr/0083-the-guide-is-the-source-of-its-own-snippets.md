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
it is one object compilation per marked block — 54 of them — and **they cache**, which is the whole
difference from `refusals/`: a compilation that succeeds leaves something
behind, so a warm run is ~30ms each and only a changed page is re-analysed. All
46 refusals cost ~12.8s every run because a failed compilation leaves nothing.

That asymmetry is why this can afford to grow and why the refusals cannot.
`-Dsql=false` skips the step, because the running example has a database in it.

## The SQL guide, and what four small rules bought

Amended after `docs/guide/sql.md` was marked: 37 of its 51 blocks, against 17
across the eight pages before it. Nothing above changes; four things were
added, each because the page could not be checked without it.

**A page may have a prelude of its own.** `pages` is a list of
`Page { path, types, values }` now, and the SQL guide points at
`docs/snippets/sql_types.zig`. It is the page that *teaches* tables: its
`User` has an `age`, an `orders` counter and a `created_at` the sign-in
example next door has no use for, and it needs an `Order`, an `Item` and five
more besides — seven types of noise in front of a snippet about a cookie. A
page whose types are the subject gets to own them.

**A block of statements is given the shapes the page declared, but not its
functions.** `<!-- compiles -->` blocks already accumulated, so that a page
could show its struct once; a body block got only the prelude, which meant a
guide could not show a `User` and then write a statement about it. The reason
was real but narrower than the rule: a `fn rename(db, c, …)` cannot sit in
front of the file-scope `db` and `c` the statements need. So the accumulator
is split — declarations that introduce no function of their own reach a body
block too, and the SQL guide declares its `User` in the first marked block on
the page rather than in a prelude that would be a second copy of it.

**A value the snippet declares for itself is not also handed to it.**
`var tx = try db.begin(c, .{});` opens five snippets in the transactions
section, and `tx` is the name the sixth uses without opening anything. Both
are how a person writes it, and Zig refuses a local that shadows a
declaration. The prelude carries every name and the ones a block introduces
are dropped on the way in.

**A local the snippet does not read is discarded for it.** `const all = try
db.select(…);` is the line a page is teaching, and Zig refuses a local nobody
reads. The alternative was `_ = all;` published under it, which is this build
step leaking into the documentation — the one thing this ADR was careful not
to do. The generated `_ = &name;` is the same trick the `export fn` above
already plays for functions.

### What marking the page found

Two of them are documentation and one is not:

- **`db.update(User, c, .{ .set = .{ .age = 31 }, .where = .{ .id = made.id } })`
  did not compile.** A literal has no type of its own, so `where.valueAt` on
  that path returned `comptime_int` — and a function with a comptime-only
  return type is evaluated at comptime, whole, which then cannot reach the
  runtime `id` in the same options struct. The message named `options`, a
  parameter the caller never wrote, three functions in. It is the most
  ordinary line on the page and it is fixed here (`where.valueAtAs`), along
  with the two other values that have no type of their own: a `null` and an
  enum name.
- **`db.raw` takes a Row, and the guide passed it a bare struct twice.** A
  Row names a relation; `raw` never reads the name, because it did not write
  the statement. The page says so now and its examples name a view.
- **The running `User` was missing two columns its own examples set.**
  `.set = .{ .name = … }` and `.set = .{ .orders = user.orders + 1 }` were
  both written against a struct four screens up that had neither.
