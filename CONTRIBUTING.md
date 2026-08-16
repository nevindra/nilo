# Contributing to nilo

This is one person's toolkit so far, and it's built to stop being one.

The most useful thing you can bring is not always a patch. A question that turns
out to have no written answer is a real find, because the whole design of this
repository rests on the answers being written down somewhere other than my head.
So "why on earth is it like this?" is a welcome issue, not a rude one.

## Get it running

```
git clone https://github.com/nevindra/nilo
cd nilo
zig build test
```

You need Zig 0.16 and nothing else. No C library, no system package, no
database. `zig build test` takes about a second.

Then read these four, in this order. They're the whole background you need:

| | |
|---|---|
| [`README.md`](./README.md) | what this is and what it refuses to be |
| [`CONTEXT.md`](./CONTEXT.md) | the vocabulary, and the words this project won't use |
| [`CLAUDE.md`](./CLAUDE.md) | the working brief: layout, commands, invariants, conventions |
| [`docs/adr/`](./docs/adr/) | 48 decisions, each one naming the alternative it beat |

The ADRs are the important one. Before you propose a design change, check
whether it already has a file. "Why not X?" usually has an answer on record, and
if you disagree with it, you get to argue with something specific instead of
with a vibe.

## The commands

```
zig build test         # the loop: the suite in Debug, plus the refusals
zig build test-all     # the above plus the same suite in ReleaseSafe. This is what CI runs
zig build layering     # check that no module imports upward or sideways
zig build refusals     # the framework's 56 compile-error checks — NOT the others
zig build refusals-sql # nilo_sql's 41; refusals-config and refusals-pw for the rest
zig build examples     # build all seven examples

zig build test-core    # only nilo_core, both modes. No engine, no module graph
zig build test-id      # only nilo_id, the same way
zig build test-config  # only nilo_config, the same way, plus its refusals
zig build test-pw      # only nilo_pw, the same way, plus its refusals

zig build run          # the benchmark server
zig build profile      # where the time inside one request goes
zig build run-hello    # or rest, orders, forms, spa, stream, chat
zig build fuzz -- --iterations 1000000 --seed 0x…
```

Two things worth knowing before they surprise you:

**The refusals never cache.** The compiler keeps nothing from a compilation that
failed, so all 91 of them get re-analysed on every run. That's why they're the
slow part of `zig build test`, and they stay there on purpose.

**The bottom four modules run without the build system.** `zig test core/core.zig`,
`zig test id/id.zig`, `zig test config/config.zig` and `zig test pw/pw.zig` all
work on their own, filters and all. That's not a nicety, it's the entry
condition for that layer. If a change ever stops one of those commands working,
the layering broke, not the test.

Everything under `http/` reaches the engine and needs the module graph, so
`zig build test` is the only way to run it. A few files are pure enough to run
standalone with a filter:

```
zig test http/range.zig --test-filter "a suffix range"
```

That works for `cookie`, `percent`, `patch`, `names`, `json` and `range`.

## What a change has to carry

Four things. They're the same four whether a person or a model wrote the code.

### 1. Which axis it spends, and the number

Performance here isn't one number, it's four, and they don't recover the same
way ([ADR 0018](./docs/adr/0018-the-trade-budget-has-three-axes.md)):

| | |
|---|---|
| Throughput and p99 | a nicer API wins if it costs under 10% |
| Allocations per request | fixed. Currently 1, held by a test |
| Memory per idle connection | fixed at 8,767 bytes. Every feature states its own cost |
| Binary size | anything the linker can't drop states its measured cost, as a stripped `ReleaseFast` number |

Say which one your change spends, and by how much, when you *propose* it. Not
after it lands, and not because a reviewer asked. If it costs an allocation on a
path that didn't ask for one, it doesn't go in, and the honest move is to say so
early rather than build it first.

A feature that can't be made to fit doesn't ship in a worse shape. Response
compression is the standing example: the shape that would fit is known, it
hasn't been built, and no allocate-per-request version got shipped in the
meantime.

### 2. Its refusals

If your change adds a compile-time check, the error message it prints is part of
the feature, and it needs a program that proves the message still says the right
thing.

That means a file in `refusals/` (or `sql/refusals/`, `config/refusals/`,
`pw/refusals/`) and a row in the matching table in `build.zig`.
[`refusals/README.md`](./refusals/README.md) shows exactly how, including the
trick for finding out what to put in `.says`: guess, run the **matching** step —
`refusals`, `refusals-sql`, `refusals-config` or `refusals-pw`, because each one
runs only its own table and a row added to one while another is running is a
check that silently never ran —
and read what it prints.

Leave the `nilo: ` prefix off the `.says` text. The build step adds it, which is
what makes it impossible to record a failure from inside the standard library as
a passing test.

### 3. Its tests

Tests go at the bottom of the file they test, and they're named as sentences
about the behaviour rather than after the function:

```zig
test "a path param that is not a number becomes a 400 with a clear message" {
```

A new source file under `http/` needs an `_ = @import(...)` line in the
`test { … }` block at the end of `http/http.zig`, or it never runs at all.

Both optimize modes matter, so run `zig build test-all` before you open a pull
request. Debug is the fast loop. ReleaseSafe is the gate, because a lifetime bug
passes in Debug, where the bytes a dangling pointer points at happen to still be
sitting there, and then segfaults in the mode people actually deploy in.

### 4. Its documentation

Documentation is part of the change, not a follow-up:

| What you have | Where it goes |
|---|---|
| a design decision | a new file in [`docs/adr/`](./docs/adr/) |
| something you measured, or a guess that turned out wrong | [`docs/history.md`](./docs/history.md) |
| something now built | delete its entry from [`docs/roadmap.md`](./docs/roadmap.md) |
| something a user has to change | [`CHANGELOG.md`](./CHANGELOG.md) |

The roadmap holds nothing that's finished. When something ships, its entry
leaves entirely. No strikethrough, no "done", no summary of how it went. The
test is that you can read the roadmap top to bottom as work outstanding.

`docs/history.md` earns its length the hard way. An entry gets in only if it
would change what somebody does next time: a number that got measured, an
assumption that turned out false, a design that was tried and lost. Not what
shipped, which is the changelog's job.

## Writing the code

**Use the project's words.** [`CONTEXT.md`](./CONTEXT.md) is the vocabulary, and
it lists the words each term refuses. Ctx, not "Context". Str, not "string".
keep, not "dupe". Refusal, not "negative test". Matching it in code, comments and
commit messages is most of what makes a patch look like it belongs here.

**Doc comments say why, and name the ADR.** The header comment on every module
is its design rationale, including the alternatives that got measured and
dropped. Several of them exist because a number was measured wrong once and
corrected in place. Keep that habit.

**A `Str` never escapes its request without `.keep()`.** That applies inside the
framework exactly as much as it does in user code.

**A module imports downward only, and never sideways.** `zig build layering`
enforces it. Which module a file belongs in comes down to one question: does it
need the event loop?
([ADR 0041](./docs/adr/0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./docs/adr/0042-the-bottom-layer-holds-more-than-one-module.md))

## Adding a whole module

Rarer, and it's a design decision before it's a patch, so it starts with an ADR.

Mechanically it's three edits: a row in the `layers` table in `build.zig` saying
what the module may import, an entry in `shipped_roots`, and a line in `.paths`
in `build.zig.zon`.

The bar is the same one the README states. A part gets in if you can express it
as a type the caller already wrote, checked while compiling, with its cost
written down. It also has to bring its own refusals. Being useful isn't the
qualification.

And if it sits in the bottom layer, it has to run under a plain `zig test` with
no module graph. A bottom-layer module whose tests need the build system is in
the wrong layer.

## Proposing a design change

Open an issue first. Design changes are cheap to argue about and expensive to
build.

If it lands, it gets an ADR, and an ADR here has a specific shape: it names the
decision, and it names the alternative that lost and why. A document that only
describes what was built is a description, not a decision. Read a few of the
existing ones before writing your first.

[ADR 0043](./docs/adr/0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
is a good one to start with. It's the first time an earlier rule got tested
under real pressure, and it shows what happens when the rule wins and the
convenient thing loses.

## Commits and pull requests

Conventional commit prefixes, and a short body:

```
feat: read settings into a struct of your own
fix: stop the router reading routes that cannot match
```

Use `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `build` or `chore`, with
a `!` for a breaking change. Say what changed, not which files. "fix: router.zig"
tells a reader nothing.

The body is optional, and it earns its place by explaining *why* or by naming a
number. A few sentences, not three paragraphs. The long version belongs in the
places built for it: history for what got measured, an ADR for the decision, the
changelog for what a user has to change. A commit body that repeats all three is
a fourth copy to keep in sync.

Before you open a pull request, run `zig build test-all`, `zig build layering`
and `zig build examples`. That's what CI runs, plus a million generated requests
at the parser.

## Where to start

**Something in the roadmap marked "Not decided".** Those want an argument more
than they want a patch, and an argument is a cheap thing to contribute. You can
write one in an issue in ten minutes.

**The seam nothing has yet: dialing out.** This is the biggest thing on the
list. Object storage, mail, a Redis client and an HTTP client are four separate
modules blocked on one missing piece, because nothing here has a supported way
to open an outbound connection. The bulkhead covers the way in only. It should
be designed once against two callers rather than fitted around whichever one
turns up first, which is exactly the kind of work that goes better with more
than one person thinking about it.

**The small end, which is real work here.** A refusal whose wording could be
clearer. A guide page that assumes something it shouldn't. An example covering
the case you hit and nobody wrote down. Wording is a feature in this repository,
so improving a sentence is a change, not a chore.

## Working with an agent

Encouraged, and the repository is arranged for it. A model needs the same three
things a person in a hurry needs: a small surface, no ordering to infer, and a
build that says what's wrong.

Hand it [`CLAUDE.md`](./CLAUDE.md) for the working brief,
[`CONTEXT.md`](./CONTEXT.md) for the vocabulary,
[`docs/reference.md`](./docs/reference.md) for the whole API on one page, and
[`docs/adr/`](./docs/adr/) for why any of it is like that.

Then let the build do the first round of reviewing. `zig build test-all` catches
a broken behaviour and `zig build layering` catches a broken design, which are
the two things a human reviewer would otherwise have to catch by reading.

One ask: read the diff before you send it. An agent will happily write a
paragraph into `docs/history.md` that repeats the changelog, or restate an ADR
in a commit body. Those are the two failure modes worth watching for, and
they're easier for you to catch than for me.

## What gets turned down

Templates, TLS, HTTP/2 and gRPC. These aren't gaps waiting for a volunteer, they
are decisions with reasoning on file. If you want one of them, the move is to
argue against the ADR, not to open a pull request adding it.

Anything that needs an annotation to work. Anything that can't say what it
costs. Anything that adds an allocation to a request path that didn't ask for
one.

None of that is meant to sound closed. It's meant to save you from writing a
thousand lines that were never going to land.

## License

MIT. By contributing, you agree your work ships under it.
