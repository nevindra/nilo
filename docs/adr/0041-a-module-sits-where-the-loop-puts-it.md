# A module sits where the loop puts it, and imports only downward

[ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md) put SQL in
a directory of its own, and
[ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
gave it a moment to finish itself in. Both were written about one module, and
one module is not a structure.

`sql/db.zig`, `sql/live.zig` and `sql/row.zig` each `@import("nilo")` — the
server, as it was called then — for `Str`, and for the two calls ADR 0040 added
to `Ctx`. With two modules that is the line already in `build.zig`: *the
dependency runs one way — `sql` on `nilo`, never back*. With eight it is a
different sentence, and a false one: **the HTTP server becomes the core of a
repository that is no longer only a server.**

Three things break, in the order they hurt.

**Nothing new can be tested on its own.** `CLAUDE.md` already lists the modules
that run under a plain `zig test`: `str`, `cookie`, `percent`, `patch`, `names`,
`json`, `range`. Everything else reaches the Bulkhead and needs the module
graph, so `zig build test` is the only way to run it — and that is the run whose
refusals never cache, because the compiler keeps nothing from a compilation that
failed. A module that generates identifiers would inherit that loop for no
reason at all. This is the one that decides whether two people can work on two
modules at once.

**The build graph states something untrue.** A module that does no IO would
depend on an event loop, and `zig fetch` would go and get one.

**The place where two modules collide belongs to neither of them.**
`build.zig` holds both refusal tables and `http/http.zig` holds the test block.
Every new module edits the same two files.

## What was decided

**Three layers, and the thing that decides which is the loop.**

| Layer | Module | The loop | Where | Runs under plain `zig test` |
|---|---|---|---|---|
| **Core** | `nilo_core` | needs none | `core/` | **yes**, and that is the point of it |
| **App** | `nilo_http` | owns it | `http/` | no |
| **Service** | `nilo_sql` | needs it, does not own it | `sql/`, and its siblings | its pure half does |

**A module imports downward only.** Core imports nothing of nilo's. An App
imports Core. A Service imports Core. **A Service never imports an App**, and
nothing imports a sibling in its own layer. That rule is the whole of what makes
a module a separate piece of work: two Services touch no file in common.

**One directory per module, named after the module, and no module is called
`nilo`.** The server moved out of `src/` and into `http/` and its module was
renamed from `nilo` to `nilo_http`, which is the part of this decision that
looks like tidying and is not.

`src/` means *the source*, which is the right name for a repository holding one
library and the wrong one for a repository holding several — a reader would have
had to learn that `src/` meant HTTP while every sibling said what it was on the
directory. Worse, a module called `nilo` made the word mean two things at once:
the project, which is what the `nilo: ` prefix on every Refusal says and what
`nilo_table`, `nilo_resolve` and `nilo_start` are named after, and one module
among several. `CONTEXT.md` exists to stop exactly that, and it cannot ask a
reader to keep a word steady that the build system spends twice.

So the bare name belongs to the project and to nothing else. **`@import("nilo")`
resolves to nothing at all, and there is no umbrella module to bring it back** —
one re-exporting the others would cost every project the bytes of every module,
which is the property [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
bought and this ADR is extending rather than spending. What a reader writes is
`const nilo = @import("nilo_http");`, and the alias costs them nothing.

The moment matters more than the argument. `docs/history.md` recorded the lesson
from the last rename — *the name is cheap for us and not for them, which is the
argument for settling it before there are users rather than after* — and there
are none yet. This rename is also cheaper than that one in the way that decides
it: the markers sit in a reader's own structs and **none of them move**, because
they are named after the project, which is precisely what is being kept steady.

**Core is the vocabulary, not a drawer to put spare things in.** `Str` and the
`Lifetime` behind it, and the Scope below. A file earns its way in by being
needed by two layers, not by having nowhere else to live — the moment Core is
where things go when they do not fit, the layering has stopped meaning anything
and only the directory is left.

**Core declares a Scope, and `Ctx` is one.** ADR 0040 gave `Ctx` `arena()` and
`str()` for exactly this reason: *a module beside the framework needed a
supported way to allocate for a request and to stamp bytes with its lifetime.*
Naming that pair is all it takes for a Service to stop needing `Ctx`:

```zig
const rows = try db.select(User, scope, .{ .where = .{ .age = .{ .gt = 18 } } });
```

`scope` is anything carrying those two calls. It is checked while compiling and
there is no vtable, so it compiles to the calls `Ctx` receives today. A request
is the Scope everything has now; the tick of a scheduled task is a second, and a
whole CLI run is a third.

That is the line where this stops being tidying. A Service that names a Scope
rather than a `Ctx` runs with no server in the process at all.

**A layer is declared by the module and held by the build.** Each module's
directory carries its own build wiring and its own refusals table, and the build
fails if a Core file imports upward. [ADR
0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md) is the
precedent and the reason: a rule about the shape of this repository that only
`CLAUDE.md` states is a rule that erodes on the first afternoon somebody is in a
hurry.

## Why not the alternatives

**Leave it — `sql` importing `nilo` costs nothing at run time.** Quite true, and
it is why this was the right thing to leave alone for two modules. Zig does not
analyse what nothing reaches, so a Service that only names `Str` links no
router and no accept loop. The cost is not bytes; it is the development loop and
the build graph, and unlike a byte count both get worse once per module rather
than once.

**Put Core inside the server's own directory as a second module.** The reason
`sql/` lives outside it applies word for word
([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)): the
convention that a new file there gets an `_ = @import(…)` line in the module
root's test block would pull every Core file into the server's test root *by
being followed correctly*. A convention that punishes the people who keep it is
worse than no convention.

**Make Core a namespace — `nilo.core` — rather than a module.** A namespace is
not a boundary in the build graph. It cannot be tested on its own, it cannot be
imported without the rest, and nothing can be made to fail when somebody imports
upward through it. All three of the problems above survive it.

**A fourth layer, splitting Services that dial from Services that do not.**
Rejected because the split is real but it is *inside* a module rather than
between two. Signing a URL needs no socket and storing a file does; both are the
same module and the same ADR. A Service's pure half is Core-layer code that
happens to live in that Service's directory, and giving it a layer of its own
would mean cutting modules in half to satisfy a table.

**A vtable for Scope.** An interface with a pointer and a function table would
let a Service take a Scope it has never heard of. Rejected on the request path:
it puts an indirect call on every allocation a Service makes, which is the path
[ADR 0018](./0018-the-trade-budget-has-three-axes.md) guards hardest, to buy a
polymorphism nobody has asked for. The comptime check refuses an unsuitable type
with a sentence and generates the same code the direct call generates.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none.** Nothing moves onto the request path. A Scope is checked while compiling. |
| Memory per idle connection | **none.** Nothing here is per-connection. |
| Throughput and p99 | **none.** The Scope check compiles to the calls `Ctx` already receives. |
| Binary size | **none**, and measured rather than assumed. |

The last row is a real zero and not a rounded one. Measured stripped
`ReleaseFast`, against a build of the parent commit in a `git worktree` — the
method `docs/history.md` settled on after stashing gave two contradictory
readings half an hour apart:

| | Before | After |
|---|---|---|
| `example-hello` | 885,504 | 885,504 |
| `example-rest` | 1,031,744 | 1,031,744 |
| `nilo-hello` | 890,384 | 890,384 |

Byte for byte, all three. That is the answer the design predicted — moving a
declaration between modules does not change what is reachable from a root — but
ADR 0018's rule is that a feature states a *measured* number and the prediction
was written down before the measurement was taken, so that somebody could
notice if it had been wrong. `nilo-hello`'s 890,384 is also exactly the number
[ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
recorded, which is a second reading of the same zero from a different direction.

## What Core actually holds

Written out because the first draft of this decision got it wrong in the way
that matters: it listed the files that *could* move instead of the ones that
have earned the right to.

**Compiling alone is not the same property as belonging in Core.** `str.zig`
imports `std` and `builtin`; `names.zig`, `percent.zig`, `patch.zig`,
`range.zig` and `cookie.zig` import `std` alone; `json.zig` imports `str.zig`.
That is a fact about the *cost of moving them*, and it is exactly the list
`CLAUDE.md` already gives for `zig test`. It says nothing about whether they
belong. A Cookie is read by one layer and means nothing to any other; moving it
down because it happens to compile alone is precisely how Core becomes the
drawer this decision opened by refusing.

**So Core holds two files.** `Str`, which the App uses on every request and
`sql` uses on every row it reads — two layers, which is the rule. And the Scope,
which is new. Nothing else has a second caller today. `percent.zig` is the most
likely to earn its place next, because signing a URL needs the encoding half; it
moves when that caller exists and not before.

**`convert.zig` is the interesting refusal.** It imports `bulkhead.zig` and
`fail.zig`. Turning text into a type is precisely what a Core wants — it is what
a configuration module would reuse — but it reaches the Bulkhead to say a
request failed. Two ways out, and this ADR picks neither: its failures come back
as a value the caller turns into a 400, or `convert` stays in the App layer and
Core gets a smaller converter following the same rules. Naming it is the point;
deciding it wants the configuration module to exist first, so there is a second
caller to design against rather than a guess.

**`sql` changes what it names, not what it does.** `c: *nilo.Ctx` becomes a
Scope and `nilo.Str` becomes `core.Str`, in `db.zig`, `row.zig` and `live.zig`.
The calls underneath are unchanged: the module only ever asked a `Ctx` for
`arena()` and `str()`, which is why the Scope has exactly those two and not a
third.

## What the wiring settled that the design had not

**A Service's tests may reach up; its code may not — and Zig is what makes the
difference cost nothing.** `sql/db.zig` and `sql/live.zig` drive a whole request
through `nilo.testing.Client`. That is an App-level test at the bottom of a
Service file, which is the convention here and is worth keeping, and it looked
like it would force `nilo_sql` to declare `nilo` after all.

It does not. **An `@import` referenced only from a `test` block is never
analysed in a build that is not a test build.** So the published module declares
`nilo_core` alone, and the test module — which `build.zig` already creates
separately, for the optimize modes — declares `nilo` as well. Checked rather
than assumed: `zig build-obj` on a file importing a module that does not exist
passes when only a test names it, and `zig test` on that same file fails
pointing at the test.

The rule that follows is worth stating on its own, because it is not what the
layer table would suggest: **the layering binds a module's code, and a module's
tests may reach one layer up.** A Service proving itself against a real App is
the test most worth having, and nothing about it belongs in the App's own
directory.

**A list that does not name a directory cannot check it, and Core shipped for a
whole session inside that hole.** `build.zig` carries a comptime check that
every module root appears in `build.zig.zon`'s `.paths`, because a dependent
whose package is missing a directory finds out at *their* build rather than
ours. It is a good check and it said nothing, because the roots it compares
against are a list somebody has to extend — and `core/` was added to neither.
Nothing failed locally; `zig fetch` would have handed out a package with no
Core in it. The check now names all three, and the comment above it says out
loud that adding a module means adding a row, since that is the step the
mechanism cannot take for itself.

**Which directory a file belongs in has a sharper test than "is it part of the
framework".** Sorting `src/` turned up four files that were not library code at
all — the benchmark server, the profiler, the fuzzer and its driver — and the
question that separated them is what they import. `bench/main.zig` names the
module the way a stranger's project would, so it is a *consumer* and lives
outside; `profile.zig` and `fuzz_main.zig` reach into `app.zig`, `router.zig`
and `bulkhead.zig`, so they are the module's own tooling and stay in it. The
rule generalises: **a file that imports a module by name can live anywhere; a
file that reaches into a module's internals belongs to that module.**

## Consequences

- **The framing changes, and the README has to say so.** nilo stops being a web
  framework with a SQL module beside it and becomes a toolkit whose largest
  module is a server. A CLI that wants identifiers, times and a signed URL links
  no server, no router and no event loop — which is the same property ADR 0040
  claimed for HTTP-only projects, pointed the other way.
- `CONTEXT.md` gains **Core**, **Layer** and **Scope**. The `Tx` entry lists
  "scope" among the words to avoid, and that stays true of `Tx` — an avoid-list
  is per term, and the reason a transaction must not be called a scope is that
  it ends three ways rather than one. The entry says so rather than being
  quietly dropped.
- `build.zig` stops being where two modules collide. The second refusals table
  (`sql_refusals`) already proved the shape; what is new is that it moves next
  to the module it belongs to. `http/http.zig`'s test block stops being every
  module's business for the same reason.
- The rule needs a build step of its own, or it is a paragraph. An import scan
  over `core/` is a small step and it is what makes the layering true a year
  from now.
- **This does not give a Service a way to dial out.** `sql` reaches the network
  through pg.zig, which brings its own zio; a Service written in this repository
  has nowhere to get an outbound socket except by naming zio, which
  [ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md) permits in exactly
  one file. The Bulkhead covers the way in and nothing covers the way out. The
  second Service module is where that bill arrives, and it is its own decision.
- Two modules is the last moment this is cheap. The work is three imports and a
  directory today; it is eight modules and their tests later.
