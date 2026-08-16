# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

zfast is an HTTP framework for Zig 0.16. A plain Zig function is a route: the
compile-time engine reads its argument list and produces routing, typed input, a
400 for anything that does not fit, and an OpenAPI document. Nothing is
annotated. The one dependency is [zio](https://github.com/lalinsky/zio), pinned
in `build.zig.zon`.

Three files carry context this one deliberately does not repeat:

- **`CONTEXT.md`** — the project's vocabulary, and the words it refuses to use
  (Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative
  test"). Match it in code, comments, docs and commit messages.
- **`docs/adr/`** — 37 binding decisions, each naming the alternative it
  rejected. Check here before proposing a design change; "why not X?" usually
  already has an answer on file.
- **`docs/reference.md`** — the whole public API on one page.

## Commands

```
zig build test         # the loop: the suite in Debug, plus the refusals
zig build test-all     # the above, plus the same suite in ReleaseSafe — what CI runs
zig build refusals     # only the compile-error checks
zig build examples     # build all seven examples
zig build fuzz -- --iterations 1000000 --seed 0x…   # generated requests at the parser
zig build run          # the benchmark server (src/main.zig): GET /users/:id, ~1 KB JSON
zig build profile      # where the time inside one request goes
zig build run-{hello,rest,orders,forms,spa,stream,chat}   # run one example
./bench/bench.sh       # wrk/oha against an already-running ReleaseFast server
```

`-Dstrip=true|false` overrides the per-artifact debug-info default (release
builds of the two measured binaries strip; examples and tests keep theirs).

**The refusals are the slow part of `zig build test` and never cache** — the
compiler keeps nothing from a compilation that failed, so all of them are
re-analysed every run. They stay on `test` on purpose (ADR 0027).

### Running one test

No `-Dtest-filter` is wired into `build.zig`, so the build steps are all-or-
nothing. Modules that do not reach the Bulkhead run standalone with a filter:

```
zig test src/range.zig --test-filter "a suffix range"
```

That works for `str`, `cookie`, `percent`, `patch`, `names`, `json` and `range`.
Everything else imports the Engine transitively and needs the module graph, so
`zig build test` is the only way to run it.

## Architecture

Bottom to top. Each layer knows nothing about the one above it.

| Layer | Files | What it is |
|---|---|---|
| **Engine** | `src/engine/zio.zig` | accept, read, write. **The only file in the repo allowed to name zio** (ADR 0002). |
| **Bulkhead** | `src/bulkhead.zig` | the entire contract zfast asks of an Engine, listed in that file's header. `Options` is declared here rather than by the Engine, so swapping engines cannot change what a user writes. |
| **HTTP + App** | `src/http1.zig`, `src/router.zig`, `src/app.zig` | parse, match, dispatch. `App.handleRequest` takes only a `*std.Io.Reader`/`*std.Io.Writer`, which is why almost every HTTP behaviour is tested against in-memory buffers with no server. |
| **Ctx** | `src/ctx.zig` | one request in flight, and zfast's real API. |
| **Typed** | `src/typed.zig` | the compile-time engine. Reads the argument list and turns a typed handler into an ordinary Ctx handler. |

The rule the typed layer enforces is one sentence: **a pointer is a service, a
value is request data.** Path params are matched *by position*, because Zig does
not keep argument names.

Supporting modules, roughly by what they serve: `str` (request-lifetime text
plus the Debug-only use-after-request trap), `fail` (fail functions, message
stored in a box bound to the fiber — ADR 0007), `resolve` (resolved values,
worked out once per request), `service` (type-keyed registry, checked at
`listen()`), `middleware` (the onion), `form`/`bound`/`convert`/`patch`/`percent`
(request data into structs of the caller's own), `session`/`cookie`,
`static`/`sendfile`/`filebody`/`range` (files, in memory or opened per request),
`stream`/`body`/`websocket` (requests that outlive one read), `openapi`,
`watchdog` (times a handler that holds its thread), `logger`, `cors`.

A request: `readHead` → `parseHead` → the head is *borrowed* from the connection
read buffer unless the request will read again, in which case it is copied into
the arena (see `borrowed` in `app.zig` — it is worth reading before touching
that path) → route match → middleware chain → resolved values → handler →
response. The arena is reset per request, keeping `arena_keep` bytes.

## Invariants that are load-bearing

ADR 0018 splits "performance" into axes that do not recover the same way. Two of
them are hard:

- **Allocations per request.** Held by `test "the request path stays inside its
  allocation budget"` in `src/app.zig`. A DX feature may not add one to a path
  that did not ask for it.
- **Memory per idle connection.** 8,767 bytes, flat. Every feature that costs
  per-connection memory states the number in its own ADR.
- Throughput and p99: DX wins below 10%.
- Binary size: a feature the linker cannot drop states its measured cost, as a
  stripped `ReleaseFast` number, in the running total in ADR 0018.

## Conventions

**Error messages are a feature, and a build step holds them.** Each file in
`refusals/` is a program written wrong on purpose; it must fail to compile with
a message zfast wrote. Adding a comptime check means adding **both** a file in
`refusals/` and a row in the `refusals` table in `build.zig`. Leave the `zfast: `
prefix off the `.says` text — the build step supplies it, which is what makes a
failure inside the standard library impossible to record as passing. See
`refusals/README.md` and ADR 0027.

**Tests sit at the bottom of the file they test**, and are named as sentences
describing the behaviour, not the function: `test "a path param that is not a
number becomes a 400 with a clear message"`. New src files get an `_ =
@import(...)` line in the `test { … }` block at the end of `src/zfast.zig`, or
they never run. The examples carry tests too, and run in the same suite.

**Both optimize modes matter.** Debug is the loop; ReleaseSafe is the gate,
because a lifetime bug passes in Debug — where the bytes a dangling pointer
points at happen to still be there — and segfaults in the mode people deploy in.
`Str`'s lifetime trap is Debug-only by design.

**A `Str` never escapes its request** without `.keep()`. That applies inside the
framework as much as in user code.

**Doc comments say why, and name the ADR.** The header comment of every module
is the design rationale, including the alternatives that were measured and
dropped. Keep that habit — several of them exist because a number was measured
wrong once and corrected in place.

**Commit subjects are imperative sentences about the effect**, not conventional-
commit prefixes: "Stop the router reading routes that cannot match", "Give an
idle connection its pages back".

**Documentation is part of the change**, not a follow-up: a design decision goes
in a new `docs/adr/` file, what got built and what was measured goes in
`docs/history.md`, what is next or refused goes in `docs/roadmap.md`, and a
released change goes in `CHANGELOG.md`.

**The roadmap holds nothing that is built.** It is what is coming, what is
refused and what nobody has decided — a plan, not a record. The moment something
ships, its entry leaves `docs/roadmap.md` entirely: no strikethrough, no
"**Built**", no account of how it went. What was measured and what was learned
moves to `docs/history.md`, which is the record; the item is then cut, not
annotated. A gap only *partly* closed keeps one sentence scoping what is left,
never a paragraph about the half that landed. The test is that the roadmap can
be read top to bottom as work outstanding.

**`docs/history.md` stays short, and that is a constraint rather than a wish** —
it gains an entry every stage forever, so left alone it becomes the longest file
in the repository and the least read. An entry earns its place only by changing
what somebody would do next time: a number that was measured, a premise that
turned out false, a design that was tried and lost. Not what shipped, which is
the CHANGELOG's job, and not per-stage bookkeeping like test and refusal counts.
Once a lesson has been promoted into an ADR, history keeps the sentence and the
link rather than the story — the ADR is the canonical copy from then on. Prune
while writing, not later.

## Refused on the record

Templates, TLS, HTTP/2 and gRPC are not gaps — they are decisions (README "What
it won't do", ADR 0028). Do not add them; propose a change to the ADR instead.
