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
`addTest` sites (ADR 138).

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

Re-measured after ADR 138, same edit, `--summary all`. 11.65s of wall against
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
(ADR 026). The only way down is fewer refusals, which is the wrong trade.

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

## The same swap on a different machine

**Not the machine in the header.** Apple M1 Pro, 8 cores, 16 GB, macOS, Zig
0.16.0 (Homebrew `0.16.0_1`), commit `abb465a`. Recorded because the x86_64
figures above were applied here unmeasured and the result was not a slower build
but a dead machine, three times, before any output
([ADR 138](../../docs/adr/138-a-test-does-not-need-the-optimiser.md)).

The compile is `pw/pw.zig`, a leaf with no module graph, a binary emitted, the
machine otherwise quiet. Footprint is `top`'s physical footprint sampled once a
second — **not `ps` RSS**, which read 1.4 GB of a 5.3 GB process once macOS had
compressed the rest — with the compiler killed at a 4 GB cap:

| mode | backend | peak footprint | wall | outcome |
|---|---|---|---|---|
| ReleaseSafe | `-fllvm` | 290 MB | 6s | finished, 561 KB |
| ReleaseSafe | `-fno-llvm` | 4,022 MB, climbing | capped at 7s | — |
| Debug | default | 229 MB | 2s | finished; LLVM's binary ±16 bytes |
| Debug | `-fllvm` | 208 MB | 2s | finished |
| Debug | `-fno-llvm` | 4,010 MB, climbing | capped at 7s | — |

Uncapped, inside `zig build test -j1` the same day: the ReleaseSafe `pw`
compile at 5.3 GB after 40s, and the step the runner moved on to at 15 GB when
it was killed by hand. Zig's default on this architecture is LLVM in both
modes — the `Debug` default row is LLVM's binary — so the one line that did
anything was the forced `false` for ReleaseSafe, and it is now x86_64-only.

What this does to the `zig build test` figures on this machine is not yet
measured; the table above was taken to find the cause, not the cost. When it is
measured it goes here, and the first thing to check is whether
`--summary all`'s per-step peak RSS says the test compile of `http/http.zig`
(2.3 GB, seen once in passing) wants a `max_rss` claim so the runner stops
scheduling eight of them on sixteen gigabytes.

## What a dependent pays for `build.zig`

**Not the machine in the header either.** 2 cores, 7.9 GB, x86_64 Linux, Zig
0.16.0, commit `8c2d3be`, `build.zig` at 192,747 bytes. Taken because a
dependent's author guessed that a consumer's cold build carries the tooling
nilo runs on itself — `bench/`, `stress/`, `spike/`, the refusal tables — and
said so as a hunch rather than a finding.

The cost is the build runner, which is compiled from every `build.zig` in the
dependency graph and cached by content. `zig build -h` is the configure phase
and nothing else, run from `bench/dependent/`, which imports `nilo_http` and
nothing more; the control is a seven-line `build.zig` with no dependencies in
a scratch directory. Each row is the mean of three runs, and the spread was
under 0.2 s.

| | runner cached | runner rebuilt |
|---|---|---|
| `bench/dependent/` on nilo | 0.03 s, 39 MB | 4.4 s, 5.2 s CPU, 210 MB |
| seven-line `build.zig`, no deps | 0.03 s, 38 MB | 3.5 s, 4.2 s CPU, 196 MB |

The runner is rebuilt when the content of any `build.zig` in the graph
changes, which for a dependent is a nilo upgrade. **So nilo's 192 KB costs a
dependent about 0.9 s and 14 MB, once per upgrade, and nothing on any other
build.** A `touch` does not do it — the cache is by content — and a warm build
with nothing changed is 30 ms with or without nilo in the graph.

**What it changed:** the roadmap carries the number as accepted rather than as
a hunch. Splitting the file would win most of the 0.9 s once per upgrade, and
a build system in two files is not worth a second a release.

**Can it go further:** the 3.5 s floor is std's build system compiling
itself, and is not nilo's to move. The 0.9 s above it is; the lever is a
`build/` directory of `@import`ed helpers so the runner sees less of what
`bench/` and `stress/` need. Not worth pulling until something else wants the
file split.

## What a restart-on-save costs per save

**Not the machine in the header.** 2 cores, 7.9 GB, x86_64 Linux, Zig
0.16.0, commit `b99a5b4`. Taken before `nilo-dev` was designed rather than
after, because the question that decided its shape was "does this eat the
disk?" ([ADR 190](../../docs/adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)).

The edit is one string literal in `examples/hello/main.zig`, changed three
to five times in a row; the build is `zig build examples` (all nine, of which
one changed) or `example-hello`; cache is `du` of `.zig-cache` after each
save, and "binary" is whether `zig-out/bin/example-hello` then runs and
serves the new string.

| | rebuild | `.zig-cache` per save | binary |
|---|---|---|---|
| `zig build` per save, self-hosted | 2.7–2.9 s | +23 MB | runs |
| `--watch`, self-hosted | 3.6–3.7 s | +23 MB | runs |
| `--watch -fincremental`, self-hosted, new ELF linker | 0.11–0.12 s | 0 | `undefined symbol: main` at exec |
| `--watch -fincremental`, self-hosted, `use_new_linker = false` | none in 60 s; 3m52s CPU and counting | 0 | not rewritten |
| `--watch -fincremental`, `use_llvm = true` | 7.4–9.4 s | 0 | runs |

Through `nilo-dev` the LLVM row is 4.8 s from the save to the new string
being served, because the restart happens on the first of two writes Zig
makes to the installed binary per change — a 27 MB one and, five seconds
later, an 8 MB one — and both carry the change.

Resident memory, RSS: the build runner and a compiler per artifact under
`-fincremental` — 180 MB each for the self-hosted backend (1.78 GB for the
nine examples), 406 MB for LLVM. Plain `--watch` keeps 275 MB over two
processes.

The third row was first read as the answer and quoted in a session as
"0.12 s and zero bytes" before anybody ran the binary. The five-line
reproduction is `zig build-exe main.zig -lc -fincremental` on 0.16.0, and
the same file without `-lc`, or with `-fllvm`, runs. Every nilo server
links libc through zio.

One save, listed file by file: exactly one new file in the cache,
`.zig-cache/o/<hash>/example-hello` at 27.2 MB (the 23 MB above is `du`'s
block count), and nothing else grows — the manifest under `h/` is rewritten
in place. Deleting a previous build's directory and reverting the source to
it rebuilt into the same directory, so the runner deletes them after each
restart: an edit, its undo, the edit and the undo again left the cache
0.0 MB larger, with one such directory at every step.

**What it changed:** the runner watches the build's output rather than the
sources and runs one `zig build --watch` rather than one per change, and
deletes the previous build's directory after each restart; `--incremental`
is a flag rather than the default, and asks for LLVM; the roadmap carries
the third row as an upstream gap.

**Can it go further:** the 0.12 s row is the number, and it is Zig's to
reach — the new ELF linker learning libc, or incremental state surviving
under the old one. The 27 MB written per save on the default path is the
Debug binary and is Zig's to shrink; what nilo could do about it, delete
it afterwards, it does. On this machine the LLVM row is bounded by
LLVM emit on two cores and should divide by the core count elsewhere; that
is a guess until somebody runs it on the sixteen-core box in the header.

## What a save costs on Zig 0.17

**Not the machine in the header.** 2 cores (Xeon Platinum 8255C, KVM), 7.9
GB, x86_64 Linux 6.8, against the tree at `b7acd22`: Zig 0.16.0 on
`git archive` of that commit, and Zig 0.17.0 on the same commit ported, run
the same afternoon. Taken during the port, to see whether 0.17 had fixed
the incremental row of [the table above](#what-a-restart-on-save-costs-per-save).

The measure is the whole loop rather than the compile: `zig build
dev-hello` running, then a script rewrites the string
`examples/hello/main.zig` returns and polls `GET /` every 50 ms until the
new string comes back. Five saves in a row, 3 s apart, the first one after
the loop has been up for ten seconds. So a figure is compile, install, the
two polls `nilo-dev` waits for, the old server's drain (about 200 ms) and
the new one's start.

| `zig build dev-hello`, save to new string served | Zig 0.16.0 | Zig 0.17.0 |
|---|---|---|
| default (self-hosted, pruned) | 4.07–4.67 s | 3.61–4.49 s |
| `-- --incremental` | 10.4–11.65 s (with `-Dllvm`; without it the binary does not run) | **0.56–0.70 s** (no `-Dllvm`), three runs of five |

Resident under `--incremental` on 0.17.0: the compiler 189 MB RSS, the
maker 8 MB, `nilo-dev` 5 MB, the server 8 MB.

`zig build-exe m.zig -lc` on a five-line program, the reproduction from the
table above, links and runs on 0.17.0 natively. It also did on 0.16.0 on
this host when tried the same afternoon, so the `crt1.o` relocation error
CLAUDE.md describes was not reproduced here by a small program either way.

**What it changed:** `nilo-dev` builds incrementally by default, with
`--no-incremental` as the way back to the pruned rebuild
([ADR 190](../../docs/adr/190-a-restart-on-save-watches-the-binary-not-the-sources.md)),
and nothing asks for LLVM to get it.

**Can it go further:** the floor under 0.56 s is mostly not the compiler:
a stamp seen twice on 250 ms polls before a restart, and a 200 ms drain,
are `nilo-dev`'s, and both are there on purpose (ADR 190). The default row is one compile of the
changed module and has not moved between releases by more than its spread.

## What a save has to touch

16 cores, x86_64 Linux, Zig 0.16.0, commit `b012502`, Debug, self-hosted backend, cache warm, `-Dtarget=x86_64-linux-gnu` on both `zig build`s because of the host's glibc. The question was whether the dev loop is the back end's or the repository's: a project keeping a front end beside its server should be able to save under the front end without the server going away. ADR 190 says the loop watches the binary, and the guide had a sentence saying `zig build dev` could watch a bundler's directory, so the two were put to a save each rather than argued.

The loop is `zig build dev-spa`, whose `public/` is served from disk by `staticWith`. Each probe appends a line to one file and reads what the runner and the build print: `nilo-dev` says when it restarts, `--trace` prints the binary's size and mtime every 250 ms, and the build prints a `Build Summary` when a step ran, so a stamp that stood still with no summary under it for fifteen seconds is a save that moved nothing.

| the file saved | what it is to the build | rebuilt | restarted |
|---|---|---|---|
| `examples/spa/public/app.js` | served from disk, never read by the build | no, in 15 s | no |
| `examples/spa/main.zig` | the root | yes | yes, listening 1–2 s after the save |
| `http/ctx.zig` | nilo's own, imported | yes | yes |
| `build.zig` | the build's own script | no, in 15 s | no |
| `examples/hello/orphan.zig`, new | beside the root, imported by nothing | no, in 15 s | no |
| `public/app.js` in a dependent whose `build.zig` has `installDirectory("public")` and the guide's `dev` step | read by the install step, never by the compiler | the copy step ran, 5/5, in under a second | no |

The first row is the one the question was about, and the last is the same save in the shape a project with a front end would give it: the build reacts, because a step of its own reads the directory, and the server does not, because what `nilo-dev` watches is the binary. The mechanism is why the first holds rather than luck: `std.Build.Watch` on Linux marks with fanotify only the directories that hold a step's inputs, and on an event looks the file's name up in that directory's table, so a save to a name no step reads marks nothing dirty. The last two rows follow from the same table. `build.zig` is not an input of any step, so a change there is a stop and a start; the dev loop does not, and could not, reconfigure.

**What it changed:** the sentence in the static-files guide and the row in `decided.md` that offered `zig build dev` as a way to restart on a bundle were wrong and were corrected; the guide gained [What a save has to touch](../../docs/guide/getting-started.md#what-triggers-a-restart), and `bench/devloop.py` runs the first two rows against any dev step so the line is a check. It ran clean here in 25 s against `dev-spa`, and again through `--cmd` against the dependent in the last row; a run with the root as the "outside" file fails the way it should. Building that dependent is also what found that the guide's `dev` step dropped `b.args`, so the `-- --incremental` on the same page never reached the runner; the guide's snippet forwards it now.

**Can it go further:** it does not need to. A second path for `nilo-dev` to watch would let a bundle restart the server, and it is the second reading of which files matter that the ADR rejected; the bundler's own dev server with a proxy is the loop for the front end. What the table does not cover is a front end that reaches the binary some way other than `@embedFile`, a generated `.zig` listing the bundle's names say, which would be inside the line by construction and is untested because nothing here does it.

## What SQLite costs a cold build

16 cores (AMD Ryzen 7 9700X), x86_64 Linux, Zig 0.16.0, commit `0635e31` against the working tree that became [ADR 249](../../docs/adr/249-sqlite-is-compiled-releasefast-whatever-the-program-is.md), `-Dtarget=x86_64-linux-gnu`. The question came from photon, whose first `ReleaseSafe` build with `nilo_sql` spent 48 seconds and a gigabyte compiling the amalgamation. Wall and CPU from `wait4` around the whole process, peak RSS its `ru_maxrss`, every cache cold.

The amalgamation alone, `zig build-obj -O <mode> lib/sqlite3.c -cflags -std=c99`, fresh local and global caches:

| mode | wall | CPU | peak RSS | object |
|---|---|---|---|---|
| Debug | 5.1 s | 5.0 s | 746 MB | 18,576,368 B |
| `ReleaseSafe` | 34.3 s | 33.6 s | 1,034 MB | 8,030,024 B |
| `ReleaseFast` | 19.8 s | 19.4 s | 704 MB | 7,762,128 B |

`ReleaseSafe` is the slow one because it is `-O2` with the undefined-behaviour sanitizer, which `ReleaseFast` does not carry and Debug carries at `-O0`.

Through a program, `zig build example-sqlite` with a fresh `--cache-dir` (the global cache warm, so libc is not in it), before and after interleaved, two runs a side:

| | before | after |
|---|---|---|
| Debug, cold | 9.1 s, 8.8 s | 22.1 s, 23.5 s |
| then `ReleaseSafe`, same cache | 69.8 s, 71.5 s | 31.2 s, 35.2 s |
| `ReleaseSafe` alone, cold | 71.9 s, 72.6 s | 57.2 s, 57.4 s |
| peak RSS, `ReleaseSafe` | 1,082 MB, 1,096 MB | 874 MB, 864 MB |

CPU is within a second of wall on every `ReleaseSafe` row, so the C compile and the Zig compile ran one after the other, not side by side.

**What it changed:** SQLite's C is compiled `ReleaseFast` whatever the program is (ADR 249), which trades 14 seconds on a cold Debug build for 15 on a cold `ReleaseSafe` one, 25 on a cold build in both modes, and about 200 MB of peak memory.

**Can it go further:** the `ReleaseSafe` row after the change is the Zig program, not SQLite, and is the compiler's. The 20 seconds left are clang at `-O2` on one 9 MB file and cannot be split; what could move them is a cache that outlives the checkout, which a CI runner keeping `~/.cache/zig` and the project's `.zig-cache` already has.


## Where `zig build test` waits on Zig 0.17

16 cores, 30 GB, x86_64 Linux, Zig 0.17.0, `-Dtarget=x86_64-linux-gnu` (CLAUDE.md), measured at `c6d6b20` with commits up to `d0b1f8e` landing during the session, none of them in `build.zig` or the suite's slow tests. Wall and CPU from bash's `time` around the whole `zig build`, after one comment appended to `http/router.zig`; a timeline from `ps` every two seconds; per-test time from the test binary run by hand, its `N/M name...OK` lines stamped as they arrive.

| | wall | CPU |
|---|---|---|
| `test`, nothing changed | 4.3 s | 48 s |
| `refusals`, nothing changed | 2.8 s | 27 s |
| `test`, one edit under `http/` | 133 s | 375 s |
| `test-all`, one edit under `http/` | 108 s | 525 s |

**The refusals are not the wait.** After the edit, the 303 refusals on `test` add up to about 50 s of step time and the 225 snippets to about 140 s, spread over sixteen cores: 3 to 4 s and about 9 s of wall, beside the run rather than in front of it. The timeline has two phases and nothing else: compilers until 45 s, then one process, the `http/` suite running, until 98 s.

**The compile is 33 s of semantic analysis on one core.** The suite's own `zig test` line, taken from `--verbose` and run alone after the same edit, is 32.9 s and 33.1 s of wall against 34.7 s of CPU; with `-fno-emit-bin` it is 32.2 s. Code generation and the link are under a second, so neither LLVM nor the linker is in it: this is comptime and Sema over some 1,575 tests (1,572 at the start, 1,577 once the landed commits were in). The `ReleaseSafe` suite, on the same self-hosted backend, was 42 s to 45 s inside a whole `test-all`, not timed alone.

**The run was 62 s, and 25 of it was one test.** "a client with a window of one byte that answers each byte with two updates is a flood" called `pump(…, 50)`, which returns only after 50 ms of quiet, once per byte; `pumpSome`, which exists for exactly this, takes it to 0.20 s. What is left, 36 s, is 36 live tests whose time is real timers (deadlines, idle limits, keep-alive comments), `h2pipe_live` 10 s, `live` 8.5 s, `grpc_tls_live` 4.7 s, `grpc_live` 3.4 s and `tls_live` 2.9 s, run one after another by Zig's test runner; the other 1,540 tests are under 10 s together.

**Two binaries were built only to see that they still compile, through LLVM.** `nilo-profile` (`ReleaseFast`) and `nilo-fuzz` (`ReleaseSafe`) were 22 s and 27 s on every `test`, competing with the suite's compile for cores. A Compile step whose binary nobody asks for is passed `-fno-emit-bin`, so `test` now depends on a second step over the same root module: 0.6 s and 3 s, the same analysis, no backend.

After both, the same afternoon, run after the befores rather than interleaved with them; the margins are far outside the spread of the repeats:

| | before | after |
|---|---|---|
| `test`, one edit under `http/` | 133 s | 75 s, 77 s |
| `test-all`, one edit under `http/` | 108 s | 88 s, 97 s |

`test` is now the suite's compile and its run back to back, 39 s and 36 s; `test-all` is the `ReleaseSafe` compile, 42 s, then the same run.

**`-fincremental` works here on 0.17, and it takes the compile off the loop.** It died with `undefined symbol: main` on 0.16 (ADR 138). On 0.17, `zig build test-http -fincremental --watch` (the suite alone, a step added for this) builds once in 54 s with a 750 MB resident compiler, and then three edits inside `Router.deinit`, each a new value so none is a cache hit, reached the end of the run 35.0 s to 35.2 s after the save against a 35 s run: the compile is under a second where it was 33. All 1,577 tests pass in the incremental binary. Not tried under `test` itself, which is 568 compile steps, and a resident compiler each is not memory this machine has.

**What it changed:** the one-byte flood test uses `pumpSome`; `test` checks the profile and the fuzzer rather than building them; `test-http` exists for the incremental loop, and ADR 138 says `-fincremental` is the loop on 0.17.

**Can it go further:** yes, and each lever is named with what it would cost. The run's 36 s is timers: a `-Dtest-filter` on `test-http` would make the incremental loop seconds for the file being worked on, and splitting the live tests into a binary of their own would run them beside the rest at the price of a second 33 s analysis of the whole framework. The 33 s of Sema is the real floor of a cold `test`, and nobody has looked inside it: `--time-report` against the suite, read through its web UI, is the run that would say which comptime is spending it. One `park-check` failed in four runs, "1 of 48 idle connections hold a second page of stack", on an unchanged loop; the other three and both `test-all` runs passed.

### The run, test by test

The same machine, the next day, at `d0b1f8e` plus the changes above; the suite's binary run by hand, each test timed from its line. 1,504 of the 1,577 tests took 1.2 s together and 73 took 34.4 s, and every one of the 73 was read for what its time was spent on.

**Forty of them were a fifth of a second of the Engine's, not of the test.** They stopped at 0.201, 0.408, 0.601 and 0.802 s, multiples of `accept_poll_ms`: `serve` saw a stop only at its next 200 ms look, and every test that starts a server stops it. With the poll set to 5 ms for one run, the suite was 27.9 s against 35.8; with a doorbell `Stop.request` rings instead (ADR 200), it was 27.8 s. A test now holds that `listen()` returns well inside a poll after `shutdown()`; without the doorbell it fails.

**Two were waiting longer than their claim needed.** "a second TLS record that arrived with the first is answered" ran twenty TLS handshakes, 95 ms each in Debug, for a condition the client creates on every one by sending both records in one write: three now, 0.30 s against 2.0. "an event stream handed to an HTTP/2 connection is sent comments while it is quiet" waited 2.6 s to count a second and third keep-alive comment, which `h2conn`'s own keep-alive test already counts; it waits 1.4 s for one now, 2.07 s against 3.4.

**The rest are what they test.** A write limit passed three times, a body grace that has to run out, a TLS record held while a post arrives 300 ms later, a block warning that has to fire: each waits a multiple of the limit it is about, and shortening the limit trades a margin on a busy machine for a fraction of a second. They were left alone. Argon2 at its default cost in Debug is 0.65 s over two tests, and a 2,000-input property test 1.3 s.

| | wall |
|---|---|
| the suite's run, before | 35.8 s |
| after, three runs | 25.0 s, 25.1 s, 25.2 s |
| `test`, one edit under `http/` | 69 s (75 s and 77 s the day before) |
| `test-all`, one edit under `http/` | 76 s (88 s and 97 s the day before) |

**`park-check` fails about one run in six, before this change and after it**: 10 of 60 with the doorbell and 11 of 60 without, interleaved, the program run alone. That `test` run was one of them. The entry is in `docs/todo.md`.
