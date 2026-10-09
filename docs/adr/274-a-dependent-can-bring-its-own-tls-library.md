# A dependent can bring its own TLS library

**Status:** accepted
**Topic:** [tls](../design/tls.md)
**Extends:** [ADR 212](./212-tls-is-an-option-a-build-asks-for.md), the `.tls` flag and the pin it fetches; [ADR 263](./263-a-first-project-is-one-call-from-its-build-file.md), `AppOptions`.
**Applies:** [ADR 066](./066-a-lazy-dependency-is-a-request.md) (a flag, not `.lazy`, keeps a dependency out), [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md) (one file names the library), [ADR 017](./017-the-trade-budget-has-four-axes.md).

## Context

`wireOptions` adds the `tls` import from nilo's pin whenever `.tls` is on, and the pin is a fork (`nevindra/tls.zig`, two commits ahead of upstream). So a fix to the TLS library reached an application only through a nilo release, and a dependent that wanted a newer commit, its own fork or a path checkout had to edit nilo. The TLS library is the place where a silent failure is most expensive (ADR 027), and nilo is not the party that audits it: the application is.

Cargo's features are how reqwest and actix let a dependent choose, and actix shows the cost to avoid: its method names carry the rustls version (`bind_rustls_0_23`), so every upgrade breaks callers. The choice here must not put a version in any name nilo publishes.

## Decision

**`.tls_own = true` (with `.tls = true`) leaves the `tls` import to the dependent, and nilo's pin is neither requested nor fetched.**

- A `build.zig` option cannot carry a `Module`, so the option only says that the import is the dependent's. The dependent then writes one line, on the module nilo already exports:

  ```zig
  const nilo = b.dependency("nilo", .{ .target = target, .optimize = optimize, .tls = true, .tls_own = true });
  nilo.module("nilo_http").addImport("tls", b.dependency("tls", .{ .target = target, .optimize = optimize }).module("tls"));
  ```

  `Module.addImport` replaces an import of the same name, which is the whole mechanism. `nilo.app` takes the module as `AppOptions.tls_module` and writes both for a project that uses it; `tls_module` implies `tls` and `tls_own`.
- **The pin is not fetched.** `wireOptions` does not call `b.lazyDependency("tls", …)` in this branch (ADR 066: the flag, not `.lazy = true`, is what keeps a package out). `zig build fetch-check -Dnetwork` builds `bench/dependent-tls-own/` against a cold cache and fails on anything but zio landing.
- **The import is never absent.** With the option on and the line forgotten, `tls` is `http/engine/tls_unset.zig`, whose one compile error is nilo's, and names the `addImport` line to write. Zig's own answer to a missing import (`no module named 'tls' available`) names nothing. The stub is reached only through the Engine's existing comptime `if (nilo_build.tls)` (ADR 212), so it costs a build that does not use it nothing.
- **"Compatible" is the surface `http/engine/zio.zig` uses**, listed in [the reference](../reference/app.md#a-tls-library-of-your-own) and nowhere else in nilo: `tls.config.CertKeyPair` (`fromFilePath`, `deinit`, `.bundle.bytes`, `.key.signature_scheme` and the public key fields of the three schemes), `tls.config.Offload`, `tls.config.Server`, `tls.server`, `tls.input_buffer_len`, `tls.output_buffer_len`, and on the connection `reader`, `writer`, `cleartext_buf`, `alpn_protocol` and `close`. A module that lacks one fails to compile in the Engine at that name; nothing is checked at run time, and nilo does not version the surface (that would be actix's `bind_rustls_0_23`).
- **Held by build steps.** `zig build tls-own` (on `test`, beside `two-modes`) compiles a dependent that injects a real tls.zig it fetched itself, and a dependent that sets the option and forgets the line, which must fail with the message, matched by `expectStdErrMatch` the way a Refusal's `.says` is. `fetch-check` holds the not-fetched claim.

## What it costs, on ADR 017's four axes

Nothing on the request path, per connection or in a default build: the option adds one `bool` to the build's option set and a branch in `wireOptions`. A build that sets it links whichever library the dependent chose, so the 560 KB of ADR 212 is theirs to measure. No binary changes for a dependent that does not set it.

## What was rejected

- **Leaving the import out and letting Zig report it.** The error says a module is missing and not which line fixes it, which is what a first-week trap is (ADR 066's lesson is that the message is the interface).
- **An option carrying a path or URL (`.tls_from = "…"`).** nilo would have to run `b.dependency` on a string with no way to pass the dependent's arguments (target, optimize, its own pins), and a path option resolves against nilo's tree, not the dependent's.
- **Making the library a parameter of `nilo_http`'s public API.** The Engine is the only file that names it (ADR 001); a type parameter threads the library through `App` for a choice made once at build time.
- **Checking the surface at compile time with a struct of expected declarations.** It would be a second statement of what `zio.zig` uses, and the first to go stale; the compile error at the use is exact and cannot drift.

## Consequences

A fix to tls.zig reaches an application on the application's schedule. The price is that the application owns compatibility: a tls.zig whose API drifts breaks the Engine at the use, in the dependent's build. The pin in `build.zig.zon` is still the tested one; `bench/tls-own/build.zig.zon` repeats it, and a bump moves both.
