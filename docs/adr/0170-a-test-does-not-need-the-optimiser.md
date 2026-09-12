# A test does not need the optimiser

> **Amended by [ADR 0189](./0189-a-backend-is-trusted-where-it-was-measured.md).**
> Every figure below is x86_64. On aarch64 the same `use_llvm = false` took a
> 290 MB compile past 15 GB and killed a 16 GB machine three times, so
> `testBackend` now names the self-hosted backend only on x86_64. The trade
> this file makes is unchanged where it was measured.

`zig build test`, warm, after one edit under `http/`, took 30.6s. Thirty of
those seconds were one step. `test-fetch-engine` builds `fetch/deadline.zig`
against the whole module graph in both optimize modes, and the `ReleaseSafe`
half compiled alone for thirty seconds while fifteen of sixteen cores had
nothing to do. The whole run spent 110s of CPU, so a perfectly parallel build
would have finished in seven. It did not, because a single compilation cannot
be split.

`--time-report` says where the thirty seconds went, and it is not close:

| phase | Debug | ReleaseSafe |
|---|---|---|
| Parsing | 133.7ms | 189.2ms |
| AST Lowering | 509.3ms | 599.5ms |
| Semantic Analysis | 1.003s | 1.395s |
| Code Generation | 1.034s | 1.427s |
| **LLVM Emit** | **no such phase** | **25.977s** |
| Linking | 318.5ms | 7.6ms |
| Linker Flush | 47.5ms | 52.7ms |
| **total** | **1.219s** | **27.614s** |

25.977 of 27.614 seconds is LLVM. That is 94.1%, and the `Debug` column has no
row for it at all, because `Debug` on x86_64 already runs on Zig's own backend.
Inside the LLVM figure, 24.300s is pass execution and 1.753s is instruction
selection.

## What the optimiser buys a test

Nothing this repository asks for. A test binary is compiled once and run once,
in a few hundred milliseconds. Nobody profiles it, nobody ships it, and the
whole reason ADR 0019 put `ReleaseSafe` on the gate was the *safety checks*: a
`Response.headers` use-after-return that passed in `Debug`, where the bytes a
dangling pointer points at happen to still be there.

Those checks are inserted by Sema. They are in the AIR before any backend sees
it, so they survive the swap intact. `.use_llvm = false` on the `ReleaseSafe`
test builds compiles the same root in 1.6s with the same 48 tests green.

## What it costs

One thing, and it is worth naming rather than waving past. A use-after-return
is undefined behaviour, and whether it is *caught* depends on stack layout,
which is exactly what a backend decides. LLVM reuses a dead frame differently
from the self-hosted backend, so a lifetime bug that one of them exposes the
other might not.

So this is a very close gate rather than the identical one. The trade is a
gate that runs in 1.6s instead of 27.6s, which means it runs on every `zig
build test` rather than being something a contributor is tempted to skip. A
gate nobody waits for catches more than a gate nobody runs.

Every `bench-*` target stays on LLVM, and none of them was touched: they are
all pinned to `.ReleaseFast` already. A throughput number measured through a
backend that does not optimise would be fiction, and ADR 0018's axes are the
whole point of that directory.

## Rejected

**Take the `ReleaseSafe` module gates off `test`.** This was tried first and it
works on the symptom: `test` drops from 30.6s to 9.5s. It does nothing for
`test-all`, which CI runs on every push and which took 65.9s, and it weakens
the gate on purpose rather than as a side effect. The backend swap is strictly
better: `test-all` after the same edit is 12.5s and every mode still runs.

**`-fincremental`.** Incremental compilation only exists on the self-hosted
backend, so switching would have unlocked it. It does not work on Zig 0.16
here: all thirteen test binaries linked and then died with `undefined symbol:
main`, exit 127. Worth retrying on a later Zig, and nothing to build on now.

**More modules.** The reflex, given ten modules and a layering build step, is
that finer splits would compile faster. They would not. LLVM works on a whole
compilation at once, with no equivalent of a Rust crate boundary, and this one
compilation discovered 712 files. The ten-module layering buys import
discipline, which is what ADR 0041 claimed for it, and buys nothing at all
here.

**Turning debug info off.** `stripMeasured` already records that this halves a
release build. Half is not 94%, and the two are independent anyway.

## Consequences

- `testBackend` in `build.zig`, named by all fourteen `addTest` sites. `Debug`
  gets `null`, which is the default, so only the second mode changes — and,
  since ADR 0189, only on x86_64.
- The gate runs the same tests. `zig build test-all` reports `382/382 steps
  succeeded; 2870/3052 tests passed (182 skipped)` through either backend,
  character for character. This was checked rather than assumed: a backend that
  quietly dropped a test would look exactly like a fast one.
- `zig build test` after one edit under `http/`: 30.6s to 9.8s.
- `zig build test-all` after the same edit: 65.9s to 12.5s. CPU 387s to 135s,
  so the work is gone rather than spread.
- Those two figures were taken at `b302549`. Re-measured at `a52e958`, after
  4,418 lines landed, the same edit is 13s to 18s against 36s to 46s. The ratio
  held and the absolutes did not, which is why `bench/result/build.md` carries
  both and this file carries neither as a promise.
- A run that changes nothing is unaffected, because that floor is the refusals,
  which never cache (ADR 0027).
- The next thing in the way is `snippets`: 66 separate objects, each importing
  all nine modules, 48s of CPU. Not this decision's problem.
