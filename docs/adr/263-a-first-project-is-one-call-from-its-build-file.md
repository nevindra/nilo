# A first project is one call from its build file

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)
**Extends:** [ADR 190](./190-a-restart-on-save-watches-the-binary-not-the-sources.md) (the `dev` step a dependent had to write is now written by the helper), [ADR 069](./069-a-library-can-tell-what-mode-the-program-was-built-in.md) (the optimize mode is passed to the dependency in the one place that can forget to)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 066](./066-a-lazy-dependency-is-a-request.md) (a flag, not `.lazy`, keeps a dependency out), [ADR 009](./009-static-files-are-held-in-memory-or-opened.md) (`embedDir` is the precedent for a function of nilo's `build.zig` a dependent calls)

## Context

A first project took six steps before its first route: `zig init`, `zig fetch --save` with a pinned commit, replace the generated `build.zig`, delete `src/root.zig`, add the root declarations, and fourteen lines for a `dev` step. `go mod init` and `npm create hono` are one line each. Every step was a place to be wrong, and the one people missed (passing `.optimize` through, in the test step above all) is the one ADR 069 had to add a runtime warning for.

## Decision

**`@import("nilo").app(b, options)` writes a server's whole `build`.** It is a public function of nilo's root `build.zig`, beside `embedDir`, and a dependent's `build.zig` is:

```zig
const std = @import("std");
const nilo = @import("nilo");

pub fn build(b: *std.Build) void {
    _ = nilo.app(b, .{ .name = "hello", .root = b.path("src/main.zig") });
}
```

It reads `-Dtarget` and `-Doptimize` (or takes `.target` and `.optimize`), calls `b.dependency("nilo", …)` with both and with the flags in the options, creates the executable with `nilo_http` imported (and `nilo_sql` when `.sql` is set), installs it, and adds `run`, `dev` and `test`. `dev` is ADR 190's runner wired the way `dev-<example>` is in this repository. It returns `AppBuilt`: the executable, the test artifact and the dependency, so a project adds a module or a step to what exists rather than to a second instance of the dependency.

**The option struct has one required field beyond the name, and every other field has a default.** `name` and `root` are required; `target`, `optimize`, `sql`, `tls`, `http2` and `libdeflate` are not. This is the property that makes the function safe to freeze at 1.0: a field added later changes no project already written. A flag that is `false` is passed as `false`, which is the dependency's default for a dependent (`sql` defaults to off when somebody else builds nilo), so a project that sets none fetches zio and nothing else (ADR 066).

**A new project is `template/` copied out of the package.** `template/` is a working server (two routes, one typed, a test), shipped in `.paths`, with a `build.zig` that is the three lines above and a `build.zig.zon` whose `.dependencies` is empty: the commit a release is pinned to does not exist until the release does, so a template cannot name it. The guide's four commands are `mkdir`, a `curl | tar` of that commit's `template/` (the commit's tarball is addressed by the commit the next line pins, so the two cannot disagree), `zig fetch --save` with the pinned commit, and `zig build dev`.

**`zig build template-check` holds the template, and is on `test`.** It copies `template/` to a scratch directory, writes nilo into the manifest as a path to this working copy, and runs `zig build test` and `zig build` there. It needs nothing `test` does not already: zio comes from the global cache. A change to `nilo.app` that breaks a dependent, or to the framework that breaks the template, fails the gate, which `bench/two-modes/` and `bench/dependent/` alone did not hold for the helper.

## What it costs, on ADR 017's four axes

- **Allocations per request, memory per idle connection**: none. The function runs while the build is configured and nothing it makes is in a binary that did not call it.
- **Throughput and p99**: none. The executable is the one the hand-written file made.
- **Binary size**: none. `template/` is source in the package, which grows by about 2 KB.
- **The cost is the surface.** `app`, `AppOptions` and `AppBuilt` join `embedDir` as public build API that 1.0 freezes. The defaults rule above is what keeps that affordable; a project that needs more than the options give writes the `build.zig` by hand, which the guide keeps (it is the "Without the helper" section) and nothing requires the helper. `dev` builds `nilo-dev` with the project's target, as the hand-written lines did.

## What was rejected

**Leaving the `build.zig` to be copied from the guide.** The status quo, and what made six steps. A file pasted from a page is a second copy that nothing compiles when the framework changes.

**A template mechanism in `zig init`.** Zig 0.17's `zig init` takes `--minimal` and nothing else; there is no template argument to name a package, so nilo cannot be what it initialises from.

**A `nilo new` program.** One command, but a binary to install, version and keep in step with the framework, in a toolchain whose own install story is `zig fetch`. The copied directory is checked by the build; a generator would be one more thing to check.

**A separate template repository.** A good place to click "Use this template" from, and still possible, but a second copy of the files that nothing in this repository compiles: it drifts from `nilo.app` the first time either changes. If it is made it is generated from `template/` at a release.

**The template's manifest naming nilo.** It cannot be pinned to a commit that does not exist yet, and a floating `?ref=` is the install the guide warns against.

**A helper that takes no options and a second one for SQL.** Two names for one decision. The flags are the dependency's; the helper forwards them.

## Consequences

- `docs/guide/getting-started.md` opens with the four commands, keeps `nilo.app` for a project that exists, and keeps the hand-written file as the way without the helper. The `?ref=` and commit appear twice on that page; `docs/releasing.md` already lists the page as the place the pin is bumped.
- `bench/dependent/` keeps its hand-written `build.zig`: it exists to show that a project importing only `nilo_http` downloads only zio, and a helper that also forwards four flags would hide the one call that proves it.
- `template/` is in `.paths` and in `shipped_roots`, so a manifest that forgets it fails the build.
