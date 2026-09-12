# A backend is trusted where it was measured

[ADR 0170](./0170-a-test-does-not-need-the-optimiser.md) put the `ReleaseSafe`
test builds on Zig's self-hosted backend, and every number in it was taken on
x86_64. The decision was written as if it were about a backend. It was about
*one* backend, and Zig has one per architecture.

On an Apple M1 Pro — 8 cores, 16 GB, macOS, Zig 0.16.0 — `zig build test` did
not run slowly. It killed the machine, three times, before printing a line.

## What was measured

`pw/pw.zig` is a leaf: it imports nothing, so the compile below is the whole
story and there is no module graph to blame. Same root, same mode, a binary
emitted, machine otherwise quiet, physical footprint sampled once a second and
the compiler killed at a cap:

| | backend | peak footprint | wall | outcome |
|---|---|---|---|---|
| `-OReleaseSafe` | `-fllvm` | **290 MB** | 6s | finished, 561 KB binary |
| `-OReleaseSafe` | `-fno-llvm` | **4,022 MB, still climbing** | killed at 7s | — |
| `-ODebug` | default | 229 MB | 2s | finished; byte-for-byte LLVM's binary ±16 |
| `-ODebug` | `-fllvm` | 208 MB | 2s | finished |
| `-ODebug` | `-fno-llvm` | **4,010 MB, still climbing** | killed at 7s | — |

Two uncapped observations from the same afternoon, inside `zig build test -j1`:
the `ReleaseSafe` `pw` compile at 5.3 GB after 40 seconds, and a sibling the
runner had moved on to at **15 GB** before it was killed by hand. Neither had
finished. Whether the aarch64 backend ever would have is not known and does
not matter: at `-j8` the build is eight of those at once on a 16 GB machine.

Two things follow that ADR 0170 did not say because on its machine they were
not true:

- **`Debug` is not "already on this backend" on aarch64.** Zig's default there
  is LLVM in both modes — the default `Debug` binary is LLVM's to within sixteen
  bytes. So `null` means LLVM here and means self-hosted on x86_64, and the one
  line that changed anything was the `false` for `ReleaseSafe`.
- **The failure is not slowness and does not look like it.** A slow build sits
  at the CPU. This one ran the machine out of memory and swap in under a minute,
  and macOS takes the machine down rather than the compiler — so there was no
  log, no `Build Summary`, nothing to read, three times in a row. The diagnosis
  needed a guard that *kills the compiler* at a footprint cap, and needed it to
  read physical footprint rather than RSS: with 3.8 GB of the process compressed,
  `ps` reported 1.4 GB of a 5.3 GB process.

## Decision

`testBackend` takes the target. The self-hosted backend is named only where ADR
0170 measured it:

```zig
fn testBackend(target: std.Build.ResolvedTarget, mode: std.builtin.OptimizeMode) ?bool {
    if (mode == loop_mode) return null;
    return if (target.result.cpu.arch == .x86_64) false else null;
}
```

Everywhere else both modes get `null`: Zig's own default, which `build.zig` then
neither forces nor forbids. On aarch64 today that is LLVM in both modes, and if
a later Zig makes its aarch64 backend the default the tests will follow it the
way the `Debug` half already does on x86_64 — at which point the table above is
the thing to re-run first.

ADR 0170's trade is unchanged where it was made. Its figures are x86_64 figures,
and it now says so.

## Rejected

**Force LLVM with `true` rather than `null`.** It reads as more explicit and it
is less honest: it would pin the tests to a backend on architectures nobody here
has measured either. `null` says what is known — that `build.zig` has no grounds
to override Zig on this architecture — and nothing more.

**Cap the memory instead.** `step.max_rss` exists, the runner schedules by it,
and a 4 GB claim on each `ReleaseSafe` test would have kept the machine alive.
It would also have made `zig build test` a 4 GB × N serial crawl that still
never finishes, on a compile LLVM does in 290 MB and six seconds. A cap is the
right tool for a step whose cost is known and large; this step's cost was not a
cost, it was a backend that does not work here yet.

**Wait for the backend.** It is the right long-term answer and the wrong thing
to gate a test suite on. When the aarch64 backend lands as a default, the
`null` above picks it up without a change here.

## Consequences

- `zig build test` and `test-all` on aarch64 run the `ReleaseSafe` gates through
  LLVM. They are slower than ADR 0170's x86_64 figures and they finish.
- On x86_64 nothing changes: same backend, same figures.
- The guard that found this is not in the repository and should not be; what is
  in the repository is the rule it found, and
  [`bench/result/build.md`](../../bench/result/build.md) carries the table.
- `CLAUDE.md`'s "take a stuck build's CPU time before believing it is slow" has a
  fourth case now, and it is the inverse: a build with no CPU time *and no
  process* was not stuck, it was killed with the machine. Read `vm.swapusage`
  before reading anything else.
