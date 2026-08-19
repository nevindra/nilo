# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**nilo is a toolkit for Zig 0.16 — eight modules, of which the largest is an HTTP
server.** It is not a framework with parts bolted beside it, and that
distinction decides where new work goes. What the modules share is one idea:
**your types are the contract, and the compiler is the check.** A plain Zig
function is a route, and its argument list produces routing, typed input, a 400
for anything that does not fit, and an OpenAPI document. A plain struct is a
table, and its fields produce the SQL before the program starts. Nothing is
annotated anywhere.

The project exists to put the ordinary parts within reach of somebody who picked
Zig up for an ordinary job — an API, a form, a settings struct, a password to
store. **A module gets built because that job is common, not because it is
interesting**, and it gets in only if it is expressible as a type the caller
already wrote, checked while compiling, with its cost written down (ADR 0018).
The name is the author's cat; the README says the rest, and the three words
there — helpful, quick, cheerful — are the order the trades are made in.

**The repository is modules, not one library** (ADR 0041). Which one a file
belongs in is decided by a single question — does it need the event loop?
`core/` needs none and is the vocabulary everything else shares; `http/` owns
the loop and is the server; `sql/` and `s3/` need the loop without owning it.
**A Fitting borrows the loop and owns no destination** — `fetch/` is one, and
ADR 0070 is where that fourth answer was added.
**A module imports downward only, and never a sibling**, which is what lets two
of them be worked on at once. Nothing under `http/` may be imported by `sql/`,
and the way a Service reaches request-lifetime memory is a Scope, not a `Ctx`.
`s3/` is the first module to name a Fitting, which is downward and is what
ADR 0070 built the layer for.

**The bottom layer holds more than one module** (ADR 0042). `core/` is the
vocabulary and sits under the rest of it; `id/`, `config/` and `pw/` are **tool
modules** — one job, no event loop, imports nothing above them. A Service may
import a tool module, which is downward. **The rule is a build step, not a
paragraph**: `zig build layering` reads the `@import`s under `core/`, `id/`,
`config/`, `pw/`, `fetch/`, `sql/` and `s3/` and refuses one that is not in that
module's row of the `layers` table in `build.zig`. Adding a module means adding
a row — there and in `shipped_roots`, and in `.paths` in `build.zig.zon`.

A tool module *may* name `nilo_core` and neither of them does, which is not an
accident: naming it costs the property that decides the layer — running under a
plain `zig test`, with no module graph. ADR 0043 is where that was settled, and
it is why `nilo_config` reads `[]const u8` rather than `Str` and carries forty
lines of converter of its own instead of sharing `http/convert.zig`.

**The framework's one dependency is [zio](https://github.com/lalinsky/zio)**,
pinned in `build.zig.zon`. The SQL module adds
[pg.zig](https://github.com/lalinsky/pg.zig), which brings four of its own
(buffer, metrics, xsync, tls), and [zqlite](https://github.com/karlseguin/zqlite.zig),
which brings the SQLite amalgamation. **A project that serves HTTP and never
imports `nilo_sql` does not fetch, build or link any of them** — and it is
`-Dsql`, not `.lazy = true`, that makes the first third of that true.
`b.lazyDependency` is a *request*: called unconditionally it runs for every
dependent whatever they import, which is how an app with no database in it
downloaded 11.1 MB of driver for a year (ADR 0075). A dependent that wants the
module passes `.sql = true` to `b.dependency("nilo", …)`.
**`zig build fetch-check -Dnetwork` is what holds that** — it builds
`bench/dependent/`, which imports `nilo_http` and nothing else, against two cold
caches and fails on anything but zio landing. Not on `test`, for the reason
`smoke-tls` is not: it needs the internet.

Three files carry context this one deliberately does not repeat:

- **`CONTEXT.md`** — the project's vocabulary, and the words it refuses to use
  (Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative
  test"). Match it in code, comments, docs and commit messages.
- **`docs/adr/`** — 88 binding decisions, each naming the alternative it
  rejected. Check here before proposing a design change; "why not X?" usually
  already has an answer on file. **ADR 0041 decides which module new work goes
  in and ADR 0042 decides what that module may import**, and they are the two
  to read before adding a file anywhere but `http/`. ADR 0043 is the first
  reading of 0042 under load, and ADR 0072 is the second — the first module to
  import a Fitting — so both are worth the ten minutes before adding a ninth
  module.
- **`docs/reference.md`** — the whole public API on one page.

## Who works here

The repository is written to be worked on by somebody who did not write it —
another person, or a model — and that is a constraint on how a change is made
rather than a hope about who turns up. **Nothing load-bearing may live only in
the author's head, only in a commit body, or only in this session.** A decision
goes in an ADR, a number goes in `docs/history.md`, a rule goes in a build step.

Two of those rules are build steps rather than paragraphs, and they are the ones
to lean on: `zig build layering` refuses an import that goes upward or sideways,
and the five `refusals` steps check the wording of 141 error messages. Prefer making
a new rule enforceable that way over writing it down here — a paragraph nobody
runs is the thing that rots.

`CONTRIBUTING.md` is the outward-facing half of this, and it lists the four
things a change has to carry: which axis it spends and the number, its refusals,
its tests in both optimize modes, its documentation. When proposing work,
propose it in that shape. Anything that changes those four rules, the commands,
or the layout has to change there and here together.

## Commands

```
zig build test         # the loop: the suite in Debug, plus the refusals
zig build test-all     # the above, plus the same suite in ReleaseSafe — what CI runs
zig build test-core    # only Core, both modes — no Engine, no module graph
zig build test-id      # only nilo_id, the same way
zig build test-config  # only nilo_config, the same way, plus its refusals
zig build test-pw      # only nilo_pw, the same way, plus its refusals
zig build test-fetch   # only nilo_fetch, both modes — a real socket, no Engine
zig build test-fetch-engine  # an outbound deadline firing against a real port; on `test`
zig build test-s3      # only nilo_s3, both modes, plus its refusals
zig build layering     # check that no module imports upward or sideways
zig build refusals     # the framework's 75 compile-error checks — NOT the others
zig build refusals-sql # nilo_sql's 44; also run by test-sql
zig build refusals-config  # nilo_config's 9, and refusals-pw for nilo_pw's 3
zig build refusals-s3  # nilo_s3's 10; also run by test-s3
zig build snippets     # the documentation's own marked snippets, which must compile
zig build smoke-tls -Dnetwork   # a real HTTPS endpoint — NOT part of test
zig build examples     # build all eight examples
zig build fuzz -- --iterations 1000000 --seed 0x…   # generated requests at the parser
zig build bench-sql    # what a prepared statement is worth: SQLite always, Postgres if reachable
zig build bench-sql-server  # a server reading Postgres per request, for wrk/oha
zig build bench-fetch-server # what an outbound call costs, with its controls
zig build bench-s3-server  # a server reading an object store per request, with its controls
zig build bench-ws-server  # a server of idle WebSockets, for what one costs
python3 bench/mem.py --port … --path …   # memory per idle connection, any server
python3 bench/ws_idle.py both            # the same axis for WebSockets, nilo and gws
python3 bench/s3_setup.py                # the bucket and objects both of the above want
python3 bench/compare-s3/drive.py        # nilo_s3 against Go, Rust and Bun — needs MinIO
zig build run          # the benchmark server (bench/main.zig): GET /users/:id, ~1 KB JSON
zig build profile      # where the time inside one request goes
zig build run-{hello,rest,orders,forms,spa,stream,chat,outbound}  # run one example
./bench/bench.sh       # wrk/oha against an already-running ReleaseFast server
```

`-Dstrip=true|false` overrides the per-artifact debug-info default (release
builds of the two measured binaries strip; examples and tests keep theirs).

**The refusals are the slow part of `zig build test` and never cache** — the
compiler keeps nothing from a compilation that failed, so all of them are
re-analysed every run. They stay on `test` on purpose (ADR 0027).

**Read the exit code, not the word "failed".** A passing run of `test` and
`test-all` prints several `failed command: ./.zig-cache/…/test …` lines and
still exits 0: `zig build` prints one for every step that wrote to stderr, and
tests that exercise a warning path do exactly that. The signals that mean
something are the **exit code** and a `Build Summary` line reporting a failed
step; without those, the `failed command:` lines are noise.

**And take a stuck build's CPU time before believing it is slow.** Because the
refusals are a documented slow path, "the suite takes a while" is always an
available explanation and it is the perfect hiding place for a deadlock —
`fetch/live.zig` held one for a fortnight. `ps -o etime,cputime -C zig` settles
it in one command: seven minutes of wall against two seconds of CPU is not a
slow build, and the tests worth suspecting first are the ones that open a real
socket at both ends (`test-fetch`, `test-s3`).

### Running one test

No `-Dtest-filter` is wired into `build.zig`, so the build steps are all-or-
nothing. Modules that do not reach the Bulkhead run standalone with a filter:

```
zig test http/range.zig --test-filter "a suffix range"
```

That works for `cookie`, `patch`, `names`, `json` and `range`.
Everything else under `http/` imports the Engine transitively and needs the
module graph, so `zig build test` is the only way to run it.

**The bottom layer is the exception, and by design rather than by luck**
(ADR 0041, ADR 0042):

```
zig test core/core.zig                  # the vocabulary, no build.zig
zig test id/id.zig                      # nilo_id, likewise
zig test config/config.zig              # nilo_config, likewise
zig test pw/pw.zig                      # nilo_pw, likewise
zig build test-core                     # the same, both optimize modes
zig build test-id
zig build test-config
zig build test-pw
```

A Fitting cannot quite do that — it borrows the loop — but it comes one step
short, and the step is the layer's entry condition rather than a convenience
(ADR 0070):

```
zig test --dep nilo_core -Mroot=fetch/fetch.zig -Mnilo_core=core/core.zig
zig build test-fetch                    # the same, both optimize modes
```

That opens a real socket at both ends on `std.Io.Threaded`, which is std's own.
**No zio anywhere.** A change that makes `fetch/` need the Engine has put the
module in the wrong layer.

**`zig build test-fetch-engine` is the one deliberate exception**, and it is a
root of its own for exactly that reason: `fetch/deadline.zig` names `nilo_http`
and watches an outbound deadline actually fire against a real server. Putting
those tests in `fetch/fetch.zig`'s test block would make `zig test
fetch/fetch.zig` need a server and cost the Fitting layer its entry condition.
It hangs off `zig build test`, and **it is the first test here that opens a
real port**, the harness `docs/roadmap.md`'s standing risks have wanted for
`sendfile` and the WebSocket, which is why two entries there now read
`Waiting on: ready`.

`nilo_s3` runs on `std.Io.Threaded` too — its canned server and its live tests
both open real sockets with no Engine anywhere — but it needs the module graph
regardless, because `s3/live.zig` names the build-generated `s3_config`. So
`zig build test-s3` is the only way to run it, and that is a property of how it
is configured rather than of its layer.

A module that needs no event loop is a module whose tests need no module graph,
which is the property the layering exists to buy. **For a module down there it
is the entry condition rather than a nicety**: one whose tests need the module
graph is in the wrong layer. If a change ever stops one of those commands
working, the layering has been broken rather than the test.

## Architecture

Bottom to top. Each layer knows nothing about the one above it.

| Layer | Files | What it is |
|---|---|---|
| **Core** | `core/` | `Str`, the Scope, the clock and percent coding. The vocabulary every layer agrees about, and no IO at all — a separate module (`nilo_core`) that names no Engine, so `zig test core/core.zig` runs the whole of it (ADR 0041). A file gets in by being needed by two layers, which is how `percent` arrived (ADR 0066). |
| **Tools** | `id/`, `config/`, `pw/` | one job each, no event loop, and `nilo_core` is the most they may import. All three import nothing at all (ADR 0042, ADR 0043, ADR 0048). |
| **Fitting** | `fetch/` | borrows the loop, owns no destination — an HTTP client for calling somebody else's API. Imports `nilo_core` and nothing else; its tests run under `std.Io.Threaded` with no Engine, which is the entry condition for the layer (ADR 0070). |
| **Services** | `sql/`, `s3/` | borrow the loop and hold a named system — a Postgres pool, a SQLite file, an object store's endpoint and credentials. **A SQLite statement is the one thing down here that blocks with nothing to wait on**, which is why `sqlite.Options.threading` has no default (ADR 0073). `s3/` is the only module that imports a Fitting, which is downward and is what the layer was built for (ADR 0072). Neither may name `nilo_http`. |
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
`listen()`), `middleware` (the onion), `form`/`bound`/`convert`/`patch`
(request data into structs of the caller's own — the percent coding they lean
on is Core's now, ADR 0066), `session`/`cookie`, `password` (the Gate and the salt in front of `nilo_pw` — ADR 0048),
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
- **Memory per idle connection.** 4,669 bytes for the framework, flat, and
  5,183 for an idle WebSocket — and that is a **floor rather than a total**. A
  suspended fiber holds its stack at its high-water mark, so a handler adds
  every byte of stack it ever touched, one for one, for the life of the
  connection: an ordinary database route measured 17,022
  ([ADR 0063](docs/adr/0063-a-handlers-stack-is-per-connection.md)).
  Every feature that costs per-connection memory states the number in its own
  ADR, and **in this framework the arena is cheaper than the stack**.
  **Where a fiber is suspended is also what it costs** — the framework's own
  frames are kept under one page on purpose, and a `std.log` call inlined into
  a connection loop puts its format machinery there
  ([ADR 0071](docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).
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

### A benchmark that was run gets written down

**[`bench/result/`](bench/result/) gets an entry for every run that changed a
decision, and the entry says what it changed.** Not the terminal, not a commit
body, not a sentence in a session — the file. One file an area, named for it:
[`http.md`](bench/result/http.md) for the server,
[`sql.md`](bench/result/sql.md) for the database,
[`fetch.md`](bench/result/fetch.md) for the way out,
[`s3.md`](bench/result/s3.md) for the object store. Each carries what was run,
the machine, the commit, the numbers, and the decision they moved — and a
closing section saying whether the number can be pushed further, so the next
person starts from the ranked levers rather than from the top. A run that
changed nothing still earns an entry if somebody would otherwise repeat it.

This is a rule because the repository has already been wrong four times about
things that *were* published: `connect_on_init` was documented in three files
and had never worked ([ADR 0062](docs/adr/0062-a-pool-that-dialled-itself-whatever-it-was-told.md));
"8,767 bytes per idle connection, flat" was repeated in four and described
a handler nobody deploys ([ADR 0063](docs/adr/0063-a-handlers-stack-is-per-connection.md));
three modules were listed as blocked on a seam that had been open since
[ADR 0040](docs/adr/0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md),
on the strength of a dependency manifest nobody opened; and the 8,767 was then
repeated in six more files while half of it was a page the connection was
holding for no reason
([ADR 0071](docs/adr/0071-where-a-connection-waits-is-what-it-costs.md)).
Three were found by re-measuring and one by reading somebody else's manifest;
none would have been findable from prose. **A number with no run behind it
decays into a claim, and a premise decays the same way and costs more, because
a wrong premise gets planned against.**

**A conclusion of "blocked on somebody else" gets one more hour than it feels
like it needs.** ADR 0063 recorded the stack fix as blocked on zio, wrote it
into the roadmap and filed an issue; the call it needed was public in the
pinned version, one file over. Nothing downstream ever re-tests a blocker.

Six habits go with it, each of which caught something here:

- **Say what the number was measured *through*.** Every figure in this cycle
  was taken across a Docker published port, and the same server over a unix
  socket is 133% faster. The ratios survived; the absolutes were half.
- **Measure a per-operation saving twice** — once unloaded, where it tells the
  truth about the work, and once at the pool, where it tells the truth about
  the service. Prepared statements are 24% at one request in flight and 67%
  at a pool under load, because a pool connection is a serial queue.
- **Put something next to it.** `/health`, `/fixed/:id` and `/deep/:id` exist
  in `bench/sql_server.zig` only so `/people/:id` has controls, and the fourth
  route is what proved the memory finding had nothing to do with the database.
- **Build the before, do not quote it — then run both more than once.** The
  primary metric was 1.31M req/s in a published table and 1.42M on the same
  machine months later, so a change measured against the published figure would
  have claimed a 9% win it did not earn. `git archive HEAD | tar -x` into a
  scratch directory is one command. Doing that and then taking **one run each**
  still published a 4% win that four interleaved pairs put at +0.6% with the
  sign changing between pairs. Interleave them, and if the margin is inside the
  spread, the answer is "unchanged".
- **Take a per-connection figure out until marginal meets average, and take the
  other side of the comparison out too.** At 2,000 sockets two WebSocket rows
  read 60 bytes high and looked like a property of the socket; at 10,000 all
  four collapsed onto 5,183. Marginal disagreeing with average means you are
  still measuring a transient. Running gws to 10,000 as well cost one command
  and moved its best row *in its favour*, from 8,206 to 7,836 — **run it out
  especially when it helps them**, because a comparison where one side is
  converged and the other is not has a thumb on it.
- **Pin both sides, or the number is about the scheduler.** Unpinned, gws
  echoes 1,029,308 messages a second on this box; pinned to the cores nilo
  gets, 1,558,146 against nilo's 1,685,719. The honest margin is 5–8%, not
  68% — and it is a band rather than a figure because four runs put it at
  7.0, 8.2, 7.1 and 4.7. **A margin narrower than its own spread is quoted
  as a range or it is quoted wrong.**

Then the lesson goes to `docs/history.md` and the decision to an ADR, the way
everything else does. `bench/result/` is the raw record those two cite.

## Conventions

**Error messages are a feature, and a build step holds them.** Each file in
`refusals/` is a program written wrong on purpose; it must fail to compile with
a message nilo wrote. Adding a comptime check means adding **both** a file in
`refusals/` and a row in the matching table in `build.zig`. **There are four
tables and four steps**, one per module — `refusals`, `sql_refusals`,
`config_refusals`, `pw_refusals` — and adding a row to one while running
another is a check that silently never ran. Leave the `nilo: `
prefix off the `.says` text — the build step supplies it, which is what makes a
failure inside the standard library impossible to record as passing. See
`refusals/README.md` and ADR 0027.

**A published snippet is a program, and a build step compiles it.** Put
`<!-- compiles -->` above a fenced `zig` block in the README, the reference or
a guide page and `zig build snippets` extracts it, puts `docs/snippets/types.zig`
in front of it, and compiles it — `<!-- compiles: body -->` for a block of loose
statements, which gets `values.zig` and a function around it as well. The block
in the page is the only copy; there is no file to keep in step. Unlike the
refusals these **cache**, so marking another one is nearly free. ADR 0083 is the
account, including the seven mistakes writing it found in one five-line example.

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

**Commits are conventional-commit prefixes, and the body is short.** The subject
is `type: imperative sentence about the effect` — `feat`, `fix`, `refactor`,
`perf`, `docs`, `test`, `build`, `chore`, with `!` for a break. Say what
changed, not which files: `fix: stop the router reading routes that cannot
match`, not `fix: router.zig`.

The body is optional and earns its place by explaining *why* or naming a number
— **a few sentences, not three paragraphs.** The long-form account belongs in
the places built for it: what was measured and what turned out false in
`docs/history.md`, the decision and its rejected alternative in `docs/adr/`,
what a reader has to change in `CHANGELOG.md`. A commit body that repeats those
is a fourth copy to keep in step. Commits before `b662f01` are bare imperative
sentences with long bodies, which is the older convention rather than a mistake.

**Documentation is part of the change**, not a follow-up: a design decision goes
in a new `docs/adr/` file, what got built and what was measured goes in
`docs/history.md`, what is next or refused goes in `docs/roadmap.md`, and a
released change goes in `CHANGELOG.md`.

**The roadmap holds nothing that is built.** It is what is coming, what is
refused and what nobody has decided: a plan, not a record. The moment something
ships, its entry leaves `docs/roadmap.md` entirely: no strikethrough, no
"**Built**", no account of how it went. What was measured and what was learned
moves to `docs/history.md`, which is the record; the item is then cut, not
annotated. A gap only *partly* closed keeps one sentence scoping what is left,
never a paragraph about the half that landed. The test is that the roadmap can
be read top to bottom as work outstanding.

**The other six rules live in the roadmap itself**, under
[How this file is written](docs/roadmap.md#how-this-file-is-written), which is
the canonical copy rather than a summary of this paragraph. The two that get
forgotten: every entry opens with its whole claim in bold, and every entry
closes with a `Waiting on:` line from a fixed list. That closing line is what
makes a blocker that has quietly stopped being one findable, which this
repository has needed four times.

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

<!-- devrun:begin -->
## Running this project's services

`devrun` runs every service in `process-compose.yaml` at once and keeps
each one's output in a plain file under `.devrun/logs/latest/`. Prefer it over
running a single dev server in the background: with one server you only
see that server's output, and the error is usually in another one.

```console
$ devrun up --detach      # start everything; returns once all are ready
$ devrun errors           # did anything break, and the log under it
$ devrun logs --since 2m  # every service's output, merged by time
$ devrun down             # stop everything
```

With no `process-compose.yaml`, supervise one command instead. The same
`logs`, `errors` and `down` work against it.

```console
$ devrun run --detach --ready-log "listening on" pnpm dev
```

`devrun run` exits with the command's own exit status. Its words pass
through untouched, so devrun's flags go before the command.

`devrun up --detach` exits non-zero if a service fails to come up, and
`devrun errors` exits non-zero while anything is broken, so both can be
branched on without reading their output.

Useful flags on `logs` and `errors`: `--grep 'panic|ERROR'`, `--tail N`,
`--since 30s`, `--json`, and `--raw` to defeat the trimming. Output is
bounded by default and says at the end what it left out. Run `devrun`
with no arguments for the rest.
<!-- devrun:end -->
