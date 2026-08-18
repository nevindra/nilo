# 0075 — a lazy dependency is a request, not a conditional

**Status:** accepted
**Amends:** [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)

## Context

`build.zig.zon` marks pg.zig and zqlite `.lazy = true`, and four files say what
that was supposed to buy:

> a project that serves HTTP and never imports `nilo_sql` does not fetch, build
> or link any of it

Two thirds of that were true. An application that imported `nilo_http`,
`nilo_config`, `nilo_id` and `nilo_pw` and named no database was checked with
`strings` and `nm`: no `sqlite3`, no `libpq`, no `PGconn`, zero symbols from
either driver. **Build and link held.**

Fetch did not. A clean `rm -rf zig-pkg .zig-cache && zig build` of that
application downloaded this:

| package | size | wanted |
|---|---|---|
| zio | 2.7 MB | yes, the Engine |
| zqlite | 9.8 MB | no |
| pg | 572 KB | no |
| tls | 456 KB | no, pg.zig's |
| xsync | 152 KB | no, pg.zig's |
| metrics | 156 KB | no, pg.zig's |

**11.1 MB fetched against 2.7 MB used**, and the build also attempted
buffer.zig — pg.zig's fifth — and printed a fetch error when GitHub rate-limited
it. So an application with no database anywhere in it could not build offline
without a Postgres driver's dependency graph in the cache, and could fail to
build at all because somebody else's server was busy.

It was not found by reading. It was found by an application built outside the
repository to answer a different question, which noticed the download because it
had cleared its package directory for an unrelated reason.

## The cause

`.lazy = true` and `b.lazyDependency` do two different jobs, and the name
suggests they do one.

`.lazy = true` stops Zig fetching a package **while reading the manifest**. That
is the only thing it does. What happens next is up to `build.zig`, and
`b.lazyDependency` does not mean "fetch this if somebody uses it". It means
*request* this: it returns null on the pass that discovers the package is
missing, enqueues the download, and re-runs the build. So this, at the top of
`build()` —

```zig
if (b.lazyDependency("pg",     .{ … })) |pg|     { nilo_sql.addImport("pg", …); }
if (b.lazyDependency("zqlite", .{ … })) |zqlite| { nilo_sql.addImport("zqlite", …); }
```

— runs for every dependent whatever they import, because **a dependent's build
runs the whole of ours**. There were three such pairs, and the third was the
expensive one: it sat inside the loop that builds *nilo's own test suite*, which
a dependent configures and never runs.

A conditional was needed and no condition existed. That is the decision.

## Decision

**The drivers sit behind a build option, and its default is who is asking.**

```zig
const want_sql = b.option(bool, "sql", "…") orelse (b.pkg_hash.len == 0);
```

`b.pkg_hash` is empty for the package being built and is the dependency's own
hash when somebody else is building it. So this repository builds all of itself
with no flag — `zig build test`, `test-all`, `test-sql`, `bench-sql`, `size-sql`
all work as they did — and a dependent gets the drivers when it asks:

```zig
const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .sql = true });
```

**The module exists either way, and what changes is its root file.** With the
flag off, `nilo_sql`'s root is `sql/unbuilt.zig`, which is one `@compileError`
naming the line that fixes it. The alternative — leaving the module out of the
graph — makes `dep.module("nilo_sql")` a panic from inside `std.Build` about a
name it could not find, which is somebody else's sentence about our decision and
against everything `refusals/` exists for (ADR 0027).

**And the number is a build step.** `zig build fetch-check -Dnetwork` builds
`bench/dependent/` — a project whose whole content is `app.get("/health", …)`
and one import — against two cold caches, and fails on anything but zio landing.
It is off `test` for the reason `smoke-tls` is: it needs a route to the
internet, and a gate that goes green because a machine had none is worse than no
gate.

Getting that step to tell the truth took three attempts and the two wrong ones
are worth keeping, because both looked like passes:

- **`--fetch` with a cold global cache and a warm `zig-pkg/`.** Nothing is
  downloaded when the packages are already unpacked, so counting downloads said
  zero.
- **Counting `zig-pkg/` with a warm global cache.** Zig unpacks everything in
  the manifest it already holds, whether or not the build asked for it, so
  counting unpacked packages said everything.

Both caches have to be cold. That is one line in the step and it is the only
line in it that is not obvious.

## What was rejected

**Splitting `nilo_sql` into its own package**, with its own `build.zig.zon`, so
a dependent that does not name it never reads the manifest. This is the shape
ADR 0041 already describes — the repository is modules — and it is the right
answer eventually. It was not taken now because it moves the version of every
module out of one file and into eight, and because it does not make the mistake
above impossible: a second package can call `lazyDependency` unconditionally too.
The build step is what makes it impossible, and it is worth having whichever
shape the packages end up in.

**Making the option default to off everywhere** and passing `-Dsql=true` in CI.
That is a flag in a file nobody reads standing between a contributor and
`zig build test`, and the first time it is forgotten the SQL suite silently
stops running. `b.pkg_hash` costs one expression and cannot be forgotten.

**Leaving it and documenting the download.** The sentence was already documented,
in four files, and had been wrong in all four for a year. This repository has now
been wrong five times about a published claim and every one of them was found by
running something rather than by reading — `connect_on_init` (ADR 0062), the
per-connection figure (ADR 0063), three modules blocked on an open seam
(ADR 0040), the page a connection held for nothing (ADR 0071), and this. The
lesson is not "write more carefully".

## What it costs

Nothing on any of the four axes. No code in the request path changed, no type
changed, and the binaries are byte-for-byte what they were: `zig build size-sql`
still gives 1,677,464 and 2,202,304, a difference of 524,840.

What a dependent pays changes from 11.1 MB to 498.7 KB, measured both ways
through `bench/dependent/`, and a dependent that wants SQL pays one field in
`build.zig`.
