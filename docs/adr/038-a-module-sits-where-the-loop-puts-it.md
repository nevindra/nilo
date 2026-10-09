# A module sits where the loop puts it, and imports only downward

**Status:** accepted
**Topic:** [layering](../design/layering.md)

## Context

`sql/db.zig`, `sql/live.zig` and `sql/row.zig` each named `nilo` (the server, as it was called then) for `Str` and for two calls on `Ctx`. With two modules that was one line in `build.zig`: the dependency runs one way, `sql` on `nilo`, never back. With eight it would have been a different sentence and a false one: the HTTP server becoming the core of a repository that is no longer only a server.

Three things would have broken. Nothing new could be tested on its own, because everything but a short list (`str`, `cookie`, `percent`, `patch`, `names`, `json`, `range`) reached the Bulkhead and needed the module graph, so `zig build test` was the only way to run it, and that run's refusals never cache. The build graph would state something untrue, a module doing no IO depending on an event loop. And the place where two modules collide would belong to neither: `build.zig` held both refusal tables and `http/http.zig` held the test block, so every new module edited the same two files.

Splitting the repository into modules answered that, but the split had only ever been tested against one module at the bottom: `nilo_core`. The second one, `nilo_id`, is where the design came due. It needs no event loop, so the layer table put it beside the vocabulary, which the "never a sibling" rule forbids it to import. And it wanted the type `nilo_sql` already had: `sql.Uuid` is sixteen bytes with a `writeText`, and generating a key is the same sixteen bytes. Two `Uuid`s in one build is the worst outcome available, because `db.insert` would refuse a generated key with a message about a type spelled exactly like the one it wants.

## Decision

### One question decides where a module sits: does it need the event loop

| Layer | Module(s) | The loop | Runs under plain `zig test` |
|---|---|---|---|
| Core | `nilo_core` | needs none | yes, and that is the point of it |
| Tool module | `id/`, `config/`, `pw/`, `cache/`, `jwt/`, `proto/` | needs none | yes, the entry condition for the layer |
| Fitting ([ADR 061](./061-a-fitting-borrows-the-loop.md)) | `fetch/`, `job/` | borrows it, owns no destination | needs `nilo_core`, no Engine |
| Service ([ADR 063](./063-an-object-store-is-a-service-that-dials.md)) | `sql/`, `s3/` | borrows it, holds a named system it dials | no |
| App | `http/` | owns it | no |

**A module imports downward only, and never a sibling.** Core imports nothing of nilo's. A tool module may import `nilo_core` and no other tool module. A Fitting or a Service may import `nilo_core` and any tool module, plus its own third-party drivers (a Wire, a Fitting a Service dials through). An App may import `nilo_core` and any tool module. A Service never imports an App. That rule is the whole of what makes a module a separate piece of work: two modules in the same layer touch no file in common.

### The bottom layer holds more than one module

**The vocabulary is not a sibling of anything, because a vocabulary is what a layer's other modules agree about, not a peer of one of them.** So the layer that needs no event loop holds `nilo_core` and, beside it and below everything else, as many tool modules as earn their place: `nilo_id` first, then `nilo_config`, `nilo_pw`, `nilo_cache`, `nilo_jwt`. A tool module may name `nilo_core`; it may not name another tool module, which is the half of the sibling rule doing the work here, since it is what keeps two of them separate pieces of work. `nilo_sql` names `nilo_id` in `sql/types.zig` and re-exports `Uuid`, which is downward, not sideways: a Service naming a tool module is exactly what the table above permits.

**Running under a plain `zig test` is the entry condition for this layer, not a property a module happens to have.** `zig test id/id.zig` is the whole of `nilo_id`, the same claim `nilo_core` made for itself and now a rule the layer holds every tenant to.

### Knowledge points down with the imports, even where a type does not

**A type sits in the lowest module that has a use for it; the opinion about it stays where the opinion is.** `Uuid` moved down to `nilo_id`, and `pub const nilo_column = "uuid"` did not move with it: that declaration is a database's opinion about a value, and a Core-layer type carrying it would be a module at the bottom knowing about a layer above it. Imports would still point downward while knowledge had quietly stopped. `sql/types.zig` answers for it instead, in one line of `declaredColumn`. **A marker on a type is an import you cannot see.** If a module below has to declare something only a module above understands, the type is in the wrong place, or the marker is.

### One directory per module, named after the module, and no module is called `nilo`

The server moved out of `src/` and into `http/`, and its module was renamed from `nilo` to `nilo_http`. `src/` means "the source," the right name for a repository holding one library and the wrong one for a repository holding several. Worse, a module called `nilo` made the word mean two things: the project, which is what the `nilo: ` prefix on every Refusal says and what `nilo_table`, `nilo_resolve` and `nilo_start` are named after, and one module among several. `CONTEXT.md` exists to stop exactly that, and it cannot ask a reader to keep a word steady that the build system spends twice. So the bare name belongs to the project and to nothing else: `@import("nilo")` resolves to nothing at all, and there is no umbrella module re-exporting the others to bring it back, which would cost every project the bytes of every module it does not use. What a reader writes is `const nilo = @import("nilo_http");`, and the alias costs them nothing. That rule held again for the second tool module: an umbrella `nilo` re-exporting `id` and its siblings would cost a project the bytes of both.

### Core is the vocabulary, not a drawer to put spare things in

Core holds `Str` and the `Lifetime` behind it, the Scope, the clock, and percent coding, each needed by at least two layers, which is the rule for a fifth: a file earns its place by being needed by two layers, not by having nowhere else to live. `Str` is what an App uses on every request and a Service uses on every row it reads. The Scope is what lets a Service stop needing a `Ctx`: `arena()` and `str()` named on any type carrying them, checked while compiling, no vtable, compiling to the calls `Ctx` already receives.

```zig
const rows = try db.select(User, scope, .{ .where = .{ .age = .{ .gt = 18 } } });
```

The clock and percent coding arrived later, each by passing the same test rather than by being here from the start. The clock is [ADR 041](./041-core-knows-what-time-it-is.md)'s: `nilo_id`'s `v7` needed a millisecond and `Ctx` exposed no clock, so `Timestamp.now()` and a Scope method answer it, and reading it is a syscall by the letter and a read from a mapped page in practice, nothing for a fiber to wait on. That is also this ADR's rule amended in the one place it needed to be: **"needs no event loop" is the question, not "does no IO," because needing the loop is what the layering has always actually been asking**, and a syscall that never waits does not need one. Percent coding is [ADR 057](./057-percent-is-needed-by-two-layers.md)'s: the App decodes every path param and a Service signs a URL, and a Service cannot import `nilo_http` to share the App's copy.

`http/convert.zig`, turning text into a type, was the interesting refusal: it does what a Core module would want to reuse, but it reaches the Bulkhead to say a request failed. It stayed exactly where it was. `nilo_config` needed the same job with no request behind it and got its own converter, `config/convert.zig`, forty lines rather than a shared one, because sharing it would mean naming `nilo_core` for `Str` and a tool module that cannot run under plain `zig test` is in the wrong layer ([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). Two converters, not one moved down: the second caller answered the question by not being the caller Core needed.

`nilo_id` answered the same "second caller" test the other way for its own open question. It ships the UUID format and not the source, `v4(entropy)` and `v7(entropy, ms)`, because entropy and the clock are both IO in Zig 0.16 and a module in the bottom layer has no Bulkhead to fetch either through. What was missing, a supported way for a handler to get either argument, is settled now rather than open: the millisecond by `Ctx`'s clock ([ADR 041](./041-core-knows-what-time-it-is.md)) and the entropy by `Ctx.entropy(comptime n)` through `bulkhead.randomSecure`, an App-layer call because the only question entropy raises is how the wait gets paid for, and only the App has a loop to pay it out of. `nilo_id` itself did not change: `Uuid.v7Now(scope)` is the two put together, for any `scope` carrying `entropy`.

### A layer is declared by the module and held by the build

Each module's directory carries its own build wiring and its own refusals table. `zig build layering` reads the `@import`s of every file under `core/`, `id/`, `config/`, `pw/`, `cache/`, `jwt/`, `fetch/`, `job/`, `sql/` and `s3/` and refuses one that is not in that module's row of the `layers` table in `build.zig`, hung off `test`. A rule about the shape of this repository that only `CLAUDE.md` states is a rule that erodes on the first afternoon somebody is in a hurry ([ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md)).

**A module's code may not reach up, and its tests may reach one layer up.** `sql/db.zig` and `sql/live.zig` drive a whole request through `nilo.testing.Client`, an App-level test at the bottom of a Service file, worth keeping. That does not force `nilo_sql` to declare `nilo_http`: an `@import` referenced only from a `test` block is never analysed in a build that is not a test build, so the published module names `nilo_core` alone and the separate test module names `nilo_http` as well. Checked rather than assumed: `zig build-obj` on a file importing a module that does not exist passes when only a test names it, and `zig test` on that file fails, pointing at the test. Telling that apart from an ordinary import needs a parser rather than a scan, so `build.zig`'s `layers` table lists each such exception under `in_tests` and does not verify it, which is weaker than the rest of the step and is written down at the table for exactly that reason. The same scan cannot tell a real `@import` from one inside a `//` doc comment or a `\\` multiline string a code generator writes (`sql/migrations.zig` prints a file whose own import line belongs to the generated file, not to this one); both are skipped at the line rather than parsed, because a real `@import` is never written after either.

**A shared module built once per optimize mode is load-bearing, and the failure mode has no symptom.** `build.zig` hands the same `nilo_id` to `nilo_sql` and to anything else in that mode. Two modules built from one root file are two different modules to Zig, so a second copy would make `id.Uuid` and `sql.Uuid` distinct types that print identically, and `db.insert` would refuse a generated key with a message naming the type it was given and the type it wants, in the same words. `sql/types.zig` carries the test that would notice.

**A list that does not name a directory cannot check it.** `build.zig` checks that every module root appears in `build.zig.zon`'s `.paths`, because a dependent whose package is missing a directory finds out at their own build. `core/` shipped for a whole session in neither list, and nothing failed locally; `zig fetch` would have handed out a package with no Core in it. Adding a module now means a row in `shipped_roots`, in `.paths`, and in `layers`.

**Which directory a file belongs in has a sharper test than "is it part of the framework."** A file that imports a module by name can live anywhere; a file that reaches into a module's internals belongs to that module. `bench/main.zig` names `nilo_http` the way a stranger's project would, so it lives outside it; `profile.zig` and `fuzz_main.zig` reach into `app.zig`, `router.zig` and `bulkhead.zig`, so they stay in `http/`.

## What was rejected

- **Leave it, `sql` importing `nilo` costs nothing at run time.** True at run time (Zig does not analyse what nothing reaches), and it is why this was right to leave alone for two modules. The cost is the development loop and the build graph, and both get worse once per module rather than once, which is why it does not survive an eighth.
- **Put Core inside the server's own directory as a second module.** The convention that a new file under a module root gets an `_ = @import(...)` line in that module's test block would pull every Core file into the server's test root by being followed correctly. A convention that punishes the people who keep it is worse than no convention.
- **Make Core a namespace, `nilo.core`, rather than a module.** A namespace is not a boundary in the build graph: it cannot be tested alone, cannot be imported without the rest, and nothing can be made to fail when somebody imports upward through it.
- **A fourth layer, splitting a Service's part that dials from its part that does not**, argued against `nilo_s3` specifically (signing a URL needs no socket, storing a file does). Rejected as a split inside one module rather than between two. This is not the split that later shipped: the Fitting layer ([ADR 061](./061-a-fitting-borrows-the-loop.md)) separates whole modules that borrow the loop and own no destination (`fetch/`, `job/`) from Services that dial a named system (`sql/`, `s3/`); it answers a different question than cutting `s3/` in half, which stayed rejected and stays one module.
- **A vtable for Scope.** An interface with a pointer and a function table would let a Service take a Scope it has never heard of, at the cost of an indirect call on every allocation a Service makes, on the request path ADR 017 guards hardest, to buy a polymorphism nobody asked for. The comptime check refuses an unsuitable type with a sentence and generates the same code the direct call generates.
- **Leave `Uuid` in `nilo_sql` and have `nilo_id` generate bytes.** Two types for one value, a conversion at every call site, and two `parse`s and two `writeText`s to keep in step; the first time they disagreed about whether hyphens are optional, the bug would be in whichever one the reader did not open.
- **Move `Uuid` into `nilo_core`.** Permitted by the two-layer rule (an App returning one, a Service reading one out of a column, is two callers) and refused by the not-a-drawer rule: Core is what every layer agrees about, and an HTTP server has no opinion about UUIDs at all. Admitting one would bring `Timestamp` on the same argument, and then Core is the drawer this decision opened by refusing. **`Timestamp` and `Date` were later admitted anyway, on a different argument** ([ADR 057](./057-percent-is-needed-by-two-layers.md)): a handler reads and writes them in a body, a query and a path with no database in the build, so the not-a-drawer rule is met by a second layer that needs them and a type that names no database. `Uuid` is the same shape and could follow on the same grounds; it has not yet, because `nilo_id` already gives both layers one.
- **A fourth layer so that "tool module" is a rank.** A layer earns itself by changing what a module may import; a tool module's rule is Core's rule (no loop, imports `nilo_core`, runs under plain `zig test`). Naming a rank would add a word to the table without adding a rule to the build.
- **An umbrella module re-exporting the tool modules.** With two tool modules it costs a project the bytes of both; see above.
- **Have `nilo_id` fetch its own randomness**, `id.v4()` with no arguments over a seeded source it holds. Needs global mutable state, a seeding moment a CLI does not have, and a reach into the operating system that a tool module may not make. A `v4()` seeded from a `DefaultPrng` would be a predictable session token shipped quietly; the format-only module asks instead. `nilo_id` still does not fetch its own randomness; how a handler supplies it is answered separately, above and in [ADR 042](./042-entropy-belongs-to-the-loop.md).

## What it costs

Against [ADR 017](./017-the-trade-budget-has-four-axes.md)'s four axes.

| Axis | Cost |
|---|---|
| Allocations per request | none. A Scope is checked while compiling, and nothing here moves onto the request path. |
| Memory per idle connection | none. Nothing in this decision is per-connection. |
| Throughput and p99 | none. The Scope check compiles to the calls `Ctx` already received. |
| Binary size | zero for splitting Core out and adding the Scope; zero for a project that does not import `nilo_id`; 16 bytes for one that also calls `v7`. |

Measured stripped `ReleaseFast`, against a build of the parent commit in a `git worktree`, the method `docs/history.md` settled on after stashing gave two contradictory readings half an hour apart: `example-hello` 885,504 bytes, `example-rest` 1,031,744, `nilo-hello` 890,384, byte-identical before and after both changes. That is the answer the design predicted (moving a declaration between modules does not change what is reachable from a root), written down before it was measured so a wrong prediction would have been noticed. The 16-byte row is a second pair of programs, identical except that one calls `v7` and prints the result: 216,568 bytes against 216,584. `toText` inlines into its caller, and what is left is the version bits and a `memcpy`.

`nilo_config` repeated the same zero for the split itself on the same three programs when it joined the bottom layer ([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)); `nilo_pw` measured the same property a different way, a byte-identical `ReleaseFast` section dump of the benchmark server ([ADR 044](./044-a-password-hash-is-gated-because-forgetting-is-silent.md)). Each module's own ADR carries its own added-feature cost.
