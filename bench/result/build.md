# What the build costs

What `zig build test` and `zig build test-all` spend, and on what. The other
files here measure the program; this one measures waiting for it.

## The machine

16 cores, x86_64 Linux, Zig 0.16.0, commit `b302549`. Every wall figure is
`/usr/bin/time` around the whole `zig build` invocation, cache warm unless a
row says otherwise. CPU is user+sys, so a number far above the wall figure
means the work parallelised and a number close to it means one step ran alone.

## Where the time was, before anything changed

`zig build test`, warm, one comment appended to `http/router.zig`:

| | wall | CPU |
|---|---|---|
| nothing changed at all | 2.90s | 24s |
| one edit under `http/` | 30.6s, 31.7s | 110s, 126s |
| caches invalidated | 38.5s | 296s |

110s of CPU finishing in 30.6s of wall on sixteen cores is the whole finding.
Per step, on the edit run:

```
48.0s CPU    66 steps   snippets
31.0s CPU     1 step    test-fetch-engine   <- one compile, thirty seconds
15.9s CPU   109 steps   refusals
 6.3s CPU    13 steps   layering
```

Everything except `test-fetch-engine` runs in parallel and hides behind it. The
run is as long as its longest single compilation, and that compilation was the
`ReleaseSafe` half of `test-fetch-engine`.

## What the thirty seconds were

`zig build test-fetch-engine --time-report --webui=127.0.0.1:9977`, read in a
browser. Note that `--time-report` prints nothing to the terminal: it stands up
a web server and waits, which from a terminal is indistinguishable from a hang.
`ps -o etime,cputime -C zig` says which it is.

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

94.1% LLVM. Inside it: 24.300s pass execution, 1.753s instruction selection,
0.967s analysis, 0.453s register allocation. The pass names were lost to a
truncated print, and it did not matter: Zig exposes no switch for an individual
LLVM pass, so the only lever is whether LLVM runs at all.

Files discovered by that one compilation: 712. Analysed: 296.

## What changed the decision

`.use_llvm = false` on the `ReleaseSafe` test builds, at all fourteen
`addTest` sites (ADR 0170).

| | LLVM | self-hosted |
|---|---|---|
| `test`, one edit under `http/` | 30.6s | 9.8s, 11.6s |
| `test-all`, one edit under `http/` | 65.9s | 12.5s |
| `test-all`, caches invalidated | 65.9s | 27.9s |
| `test`, nothing changed | 2.90s | 2.62s |
| `test-all` CPU, one edit | 387s | 135s |

Two independent measurements agree on the size of it. `--time-report` puts the
non-LLVM part of that compilation at 1.637s; timing the same compilation with
LLVM off put it at 1s in the build summary.

The gate reports `382/382 steps succeeded; 2870/3052 tests passed (182
skipped)` through either backend, identically. That was checked on purpose,
because a backend that dropped tests would present as a fast one.

## What was tried and did not work

**`-fincremental`.** Only available on the self-hosted backend, so the swap
should have unlocked it. On Zig 0.16 it produced binaries that would not run:
thirteen test executables died with `undefined symbol: main`, exit 127. Wall
was 11.1s and 12.2s, and meaningless. Retry on a later Zig.

**`zig build --time-report` from a terminal.** Ten minutes elapsed against one
second of CPU, which reads as a deadlock and is not one. See above.

## Where the time is now

Re-measured after ADR 0170, same edit, `--summary all`. 11.65s of wall against
84.6s of CPU, and **no single step is longer than 1.00s any more.** The shape
of the problem changed: it was one compilation running alone, and now it is a
lot of small ones against sixteen cores.

```
49.7s CPU    66 steps   snippets            longest 1.00s
17.5s CPU   109 steps   refusals            longest 0.34s
 7.1s CPU    13 steps   layering            longest 1.00s
 2.0s CPU     2 steps   test-fetch-engine   longest 1.00s
 2.7s CPU    27 steps   the other module gates
```

## Can it go further

About four seconds, and the levers are ranked by what they cost you rather than
by what they save.

**`zig build test --watch`, and it is free.** Three rebuilds after an edit under
`http/`: 9.33s, 9.48s, 10.61s, against 11.33s mean for the same edit typed
fresh. Roughly 2s, all of it process startup and cache-manifest reading, with
no change to any file.

**Batching `snippets` per page is worth 2.8s to 4.8s, and that is a ceiling
rather than an estimate.** Three interleaved pairs, snippets on the `test` step
against snippets detached from it:

| pair | with | without | delta |
|---|---|---|---|
| 1 | 10.76s | 7.93s | 2.83s |
| 2 | 11.31s | 6.51s | 4.80s |
| 3 | 11.92s | 8.34s | 3.58s |

The margin is wider than a single figure can honestly carry, so it is a band.
Note that detaching them entirely is the *upper* bound: batching 66 objects
into 9 gets some of that back, not all of it. The obstacle is that a page's
snippet sources are cumulative, so snippet N already contains blocks 1..N-1
(`declared` and `shapes` in `Snippets.collect`). Batching is a rewrite of that
generator, not a concatenation, and every body block needs a wrapper name of
its own.

Also worth correcting while here: the comment at `Snippets.pages` says a warm
run is ~30ms each. That holds only when nothing a snippet imports has moved.
After an edit under `http/` all 66 re-analyse, and it was 727ms each.

**`refusals`, 17.5s of CPU and the whole of the 2.6s floor.** These cannot
cache, because the compiler keeps nothing from a compilation that failed
(ADR 0027). The only way down is fewer refusals, which is the wrong trade.

**`layering`, 7.1s of CPU.** 8% of the total, longest step 1.00s. Nothing
measured suggests it is worth opening.

So the realistic floor for `zig build test` after an edit is around 7s, and
2.6s when nothing changed. Below that, the remaining time is not waste: it is
four gates that each have an ADR arguing they belong on the loop.

## Re-measured at `a52e958`, after 4,418 lines landed

Everything above was taken at `b302549`. Rebasing onto `a52e958` added eight
refusals and a great deal of `http/` and `sql/`, so the whole table moved. Two
interleaved pairs, same edit under `http/`:

| pair | LLVM | self-hosted |
|---|---|---|
| 1 | 45.87s | 16.34s |
| 2 | 35.92s | 14.54s |

Three more self-hosted runs the same day came out 12.79s, 13.23s and 18.51s, so
call it **13s to 18s against 36s to 46s**. The ratio survived the growth; the
absolutes did not, and the spread on both sides is wide enough that a single
figure would be dishonest. A no-change run is 4.27s.

`zig build test-all` on the merged tree: 14.13s, 99.9s of CPU, and
`396/396 steps succeeded; 2938/3120 tests passed (182 skipped)`.

## `--watch` is a convenience and not a speed-up

Worth recording because it looked like a win and was not, and because the next
person will otherwise measure it again.

Two runs of `--watch` at `b302549` came out 9.33s, 9.48s and 10.61s against an
11.33s mean for the same edit typed fresh, which reads as roughly 2s saved.
Interleaved at `a52e958`, alternating one fresh run with one watch rebuild, it
loses every round:

| round | typed fresh | `--watch` |
|---|---|---|
| 1 | 12.79s | 14.94s |
| 2 | 13.23s | 17.61s |
| 3 | 18.51s | 19.07s |

The fresh column alone spans 5.7s, so the honest reading is **no measurable
difference**, not that watch is slower. The first measurement was two
un-interleaved runs against a remembered number, which is exactly the mistake
this directory's own rules warn about, made by somebody who had just written
them down.

Keep `--watch` for what it actually gives: not retyping the command, and a
rebuild starting the moment a file is saved. Do not sell it as faster.
