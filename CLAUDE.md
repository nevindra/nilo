# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

nilo is an HTTP framework for Zig 0.16. A plain Zig function is a route: the
compile-time engine reads its argument list and produces routing, typed input, a
400 for anything that does not fit, and an OpenAPI document. Nothing is
annotated.

**The repository is modules, not one library** (ADR 0041). Which one a file
belongs in is decided by a single question — does it need the event loop?
`core/` needs none and is the vocabulary everything else shares; `http/` owns
the loop and is the HTTP framework; `sql/` needs the loop without owning it.
**A module imports downward only, and never a sibling**, which is what lets two
of them be worked on at once. Nothing under `http/` may be imported by `sql/`,
and the way a Service reaches request-lifetime memory is a Scope, not a `Ctx`.

**The framework's one dependency is [zio](https://github.com/lalinsky/zio)**,
pinned in `build.zig.zon`. The SQL module adds
[pg.zig](https://github.com/lalinsky/pg.zig), which brings four of its own
(buffer, metrics, xsync, tls) and is marked `.lazy = true` — a project that
serves HTTP and never imports `nilo_sql` does not fetch, build or link any of
it, and that is the property to keep (ADR 0040).

Three files carry context this one deliberately does not repeat:

- **`CONTEXT.md`** — the project's vocabulary, and the words it refuses to use
  (Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative
  test"). Match it in code, comments, docs and commit messages.
- **`docs/adr/`** — 41 binding decisions, each naming the alternative it
  rejected. Check here before proposing a design change; "why not X?" usually
  already has an answer on file. **ADR 0041 decides which module new work goes
  in**, and it is the one to read before adding a file anywhere but `http/`.
- **`docs/reference.md`** — the whole public API on one page.

## Commands

```
zig build test         # the loop: the suite in Debug, plus the refusals
zig build test-all     # the above, plus the same suite in ReleaseSafe — what CI runs
zig build test-core    # only Core, both modes — no Engine, no module graph
zig build refusals     # only the compile-error checks
zig build examples     # build all seven examples
zig build fuzz -- --iterations 1000000 --seed 0x…   # generated requests at the parser
zig build run          # the benchmark server (bench/main.zig): GET /users/:id, ~1 KB JSON
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
zig test http/range.zig --test-filter "a suffix range"
```

That works for `cookie`, `percent`, `patch`, `names`, `json` and `range`.
Everything else under `http/` imports the Engine transitively and needs the
module graph, so `zig build test` is the only way to run it.

**Core is the exception, and by design rather than by luck** (ADR 0041):

```
zig test core/core.zig                  # the whole bottom layer, no build.zig
zig build test-core                     # the same, both optimize modes
```

A module that needs no event loop is a module whose tests need no module graph,
which is the property the layering exists to buy. If a change to `core/` ever
stops that command working, the layering has been broken rather than the test.

## Architecture

Bottom to top. Each layer knows nothing about the one above it.

| Layer | Files | What it is |
|---|---|---|
| **Core** | `core/` | `Str` and the Scope. The vocabulary every layer agrees about, and no IO at all — a separate module (`nilo_core`) that names no Engine, so `zig test core/core.zig` runs the whole of it (ADR 0041). |
| **Engine** | `http/engine/zio.zig` | accept, read, write. **The only file in the repo allowed to name zio** (ADR 0002). |
| **Bulkhead** | `http/bulkhead.zig` | the entire contract nilo asks of an Engine, listed in that file's header. `Options` is declared here rather than by the Engine, so swapping engines cannot change what a user writes. |
| **HTTP + App** | `http/http1.zig`, `http/router.zig`, `http/app.zig` | parse, match, dispatch. `App.handleRequest` takes only a `*std.Io.Reader`/`*std.Io.Writer`, which is why almost every HTTP behaviour is tested against in-memory buffers with no server. |
| **Ctx** | `http/ctx.zig` | one request in flight, and nilo's real API. |
| **Typed** | `http/typed.zig` | the compile-time engine. Reads the argument list and turns a typed handler into an ordinary Ctx handler. |

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
  allocation budget"` in `http/app.zig`. A DX feature may not add one to a path
  that did not ask for it.
- **Memory per idle connection.** 8,767 bytes, flat. Every feature that costs
  per-connection memory states the number in its own ADR.
- Throughput and p99: DX wins below 10%.
- Binary size: a feature the linker cannot drop states its measured cost, as a
  stripped `ReleaseFast` number, in the running total in ADR 0018.

**A feature that cannot be made to fit does not ship in a worse shape.**
Response compression is what that looks like: the shape that fits is known, it
has not been built, and no allocating-per-request version was shipped meanwhile.

**Every change is put against all four before it is written.** Which axis it
spends, and the number, is part of proposing it — not something worked out after
it lands, or left for review to ask about. That applies to a design argued in a
session as much as to a diff, and a proposal that skips it is not finished.

## Conventions

**Error messages are a feature, and a build step holds them.** Each file in
`refusals/` is a program written wrong on purpose; it must fail to compile with
a message nilo wrote. Adding a comptime check means adding **both** a file in
`refusals/` and a row in the `refusals` table in `build.zig`. Leave the `nilo: `
prefix off the `.says` text — the build step supplies it, which is what makes a
failure inside the standard library impossible to record as passing. See
`refusals/README.md` and ADR 0027.

**Tests sit at the bottom of the file they test**, and are named as sentences
describing the behaviour, not the function: `test "a path param that is not a
number becomes a 400 with a clear message"`. New src files get an `_ =
@import(...)` line in the `test { … }` block at the end of `http/http.zig`, or
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
