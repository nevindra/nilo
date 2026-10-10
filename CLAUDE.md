# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. It holds what a session needs every time; anything needed once in a while lives in its own file and is linked from here.

## What this is

**nilo is an HTTP framework for Zig 0.17, and the toolkit it is built from: twelve modules, of which the largest is the framework.** The repository is the Toolkit and `nilo_http` is the Framework (`CONTEXT.md` has both words). What they share is one idea: **your types are the contract, and the compiler is the check.** A plain Zig function is a route, and its argument list produces routing, typed input, a 400 for anything that does not fit, and an OpenAPI document. A plain struct is a table, and its fields produce the SQL before the program starts. Nothing is annotated.

**A module gets built because the job is common, not because it is interesting**, and it gets in only if it is expressible as a type the caller already wrote, checked while compiling, with its cost written down (ADR 017). The README's three words, helpful, quick, cheerful, are the order the trades are made in.

Four places carry context this one does not repeat:

- **`CONTEXT.md`**: the vocabulary and the words the project refuses (Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative test"). Match it in code, comments, docs and commit messages.
- **`docs/adr/`**: the binding decisions, each naming the alternative it rejected, and each the rule in force: a change to a decision edits its ADR in place, and a new number is for a new decision (ADR 221). Every ADR names its topic; a topic with a page in `docs/design/` is where to start reading it. Check here before proposing a design change; "why not X?" usually has an answer on file. The ADRs were renumbered once to three digits, so a four-digit number is an old one: `docs/adr/renumbered.md` translates it, and `zig build adr-check` refuses it anywhere else. **ADR 038 decides which module new work goes in and what that module may import**; read it before adding a file anywhere but `http/`, and ADR 039 and 063 before adding a module.
- **`docs/reference/`**: the whole public API, one page a module.
- **`docs/README.md`**: the map, one row per topic with its guide, reference and design page. Every doc page's line 3 says what it is and line 5 links its other two layers, so `head -5` over a folder is its table of contents (ADR 236).

## Guiding principles

These come before everything below, and a proposal that breaks one says which and why.

1. **Developer experience comes first, and performance comes with it, not after it.** When the two pull apart, DX wins, within ADR 017's budget: below 10% of throughput and p99, and never a byte of the two hard axes (allocations per request, memory per idle connection). Fast and small are numbers on the record, not adjectives: a run in `bench/result/` behind each figure.
2. **The best developer experience the language allows, and the user's code kept safe while giving it.** The type they already wrote is the API, a mistake is a compile error naming it (a refusal) before it is a runtime one, and nothing gets easier by getting less safe: a convenience that would need undefined behaviour in ReleaseFast, a panic a request can reach, or a lifetime the compiler cannot see does not ship.
3. **Build the clean, proper and beautiful solution, not the quick one.** nilo is growing, and a bad design that gets improved instead of replaced keeps producing more of itself. The edge of a young project is that things are expected to break: a breaking change that buys the cleaner design is paid now, with a `CHANGELOG.md` entry saying what a user changes, rather than carried for ever. What this does not license is shipping in a worse shape to ship sooner; a design that cannot fit the four axes waits for one that does.
4. **Be objective.** A claim rests on code read or a number measured, and says which. Say where a proposal is weak, the user's and your own included, recommend against it when the evidence does, and report a result that went the wrong way as plainly as one that went the right way.
5. **A recommendation is tested before it is given, and again after.** Put it against the real cases (the clients, proxies, protocols and other frameworks that meet it), against every stage the roadmap says comes later, and against what it closes off; then give it, with what it fails at. Never "this now, that later" when the later thing is one many others depend on: that is the design deferred, not simplified. Design it whole and build it in stages.

## Who works here

The repository is written to be worked on by somebody who did not write it, a person or a model. **Nothing load-bearing may live only in the author's head, only in a commit body, or only in this session.** A decision goes in an ADR, a lesson in `docs/history.md`, a rule in a build step. **Prefer making a rule enforceable over writing it down here**: a paragraph nobody runs is the thing that rots. `zig build layering`, `adr-check`, `docs-check` and the refusal steps are the ones to lean on.

`CONTRIBUTING.md` is the outward-facing half: the four things a change carries (which axis it spends and the number, its refusals, its tests in both optimize modes, its documentation). Propose work in that shape. A change to those rules, the commands or the layout changes there and here together.

## Layout

**The repository is modules, not one library** (ADR 038), and one question decides where a file goes: does it need the event loop? **A module imports downward only, and never a sibling**, which is what lets two of them be worked on at once. A Service reaches request-lifetime memory through a Scope, never a `Ctx`.

| Layer | Files | What it is |
|---|---|---|
| **Core** | `core/` | `Str`, the Scope, the clock, percent coding: the vocabulary every layer agrees about. Needs no loop, names no Engine, so `zig test core/core.zig` runs all of it. A file gets in by being needed by two layers (ADR 057). |
| **Tools** | `id/`, `config/`, `pw/`, `cache/`, `jwt/`, `proto/` | one job each, no event loop. They *may* name `nilo_core` and none does: that would cost running under a plain `zig test`, the property that decides the layer (ADR 038, ADR 039). `cache/` spins because `std.Io.Mutex.lock` takes an `Io` this layer has none of, so nothing that waits goes inside its critical section. |
| **Fitting** | `fetch/`, `job/` | borrows the loop, owns no destination: an HTTP client, and a queue whose store is handed to it (`job.Table(Db)` takes the caller's Db type, ADR 160). Import `nilo_core` only; tests run on `std.Io.Threaded` with no Engine, which is the layer's entry condition (ADR 061). |
| **Services** | `sql/`, `s3/` | borrow the loop and hold a named system: a Postgres pool, a SQLite file, an object store. A SQLite statement blocks with nothing to wait on, which is why `sqlite.Options.threading` has no default (ADR 064). `s3/` imports a Fitting (ADR 063). Neither may name `nilo_http`. |
| **Engine** | `http/engine/zio.zig` | accept, read, write. **The only file allowed to name zio** (ADR 001). |
| **Bulkhead** | `http/bulkhead.zig` | the whole contract nilo asks of an Engine, listed in its header. `Options` lives here so swapping engines cannot change what a user writes. |
| **HTTP + App** | `http/http1.zig`, `http/router.zig`, `http/app.zig` | parse, match, dispatch. `App.handleRequest` takes only a `*std.Io.Reader` and `*std.Io.Writer`, so almost every HTTP behaviour is tested on in-memory buffers. |
| **Ctx** | `http/ctx.zig` | one request in flight, and nilo's real API. |
| **Typed** | `http/typed.zig` | the compile-time engine: turns a typed handler into a Ctx handler. **A pointer is a service, a value is request data.** Path params match by position, because Zig keeps no argument names. |

**The layering rule is a build step**, and like `adr-check`, `docs-check` and `fetch-check` it is a subcommand of the one program in `checks/`, which `build.zig` runs because Zig 0.17 has no step with a function of its own: `zig build layering` reads the `@import`s of every module but `http/` and refuses one missing from that module's row of `layers` in `build.zig`. Adding a module means a row there, in `shipped_roots`, and in `.paths` in `build.zig.zon`, and a program in `bench/release/`, which `bench/release.py` refuses to run without.

A request: `readHead` → `parseHead` → the head is *borrowed* from the read buffer unless the request will read again, when it is copied into the arena (read `borrowed` in `app.zig` before touching that path) → route match → middleware chain → resolved values → handler → response. The arena is reset per request, keeping `arena_keep` bytes. The rest of `http/`, by what it serves: `str` (request-lifetime text and the Debug-only use-after-request trap), `fail` (ADR 006), `resolve`, `service`, `middleware`, `form`/`bound`/`convert`/`patch`, `session`/`cookie`, `password` (the Gate in front of `nilo_pw`, ADR 044), `static`/`sendfile`/`filebody`/`range`, `stream`/`body`/`websocket`, `openapi`, `watchdog`, `logger`, `cors`.

### Dependencies and build flags

**The one dependency of a plain HTTP build is [zio](https://github.com/lalinsky/zio)**, pinned in `build.zig.zon`. Everything else sits behind a flag a dependent passes to `b.dependency("nilo", …)`, and a build without the flag fetches, builds and links none of it:

| flag | brings | ADR |
|---|---|---|
| `.sql = true` (`-Dsql`) | pg.zig (with buffer, metrics, xsync, tls) and zqlite (the SQLite amalgamation, compiled `ReleaseFast` by `zqliteFor` whatever the program's mode; zqlite's Zig keeps the program's) | 066, 249 |
| `.tls = true` (`-Dtls`) | tls.zig; without it there is no `tls` module and the Engine's every use is under `@import("nilo_build").tls`. With `.http2` as well, a TLS listener offers `h2` and `http/1.1` by ALPN and serves what was chosen | 212, 259 |
| `.http2 = true` (`-Dhttp2`) | nothing: HTTP/2 and gRPC are `http/h2.zig`, `hpack.zig`, `h2conn.zig` (the connection) and `grpc.zig` (the envelope). A call reaches the App as its fields and its message through `serve.serveRequest` (`Arrival.call`), held to every rule an HTTP/1.1 head is (RFC 9113 §8 for any method), so a gRPC method is an ordinary route and any other request is served as HTTP, on a plain listener by its first bytes and on a TLS one by ALPN. A WebSocket stays HTTP/1.1 | 220, 259 |
| `.libdeflate = true` (`-Dlibdeflate`) | libdeflate's compressor, from its release tarball, compiled `ReleaseFast` and `FREESTANDING` by `libdeflateFor` in `build.zig`, never with `lib/utils.c` (whose weak `memcpy` would win the link for the whole program). `compress.backend` picks it for the pool and for static gzip | 248 |

It is the flag, not `.lazy = true`, that keeps a dependency out: `b.lazyDependency` is a request, and called unconditionally it ran for every dependent. This repository's own http test root is built with TLS and gRPC whatever the flags say, and links libdeflate so `compress.zig`'s tests hold both pools; its App keeps the default backend, so `zig build test -Dlibdeflate` is the run of the App through libdeflate. `zig build fetch-check -Dnetwork` builds `bench/dependent/` against two cold caches and fails on anything but zio landing; it needs the internet, so it is not on `test`. `zig build tzdata-check -Dnetwork` fails when IANA has published a time zone release newer than the one `nilo_job` carries (`job.tzdata_version`); also off `test`, and `-Dtzdata=<dir>` builds against the output of `job/tzdata/refresh.py --out <dir>` (ADR 161).

## Commands

```
zig build test         # the loop: the suite in Debug, the refusals, every module's gate but
                       #   test-sql, plus layering, adr-check, docs-check and snippets
zig build test-all     # the above, the suite in ReleaseSafe, test-sql and refusals-sql.
                       #   What CI runs, and the whole gate
zig build test-http -fincremental --watch   # the framework's suite alone, rebuilt in under a
                       #   second on a save; the loop while working under http/ (ADR 138)
zig build test-{core,id,config,pw,cache,jwt,proto,fetch,job,s3,dev}   # one module, both modes,
                       #   plus its refusals where it has a table
zig build test-fetch-engine  # an outbound deadline firing against a real port; on `test`
zig build test-sql     # nilo_sql, with test-job-sql and refusals-sql; Postgres if DATABASE_URL reaches one,
                       #   and a failure without one where $CI is set (-Ddatabase-required=false)
zig build layering     # no module imports upward or sideways
zig build park-check   # a plain idle connection holds one page of stack (two on -Dtls), never a second or third; on test.
                       #   Linux x86-64 host and target only: anywhere else the step is named "skipped" and succeeds (ADR 062)
zig build two-modes    # configure a dependent asking for nilo in Debug and ReleaseSafe; on test
zig build adr-check    # ADR files, their Topic lines, and every ADR cited exists; on test
zig build docs-check   # every doc page's head, prose, links and anchors, the map, the reference's heading list,
                       #   the roadmap's lists of todo entries, and the todo list ranked at this version; on test
zig build docs-index   # rewrite the reference's list of every heading, and the roadmap's lists of todo entries
zig build refusals     # the framework's table only; refusals-{sql,config,pw,cache,s3,job,fetch,proto} for the others
zig build snippets     # the documentation's marked snippets, which must compile
zig build examples     # build every example; run-{hello,rest,orders,forms,spa,embedded,stream,chat,scheduled,outbound,sqlite}
zig build dev-{hello,…}  # an example restarted on a save to its Zig, and on nothing else (ADR 190)
zig build fuzz -- --iterations 1000000 --seed 0x…   # generated requests at the parser; --frames for gRPC, --forms for multipart
zig build fuzz-llhttp -Dllhttp -- --iterations 1000000   # the same heads read by llhttp too; fetches it, exits 1 on an undecided difference (ADR 231)
zig build smoke-tls -Dnetwork   # a real HTTPS endpoint; not on test
zig build tzdata-check -Dnetwork   # IANA has no newer time zone release than nilo_job carries; not on test
mkdocs serve           # the guide as the website; `mkdocs build` is CI's strict check (ADR 219)
```

Benchmarks and their scripts are in [`bench/README.md`](bench/README.md). `-Dstrip=true|false` overrides the per-artifact debug-info default.

**`test-all` is the whole gate.** It depends on every module step above plus `layering` and `snippets`; a change under `core/` moves every module while showing no lines under them in a diffstat, and the answer is that one command. `zig build test-all --summary all` prints the tree.

**On a host whose glibc was built by GCC 16, the native link of anything with libc fails** at `crt1.o:.sframe` with `unhandled relocation type R_X86_64_PC64`. Pass `-Dtarget=x86_64-linux-gnu` to every `zig build test*` and `examples` line, or `-Dllvm` for the examples.

**Read the exit code, not the word "failed".** A passing `test` prints several `failed command: …` lines and exits 0, because `zig build` prints one for every step that wrote to stderr. The exit code and a `Build Summary` reporting a failed step are what count.

**The refusals never cache**: the compiler keeps nothing from a failed compilation, so they are re-analysed every run and are the floor of a run that changed nothing (ADR 026). They are not the slow part of a run that changed something; that is the largest single compilation ([`bench/result/build.md`](bench/result/build.md)).

**Take a stuck build's CPU time before believing it is slow.** `ps -o etime,cputime -C zig`: minutes of wall against seconds of CPU is a deadlock or something waiting on you (`--time-report` stands up a web server), and a documented slow path is the best hiding place for one. Suspect first the tests that open a real socket at both ends (`test-fetch`, `test-s3`, `http/live.zig`). **A wait on a flag needs a bound, and the giving-up path needs to set something**; a listener a test connects to is started with `io.concurrent`, because `io.async` may run it on the calling thread (ADR 056). A genuinely slow build gets the same treatment: compare CPU against wall. The other readings (OOM, a piped log, a green run about an edited tree) are tabled in [`docs/history.md`](docs/history.md#a-suite-that-hangs-and-a-build-that-looks-stuck).

### Running one test

No `-Dtest-filter` is wired in, so build steps are all-or-nothing. What runs standalone:

```
zig test http/range.zig --test-filter "a suffix range"   # also cookie, patch, names, json
zig test core/core.zig                                   # and id/, config/, pw/, cache/, jwt/, proto/
zig test --dep nilo_core -Mroot=fetch/fetch.zig -Mnilo_core=core/core.zig
zig test --dep nilo_core --dep nilo_tzdata -Mroot=job/job.zig -Mnilo_core=core/core.zig -Mnilo_tzdata=job/tzdata/tzdata.zig
```

Everything else under `http/` needs the module graph, so `zig build test-http` (the suite alone) or `zig build test` is the way. **Most of a `test` after an edit is not the refusals**: it is 33 s of single-threaded Sema compiling the `http/` suite and 25 s running it, mostly live tests waiting out the limits they test ([`bench/result/build.md`](bench/result/build.md#where-zig-build-test-waits-on-zig-017)). `-fincremental --watch` on `test-http` takes the first to under a second. **For the bottom two layers standalone is the entry condition, not a nicety**: if a change stops one of those lines working, the layering broke, not the test. That is why `fetch/deadline.zig`, which names `nilo_http`, is its own root (`test-fetch-engine`), and `job/live.zig`, which names `nilo_sql`, is `test-job-sql`. `nilo_s3` needs the module graph only because `s3/live.zig` names the generated `s3_config`.

## Invariants that are load-bearing

ADR 017 splits performance into four axes that do not recover the same way:

- **Allocations per request** (hard). Held by `test "the request path stays inside its allocation budget"` in `http/behaviour.zig`. A DX feature may not add one to a path that did not ask for it.
- **Memory per idle connection** (hard). 4,669 bytes for the framework and 5,183 for an idle WebSocket, and that is a **floor, not a total**: a suspended fiber holds its stack at its high-water mark, so a handler adds every byte of stack it ever touched for the life of the connection (ADR 062). **In this framework the arena is cheaper than the stack**, and **where a fiber is suspended is what it costs**: the framework's frames are kept under a page, and a `std.log` call inlined into a connection loop puts its format machinery there (ADR 062). Every feature that costs per-connection memory states the number in its own ADR. A plain listener holds one page in every build, `-Dtls` and `-Dhttp2` included (4,692 and 4,699 bytes, `park-check` pins it); a connection that did a TLS handshake parks deeper and holds two (8,843). The default build's park sits 288 bytes under the boundary, so a change to the connection loop is a page per idle connection away from being noticed, and `bench/mem.py` is what notices.
- **Throughput and p99**: DX wins below 10%.
- **Binary size**: a feature the linker cannot drop states its stripped `ReleaseFast` cost in the running total in ADR 017.

**Every change is put against all four before it is written**, the axis it spends and the number, in a design argued in a session as much as in a diff. **A feature that cannot be made to fit does not ship in a worse shape**: it waits for the shape that fits.

### A benchmark that was run gets written down

**Every release is measured against the one before it** on every module by `python3 bench/release.py`, which the **Release numbers** workflow runs on a published release and by hand before tagging: instructions and allocations an operation, bytes an idle connection, stripped binary bytes, never req/s (ADR 242). A module's new everyday operation belongs in `bench/release/`.

**Every run that changed a decision gets an entry in [`bench/result/`](bench/result/)**, one file an area (the list is in [`bench/README.md`](bench/README.md)), saying what was run, on which machine, at which commit, the numbers, the decision they moved, and whether the number can be pushed further. Not the terminal, not a commit body. A run that changed nothing still earns one if somebody would otherwise repeat it. The lesson then goes to `docs/history.md` and the decision to an ADR. **A number with no run behind it decays into a claim, and a premise decays the same way and costs more.**

The habits, each of which caught something here (the cases are under *Measuring* in [`docs/history.md`](docs/history.md#measuring)):

- **Build the before, do not quote it**: `git archive HEAD | tar -x` into a scratch directory, same flags, same afternoon. Then **interleave** runs; a margin inside the spread is "unchanged", and a margin narrower than its spread is quoted as a range.
- **Say what the number was measured through**: a Docker port, loopback and a unix socket differ by 133%, and a Debug build hides behind a flag given once.
- **Put something next to it**: a control route doing the same work minus the thing measured.
- **Measure a per-operation saving twice**, unloaded and at the pool, because a pool connection is a serial queue.
- **Take a per-connection figure out until marginal meets average**, on both sides of a comparison.
- **Pin both sides to physical cores**, or the number is about the scheduler.

**A conclusion of "blocked on somebody else" gets one more hour than it feels like it needs, and one blocked on "a design" gets two.** Nothing downstream ever re-tests a blocker, and a requirement written as one mechanism reads as a blocker where written as what it has to catch it reads as a choice (ADR 062, last section).

## Conventions

**Error messages are a feature, and a build step holds them.** Each file in `refusals/` (and `<module>/refusals/`) is a program written wrong on purpose that must fail with a message nilo wrote. Adding a comptime check means adding **both** a file and a row in the matching table in `build.zig`. **There are nine tables and nine steps**, one per module, and adding a row to one while running another is a check that silently never ran. Leave the `nilo: ` prefix off `.says`; the step supplies it, so a failure inside std cannot be recorded as passing. `.says` is matched with `endsWith`, so it is the whole tail of the message's first line. See `refusals/README.md` and ADR 026.

**A published snippet is a program, and a build step compiles it.** `<!-- compiles -->` above a fenced `zig` block in the README, the reference or a guide page makes `zig build snippets` compile it after `docs/snippets/types.zig`; `<!-- compiles: body -->` wraps loose statements in a function with `values.zig`. The block in the page is the only copy. These cache, so marking one is nearly free (ADR 068).

**Tests sit at the bottom of the file they test**, named as sentences about the behaviour: `test "a path param that is not a number becomes a 400 with a clear message"`. A new file under `http/` gets an `_ = @import(...)` line in the `test { … }` block at the end of `http/http.zig`, or it never runs. The examples carry tests and run in the same suite.

**Both optimize modes matter.** Debug is the loop and ReleaseSafe is the gate, because a lifetime bug passes in Debug, where a dangling pointer's bytes happen to still be there, and segfaults in the mode people deploy in. `Str`'s lifetime trap is Debug-only by design. **A `Str` never escapes its request** without `.keep()`, inside the framework as much as outside.

**`std.log.err` means the server is refusing to start.** Zig's test runner fails a run on any `err` line, so everything on the request path logs at `warn`, and a branch a test must reach returns a value rather than only logging.

**Doc comments say why, and name the ADR.** Every module's header is its design rationale, including the alternatives measured and dropped.

**Commits are conventional-commit prefixes with a short body.** The subject is `type: imperative sentence about the effect` (`feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build`, `chore`, `!` for a break), and says what changed, not which files: `fix: stop the router reading routes that cannot match`. The body is optional, a few sentences explaining why or naming a number; the long account belongs in the files below, and a body that repeats them is a fourth copy. Commits before `b662f01` follow an older convention.

**A revision never makes a new ADR.** Changing, narrowing, widening, correcting or reversing a decision edits its ADR in place: the Decision says the rule as it holds now, and the position it replaced moves under "What was rejected" with the evidence that moved it. A new number is only for a decision that did not exist before; if it changes part of an older one, edit the older one in the same change so each says the rule in force, and name it with `**Extends:**`. `zig build adr-check` refuses `Amends`, `Supersedes`, `Refines` or any head word outside `Applies`, `Extends`, `Carries out`, `Closes` and `Found by` (ADR 221). Before writing an ADR, look for the one it would revise: its topic page in `docs/design/` lists every ADR on that topic.

**Documentation is part of the change**, not a follow-up:

| what | where |
|---|---|
| a design decision and the alternative it rejected | a new file in `docs/adr/`, or an edit to the ADR it changes |
| how a topic's decisions fit together | its page in `docs/design/`, linked from each ADR's `**Topic:**` line |
| a lesson: a number measured, a premise that turned out false, a design tried and lost | `docs/history.md`, as one paragraph under the theme it teaches (its header has the rules) |
| what a user has to change | `CHANGELOG.md`, under `## Unreleased` |
| a direction the framework is heading, larger than one change | `docs/roadmap.md` (its rules are under [How this file is written](docs/roadmap.md#how-this-file-is-written)) |
| a concrete item still open: a defect, a decision, a question, a measurement, an upstream fix | `docs/todo.md`, in the tier P0 to P3 its cost puts it, or nowhere if it is small and not needed now (its own rules are under [How this file is written](docs/todo.md#how-this-file-is-written)) |
| a question answered, a gap kept as the rule, a feature refused with its reason | `docs/decided.md` |
| a risk with no mechanism under it yet | `docs/risks.md`, under `## Open` |
| a benchmark run | `bench/result/` |
| a new guide page | `docs/guide/`, with the five-line head and a row in `docs/README.md` (`docs-check` refuses either missing), plus a line in `nav:` in `mkdocs.yml` or CI's `docs` job fails |
| a new reference or design page, or a renamed heading on one | the five-line head, a link in `docs/README.md`, and `zig build docs-index` for the reference's heading list |

**The roadmap and the todo list hold nothing built and nothing decided.** The roadmap is a few directions grouped by when (Now, Alongside, Next, Later); the todo list is every concrete item worth doing, ranked P0 to P3 by what it costs users or the project and never by who has asked; a small thing not needed now is not added, and a defect is never left off. A todo entry that serves a direction says so on a `**Direction:**` line, `zig build docs-index` writes each direction's list from those lines, and `docs-check` refuses a stale one. A release bumps `build.zig.zon`, and `docs-check` then refuses the todo list until its `Ranked at` line is brought up to it by ranking it again. When something ships its entry leaves entirely, no strikethrough; what was learned moves to `docs/history.md`. Every entry opens with its whole claim in bold and closes with a `Needs:` or `What would settle it:` line, which is what makes a blocker that has quietly stopped being one findable. **`docs/history.md` stays short**: a lesson, not an account of what shipped, and a lesson learned again extends its entry rather than adding one.

Cutting a release (the version bumps, the pinned `?ref=#commit`, the release page) is [`docs/releasing.md`](docs/releasing.md).

## Refused on the record

Templates are a decision, not a gap (README "What it won't do"); propose a change to the ADR instead of adding them. HTTP/2 moved: it is behind `-Dhttp2`, never in the default build, and in that build every listener answers it beside HTTP/1.1, a plain one by the client's first bytes and a TLS one by ALPN (ADR 259, ADR 027, ADR 220); a WebSocket stays HTTP/1.1 (ADR 260), gRPC is unary only, and streaming is on the roadmap. TLS is the precedent for moving one: an option behind a build flag, the default build unchanged on the memory axis and 2.8 KB on the size one, and every number on the record before it shipped (ADR 212).

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
