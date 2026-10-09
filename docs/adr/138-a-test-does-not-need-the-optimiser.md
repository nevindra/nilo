# A test does not need the optimiser

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)

## Context

`zig build test`, warm, after one edit under `http/`, took 30.6s on an x86_64 machine. Thirty of those seconds were one step. `test-fetch-engine` builds `fetch/deadline.zig` against the whole module graph in both optimize modes, and the `ReleaseSafe` half compiled alone for thirty seconds while fifteen of sixteen cores had nothing to do. The whole run spent 110s of CPU, so a perfectly parallel build would have finished in seven. It did not, because a single compilation cannot be split.

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

25.977 of 27.614 seconds is LLVM: 94.1%, and the `Debug` column has no row for it at all, because `Debug` on x86_64 already runs on Zig's own backend. Inside the LLVM figure, 24.300s is pass execution and 1.753s is instruction selection.

**What the optimiser buys a test is nothing this repository asks for.** A test binary is compiled once and run once, in a few hundred milliseconds. Nobody profiles it, nobody ships it, and the whole reason [ADR 018](./018-a-response-owns-its-headers.md) put `ReleaseSafe` on the gate was the safety checks: a `Response.headers` use-after-return that passed in `Debug`, where the bytes a dangling pointer points at happen to still be there. Those checks are inserted by Sema, in the AIR before any backend sees it, so they survive a backend swap intact.

A second machine changed what "a test" could assume about the backend. On an Apple M1 Pro, 8 cores, 16 GB, macOS, Zig 0.16.0, `zig build test` did not run slowly on the self-hosted `ReleaseSafe` backend. It killed the machine, three times, before printing a line. `pw/pw.zig` is a leaf, importing nothing, so the compile is the whole story and there is no module graph to blame:

| | backend | peak footprint | wall | outcome |
|---|---|---|---|---|
| `-OReleaseSafe` | `-fllvm` | 290 MB | 6s | finished, 561 KB binary |
| `-OReleaseSafe` | `-fno-llvm` | 4,022 MB, still climbing | killed at 7s | not finished |
| `-ODebug` | default | 229 MB | 2s | finished; byte-for-byte LLVM's binary ±16 |
| `-ODebug` | `-fllvm` | 208 MB | 2s | finished |
| `-ODebug` | `-fno-llvm` | 4,010 MB, still climbing | killed at 7s | not finished |

Two uncapped observations from the same afternoon, inside `zig build test -j1`: the `ReleaseSafe` `pw` compile at 5.3 GB after 40 seconds, and a sibling the runner had moved on to at 15 GB before it was killed by hand. Neither had finished, and whether the aarch64 self-hosted backend ever would have is not known and does not matter: at `-j8` the build is eight of those at once on a 16 GB machine.

Two things follow that were not true on the first machine. `Debug` is not "already on this backend" on aarch64: Zig's default there is LLVM in both modes, the default `Debug` binary is LLVM's to within sixteen bytes, so `null` means LLVM on aarch64 and means self-hosted on x86_64. And the failure is not slowness and does not look like it: a slow build sits at the CPU, this one ran the machine out of memory and swap in under a minute, and macOS takes the machine down rather than the compiler, so there was no log and no `Build Summary`, three times in a row. The diagnosis needed a guard that kills the compiler at a footprint cap, reading physical footprint rather than RSS: with 3.8 GB of the process compressed, `ps` reported 1.4 GB of a 5.3 GB process.

## Decision

**The `ReleaseSafe` test builds run on Zig's self-hosted backend, named only where it was measured to work.**

```zig
fn testBackend(target: std.Build.ResolvedTarget, mode: std.builtin.OptimizeMode) ?bool {
    if (mode == loop_mode) return null;
    return if (target.result.cpu.arch == .x86_64) false else null;
}
```

On x86_64, `ReleaseSafe` test binaries build with `.use_llvm = false`: `.use_llvm = false` on the `ReleaseSafe` test builds compiles the same root in 1.6s with the same 48 tests green, against 27.6s through LLVM. Everywhere else, both modes get `null`: Zig's own default, which `build.zig` then neither forces nor forbids. On aarch64 today that is LLVM in both modes, and if a later Zig makes its aarch64 backend the default the tests will follow it the way the `Debug` half already does on x86_64, at which point the table above is the thing to re-run first.

**This is a very close gate rather than the identical one, and it is worth naming rather than waving past.** A use-after-return is undefined behaviour, and whether it is caught depends on stack layout, which is exactly what a backend decides: LLVM reuses a dead frame differently from the self-hosted backend, so a lifetime bug that one of them exposes the other might not. The trade is a gate that runs in 1.6s instead of 27.6s on x86_64, which means it runs on every `zig build test` rather than being something a contributor is tempted to skip. A gate nobody waits for catches more than a gate nobody runs.

**A program built only to see that it still compiles builds no binary.** `nilo-profile` and `nilo-fuzz` are on `test` because both stopped compiling unnoticed, and the step they hung off was the one that builds them, `ReleaseFast` and `ReleaseSafe` through LLVM: 22 s and 27 s of every `test`, beside the suite's compile. `test` now depends on a second Compile step over the same root module, whose binary nothing asks for, so the Maker passes `-fno-emit-bin`: the same analysis in the same mode with the same options, 0.6 s and 3 s. `zig build profile` and `zig build fuzz` build the real ones as before.

**On Zig 0.17 the loop is incremental.** `zig build test-http -fincremental --watch` runs the framework's suite alone and rebuilds it in under a second after a save, where a fresh compile is 33 s of semantic analysis on one core; what is left of the loop is the suite's own run ([the run](../../bench/result/build.md#where-zig-build-test-waits-on-zig-017)). `test` and `test-all` stay what they were, the gate before a commit.

Every `bench-*` target stays on LLVM and none of them was touched: they are all pinned to `.ReleaseFast` already. A throughput number measured through a backend that does not optimise would be fiction, and ADR 017's axes are the whole point of that directory.

## What was rejected

**Take the `ReleaseSafe` module gates off `test`.** Tried first, and it works on the symptom: `test` drops from 30.6s to 9.5s. It does nothing for `test-all`, which CI runs on every push and which took 65.9s, and it weakens the gate on purpose rather than as a side effect. The backend swap is strictly better: `test-all` after the same edit is 12.5s and every mode still runs.

**`-fincremental` on `test` itself.** On Zig 0.16 it did not work here at all: all thirteen test binaries linked and then died with `undefined symbol: main`, exit 127. On 0.17 it does, and it is now the loop (Decision), but on `test-http` and not on `test`: `test` is 568 compile steps, and a resident compiler each, at 750 MB for the suite's, is not memory a laptop has.

**More modules.** The reflex, given ten modules and a layering build step, is that finer splits would compile faster. They would not: LLVM works on a whole compilation at once, with no equivalent of a Rust crate boundary, and this one compilation discovered 712 files. The ten-module layering buys import discipline, which is what ADR 038 claimed for it, and buys nothing at all here.

**Turning debug info off.** `stripMeasured` already records that this halves a release build. Half is not 94%, and the two are independent anyway.

**Force LLVM with `true` rather than `null` on every architecture but x86_64.** It reads as more explicit and it is less honest: it would pin the tests to a backend on architectures nobody here has measured either. `null` says what is known, that `build.zig` has no grounds to override Zig on an architecture it has not tested, and nothing more.

**Cap the memory instead of naming the architecture.** `step.max_rss` exists and the runner schedules by it, and a 4 GB claim on each `ReleaseSafe` test would have kept the aarch64 machine alive. It would also have made `zig build test` a 4 GB × N serial crawl that still never finishes, on a compile LLVM does in 290 MB and six seconds. A cap is the right tool for a step whose cost is known and large; this step's cost was not a cost, it was a backend that does not work there yet.

**Wait for the aarch64 backend.** It is the right long-term answer and the wrong thing to gate a test suite on. When the aarch64 backend lands as a default, the `null` above picks it up without a change here.

## What it costs

Nothing on any of ADR 017's four axes: this changes how the test suite is compiled, not anything shipped. What it buys is time, put against x86_64 figures taken at commit `b302549`:

- `zig build test` after one edit under `http/`: 30.6s to 9.8s.
- `zig build test-all` after the same edit: 65.9s to 12.5s. CPU 387s to 135s, so the work is gone rather than spread.
- Re-measured at `a52e958`, after 4,418 lines had landed, the same edit is 13s to 18s against 36s to 46s. The ratio held and the absolutes did not, which is why `bench/result/build.md` carries both and this file carries neither as a promise.
- A run that changes nothing is unaffected, because that floor is the refusals, which never cache ([ADR 026](./026-the-rule-about-error-messages-is-held-by-a-build-step.md)).
- `zig build test` and `test-all` on aarch64 run the `ReleaseSafe` gates through LLVM: slower than the x86_64 figures above, and they finish rather than taking the machine down with them.

## Consequences

- `testBackend` in `build.zig`, named by every `addTest` site, keyed on both the target and the mode.
- The gate runs the same tests on either backend: `zig build test-all` reports the same pass count through either backend, character for character. This was checked rather than assumed, since a backend that quietly dropped a test would look exactly like a fast one.
- The guard that found the aarch64 failure mode (a footprint cap that kills the compiler) is not in the repository and should not be; what is in the repository is the rule it found, and [`bench/result/build.md`](../../bench/result/build.md) carries the table.
- `CLAUDE.md`'s "take a stuck build's CPU time before believing it is slow" has a case that is its inverse: a build with no CPU time and no process was not stuck, it was killed with the machine. Read `vm.swapusage` (or the platform's equivalent) before reading anything else.
- The next thing in the way is `snippets`: 66 separate objects, each importing all nine modules, 48s of CPU. Not this decision's problem.
