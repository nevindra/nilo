# Contributing to nilo

This is one person's toolkit so far, and it's built to stop being one. The most useful thing you can bring is not always a patch: a question that turns out to have no written answer is a real find, because the whole design rests on the answers being written down somewhere other than my head. "Why on earth is it like this?" is a welcome issue.

## Get it running

```
git clone https://github.com/nevindra/nilo
cd nilo
zig build test
```

Zig 0.17 and nothing else: no C library, no system package, no database. The first run after a clone builds everything; after that a run that changed nothing is a few seconds, almost all of it the refusals below.

Then read these four, in this order:

| | |
|---|---|
| [`README.md`](./README.md) | what this is and what it refuses to be |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project won't use |
| [`CLAUDE.md`](./CLAUDE.md) | the working brief: layout, the commands, invariants, conventions |
| [`docs/adr/`](./docs/adr/) | the decisions, each one naming the alternative it beat |
| [`docs/design/`](./docs/design/) | one page a topic: how its decisions fit, and which ADR decided each rule. Written one topic at a time |

The ADRs are the important one. Before you propose a design change, check whether it already has a file: "why not X?" usually has an answer on record, and if you disagree with it you get to argue with something specific instead of with a vibe.

## The commands

```
zig build test          # the loop: the suite in Debug, the refusals, every module gate, layering, snippets, adr-check, docs-check
zig build test-all      # the same plus ReleaseSafe and the SQL suite. What CI runs, and the whole gate
zig build test-http -fincremental --watch   # the framework's suite alone, rebuilt in under a second on a save
zig build refusals-sql  # one module's refusal table; refusals, -config, -pw, -cache, -proto, -s3, -job, -fetch for the others
zig build examples      # build every example
zig build fuzz -- --iterations 1000000 --seed 0x…   # --frames for gRPC, --forms for multipart
zig build fuzz-llhttp -Dllhttp   # a parser change runs this too (ADR 231)
```

The rest of the build steps are in [`CLAUDE.md`](./CLAUDE.md#commands), and the benchmarks in [`bench/README.md`](./bench/README.md). Three things worth knowing before they surprise you:

**The refusals never cache.** The compiler keeps nothing from a compilation that failed, so every one of them is re-analysed on every run. They are the floor of a run rather than its slow part: a run after an edit is longer by whichever single compilation is biggest, because that one cannot be split across cores. [`bench/result/build.md`](./bench/result/build.md) has the numbers and the levers.

**The bottom layer runs without the build system.** `zig test core/core.zig`, and the same for `id/`, `config/`, `pw/`, `cache/`, `jwt/` and `proto/`, work on their own, filters and all. That is the entry condition for the layer, not a nicety: if a change stops one of them working, the layering broke, not the test. A Fitting is one step short because it borrows the loop ([ADR 061](./docs/adr/061-a-fitting-borrows-the-loop.md)), and needs `nilo_core` in the graph and nothing else:

```
zig test --dep nilo_core -Mroot=fetch/fetch.zig -Mnilo_core=core/core.zig
zig test --dep nilo_core -Mroot=job/job.zig -Mnilo_core=core/core.zig
```

**Everything under `http/` needs the module graph**, so `zig build test` is the only way to run it. `cookie`, `patch`, `names`, `json` and `range` are pure enough for `zig test http/range.zig --test-filter "a suffix range"`.

## What a change has to carry

Four things, the same four whether a person or a model wrote the code. The [pull request template](./.github/PULL_REQUEST_TEMPLATE.md) asks for them in this shape.

### 1. Which axis it spends, and the number

Performance here is four numbers, not one, and they don't recover the same way ([ADR 017](./docs/adr/017-the-trade-budget-has-four-axes.md)):

| | |
|---|---|
| Throughput and p99 | a nicer API wins if it costs under 10% |
| Allocations per request | fixed, held by a test in `http/behaviour.zig` |
| Memory per idle connection | 4,669 bytes is the **floor**, and a handler adds every byte of stack it touches ([ADR 062](./docs/adr/062-where-a-connection-waits-is-what-it-costs.md)). Every feature states its own cost |
| Binary size | anything the linker can't drop states its measured cost, as a stripped `ReleaseFast` number |

Say which one your change spends, and by how much, when you *propose* it, not after it lands. If it costs an allocation on a path that didn't ask for one, it doesn't go in, and the honest move is to say so early. A feature that can't be made to fit doesn't ship in a worse shape: response compression is the standing example: its shape was known long before it shipped, no allocate-per-request version went in meanwhile, and it landed once a compressor borrowed from a pool made it fit ([ADR 211](./docs/adr/211-a-response-is-compressed-on-a-compressor-borrowed-from-a-pool.md)).

### 2. Its refusals

A compile-time check's error message is part of the feature, and it needs a program that proves the message still says the right thing: a file in the module's `refusals/` directory and a row in the matching table in `build.zig`. [`refusals/README.md`](./refusals/README.md) shows how, including how to find the `.says` text (guess, run the step, read what it prints).

There are eight tables and eight steps, one per module, and each step runs only its own table. A row added to one while running another is a check that silently never ran. Leave the `nilo: ` prefix off `.says`; the build step adds it, which is what makes a failure inside the standard library impossible to record as passing.

### 3. Its tests

Tests sit at the bottom of the file they test, named as sentences about the behaviour rather than after the function:

```zig
test "a path param that is not a number becomes a 400 with a clear message" {
```

A new source file under `http/` needs an `_ = @import(...)` line in the `test { … }` block at the end of `http/http.zig`, or it never runs.

Run `zig build test-all` before you open a pull request. Debug is the loop; ReleaseSafe is the gate, because a lifetime bug passes in Debug, where the bytes a dangling pointer points at happen to still be there, and segfaults in the mode people deploy in.

### 4. Its documentation

Documentation is part of the change, not a follow-up:

| What you have | Where it goes |
|---|---|
| a design decision | a new file in [`docs/adr/`](./docs/adr/), naming the alternative it rejected; a change to one edits that ADR in place ([ADR 221](./docs/adr/221-an-adr-is-the-rule-in-force-and-a-topic-page-joins-them.md)) |
| something you measured, or a guess that turned out wrong | [`docs/history.md`](./docs/history.md) |
| a benchmark you ran | [`bench/result/`](./bench/result/), one file an area |
| a direction the framework should take, larger than one change | [`docs/roadmap.md`](./docs/roadmap.md) |
| something left open: a defect, a decision, a question, a measurement, a fix upstream | an entry in [`docs/todo.md`](./docs/todo.md), in the tier its cost puts it (or nowhere, if it is small and not needed now), with a `Direction:` line if it serves a direction of the roadmap |
| something now built | delete its entry from [`docs/todo.md`](./docs/todo.md), and from [`docs/roadmap.md`](./docs/roadmap.md) when it closes a direction |
| a question answered, or a feature refused with its reason | [`docs/decided.md`](./docs/decided.md), and out of the todo list |
| something a user has to change | [`CHANGELOG.md`](./CHANGELOG.md), under `## Unreleased` |
| a public API | [`docs/reference/`](./docs/reference/), one page a module; `zig build docs-index` rewrites the list of every heading on its `README.md` |
| how to use something | [`docs/guide/`](./docs/guide/), one page a task |
| how a topic's decisions fit together | its page in [`docs/design/`](./docs/design/), linked from each ADR's `**Topic:**` line |

**Every page of the guide, the reference and the design pages opens the same way, and a build step holds it.** Line 1 is the title, line 3 one bold sentence saying what the page is, and line 5 links the same topic in the other two layers (`**Reference:** … · **Design:** …`, or `none`). A heading names what its section covers in the words a reader would search for (a task in the guide, a symbol in the reference), and what it concludes is the section's bold first sentence. Prose is one paragraph a line with no em dash. A new page also gets a row or link in the map, [`docs/README.md`](./docs/README.md). `zig build docs-check`, on `test`, refuses a page that breaks any of this, and every anchor that points at nothing ([ADR 236](./docs/adr/236-a-doc-page-says-what-it-is-and-where-its-other-layers-are.md)).

**A snippet you publish is a program, so let the build compile it.** `<!-- compiles -->` above a fenced `zig` block (`<!-- compiles: body -->` for a run of statements) and `zig build snippets` compiles it with [`docs/snippets/types.zig`](./docs/snippets/types.zig) in front. Writing that step found seven mistakes in one five-line example ([ADR 068](./docs/adr/068-the-guide-is-the-source-of-its-own-snippets.md)). Unlike the refusals these cache, so marking one more is nearly free.

**The guide is also a website, published when a release is tagged.** `docs/guide/` and nothing else, one copy per minor release, built by Material for MkDocs ([ADR 219](./docs/adr/219-the-guide-is-published-once-a-release.md)). A new guide page needs a line in `nav:` in [`mkdocs.yml`](./mkdocs.yml), and CI fails on a page left out of it or on a link to a heading that no longer exists. `pip install -r docs/site/requirements.txt`, then `mkdocs serve` to see it.

**A benchmark that changed a decision gets written down where it can be re-run.** The entry says what was run, on what machine, at what commit, through what transport (the same server measured 197k requests a second across a Docker port and 458k over a unix socket), what the numbers were, and what they changed; and it closes with whether the number can be pushed further, ranked. Build the before rather than quoting it, interleave the runs, pin both sides of a comparison, and quote a margin narrower than its own spread as a range. This is a rule because the repository has already published wrong numbers three times, and all three were found by re-measuring ([ADR 062](./docs/adr/062-where-a-connection-waits-is-what-it-costs.md)).

**The roadmap and the todo list hold nothing finished and nothing decided.** When something ships its entry leaves entirely: no strikethrough, no "done". **`docs/history.md` stays short**: an entry gets in only if it would change what somebody does next time, not to record what shipped.

## Writing the code

- **Use the project's words.** [`CONTEXT.md`](./CONTEXT.md) lists each term and the words it refuses: Ctx not "Context", Str not "string", keep not "dupe", Refusal not "negative test". In code, comments and commit messages.
- **Doc comments say why, and name the ADR.** The header of every module is its design rationale, including the alternatives measured and dropped.
- **A `Str` never escapes its request without `.keep()`**, inside the framework as much as in user code.
- **A module imports downward only, and never sideways.** `zig build layering` enforces it. Which module a file belongs in is one question: does it need the event loop? ([ADR 038](./docs/adr/038-a-module-sits-where-the-loop-puts-it.md))

## Adding a whole module

A design decision before it's a patch, so it starts with an ADR. Mechanically it's three edits: a row in the `layers` table in `build.zig` saying what the module may import, an entry in `shipped_roots`, and a line in `.paths` in `build.zig.zon`. The bar is the README's: a part gets in if it is expressible as a type the caller already wrote, checked while compiling, with its cost written down, and it brings its own refusals. A bottom-layer module whose tests need the build system is in the wrong layer.

## Proposing a design change

Open an issue first; design changes are cheap to argue and expensive to build. If it lands it gets an ADR, and an ADR names the decision and the alternative that lost and why. A document that only describes what was built is a description, not a decision. [ADR 039](./docs/adr/039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md) is a good first read: an earlier rule tested under real pressure, where the rule won and the convenient thing lost.

## Commits and pull requests

Conventional prefixes and a short body:

```
feat: read settings into a struct of your own
fix: stop the router reading routes that cannot match
```

`feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build` or `chore`, with a `!` for a break. Say what changed, not which files. The body is optional and earns its place by explaining *why* or naming a number, in a few sentences; the long version belongs in history, an ADR or the changelog, and a body that repeats them is a fourth copy to keep in sync.

One decision per pull request. A branch carrying two is two pull requests, and the [template](./.github/PULL_REQUEST_TEMPLATE.md) asks for the four things above. Run `zig build test-all` and `zig build examples` first; that's what CI runs, plus a million generated requests at the parser.

## Where to start

- **A todo entry that ends with `What would settle it:`** ([the list](./docs/todo.md)). Those want an argument or a number more than a patch, and the line says which.
- **A module that dials out.** Mail and Redis are ordinary work now: the outbound seam is designed ([ADR 061](./docs/adr/061-a-fitting-borrows-the-loop.md)), `nilo_fetch` is the way out and `s3/` is a worked example on top of it.
- **The small end, which is real work here.** A refusal whose wording could be clearer, a guide page that assumes something it shouldn't, an example for the case you hit. Wording is a feature in this repository, so improving a sentence is a change, not a chore.

## Working with an agent

Encouraged, and the repository is arranged for it. Hand it [`CLAUDE.md`](./CLAUDE.md) for the brief, [`CONTEXT.md`](./CONTEXT.md) for the vocabulary, [`docs/reference/`](./docs/reference/) for the API and [`docs/adr/`](./docs/adr/) for why. Let the build do the first round of review: `zig build test-all` catches a broken behaviour and `zig build layering` catches a broken design.

One ask: read the diff before you send it. An agent will happily write a paragraph into `docs/history.md` that repeats the changelog, or restate an ADR in a commit body. Those are the two failure modes worth watching for.

## What gets turned down

Templates, TLS and gRPC in the default build, and HTTP/2 for ordinary routes. These aren't gaps waiting for a volunteer, they are decisions with reasoning on file; the move is to argue against the ADR, not to open a pull request adding one. (TLS behind `-Dtls` is the one that was argued and moved, and [ADR 212](./docs/adr/212-tls-is-an-option-a-build-asks-for.md) is what that took: the numbers on all four axes, and a default build that pays 2,760 bytes. gRPC behind `-Dhttp2` moved the same way, [ADR 220](./docs/adr/220-grpc-is-served-over-h2c-behind-a-flag.md).) Also anything that needs an annotation to work, anything that can't say what it costs, and anything that adds an allocation to a request path that didn't ask for one. None of that is meant to sound closed; it's meant to save you from writing a thousand lines that were never going to land.

## License

MIT. By contributing, you agree your work ships under it.
