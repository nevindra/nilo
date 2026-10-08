# A restart on save watches the binary, not the sources

**Status:** accepted
**Topic:** [docs-tooling](../design/docs-tooling.md)
**Extends:** [ADR 098](./098-a-file-is-described-by-the-descriptor-being-sent.md),
whose `staticWith(.{ .reload = true })` was the half of "reload without a
restart" that could live inside `App`; this is the other half, and it
lives in the build.
**Applies:** [ADR 077](./077-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md),
[ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 138](./138-a-test-does-not-need-the-optimiser.md).

## Context

A file that changes under a running server is served fresh since ADR 098,
and a `.zig` file that changes still needs the person to stop the server,
rebuild and start it again. The roadmap held the entry at *ready* with one
sentence of design — jetzig sums the mtimes of its source tree and rebuilds
when the sum moves, "about as much machinery as this deserves" — and one
constraint: none of it may end up in a release binary.

The question that reshaped it was asked before a line was written: **does
this eat the disk?** Zig's cache evicts nothing
([ziglang/zig#15358](https://github.com/ziglang/zig/issues/15358), closed to
[Codeberg #30193](https://codeberg.org/ziglang/zig/issues/30193) with no
eviction in 0.16.0's release notes), and a watcher that ran `zig build` on
every save would be a leak with a good excuse. So the loop was measured
before it was designed, five ways, on this machine — the table is in
[`bench/result/build.md`](../../bench/result/build.md#what-a-restart-on-save-costs-per-save)
— and two of the five rows moved the decision.

## Decision

**`nilo-dev` runs one `zig build <step> --watch` and leaves it running,
starts the server whenever the binary that build writes changes, and
watches nothing else.** It spawns two processes and reads the size and
mtime of one file every 250 ms. It imports `std` and nothing of nilo's,
ships as `nilo.artifact("nilo-dev")`, and no server links it — which is
the release-binary constraint met by construction rather than by a flag.

```zig
const dev = b.addRunArtifact(nilo.artifact("nilo-dev"));
dev.addArg("--zig");
dev.addFileArg(.zig_exe);
dev.addPassthruArgs();
dev.addDirectoryArg2(
    .{ .relative = .{ .base = .install_bin, .sub_path = exe.out_filename } },
    .{ .make_absolute = true },
);
b.step("dev", "Rebuild and restart on every save").dependOn(&dev.step);
```

The binary's path is a directory argument rather than a file one because a
file argument is an input the step hashes, and this one is written by the
build `nilo-dev` itself starts. On Zig 0.16 the same lines were four, with
`b.args` and `b.getInstallPath`, both of which 0.17 removed.

**The build system watches the sources, because it already does.** A
watcher of nilo's own would be a second reading of which files matter, kept
in step with `build.zig` by hand; `zig build --watch` reads the same graph
the build does. Watching the *output* instead of the inputs is also what
makes a failed build free: the watch prints the errors, the binary on disk
is the last one that compiled, and the server running is the one serving
it. There is no code for that case.

**And it reacts only to the files the build read, which is what makes it the back end's loop and not the repository's.** The watch marks the directories holding a step's inputs and answers to those names alone, so a front end kept beside the server is outside it: under `zig build dev-spa`, a save to `public/app.js` moved nothing in the fifteen seconds it was watched, and a save to `main.zig` had the new server listening one to two seconds later. A file the binary `@embedFile`s is inside the line, because saving it changes the binary; `build.zig`, and a `.zig` file nothing imports yet, are outside it. `bench/devloop.py` runs that probe against any dev step, so the line is a check rather than a paragraph ([`build.md`](../../bench/result/build.md#what-a-save-has-to-touch)).

**The old server is asked to stop, in a process group of its own.** SIGTERM
is what nilo drains on (ADR 077), and SIGKILL comes only after five
seconds. Each child gets a process group of its own so a Ctrl-C at the
terminal reaches `nilo-dev` alone: nilo reads a *second* signal as "stop
waiting" and exits without the drain, and the terminal's group would have
delivered one before the runner's TERM arrived. The build's group is also
what makes the compilers it keeps under it one `kill` on the way out — a
`zig build --watch` sent SIGTERM on its own leaves them running, which was
found the first time it was tried.

**A change is acted on once it has been seen twice.** Two polls with the
same stamp, 250 ms apart, before a restart, so a binary still being copied
is not started half way through.

**The first server is the current one, or none.** Before the watch starts, `nilo-dev` runs the same `zig build <step>` once to the end, without `--watch` and with `-fincremental` and every `-D` option it was given. The binary on disk is whatever the last run left, and nothing but a build can say whether it still describes the sources. Started on the first two polls, as this loop first did, it was served before the watch had rebuilt it: an application whose schema changed with the loop stopped had its SQLite file created and seeded by the old binary, one index the edit had removed included, and `listening` printed twice. A server is not a pure function of its binary, so serving a stale one for a moment is not free. When the first build compiles, the watch's first pass is a cache hit that writes nothing, so there is no restart after the start.

**When that first build fails, the stale binary is removed.** Remembering its stamp as already served does not work, and was tried: a fix that puts the sources back to the ones the old binary was built from compiles, the install step finds the file on disk already right and does not write it, the stamp never moves, and the loop waits for ever beside a build that succeeded. Removed, the first build that compiles writes it, whatever it compiles to. A Ctrl-C during that build stops it the way the loop stops the watch.

**Under `--no-incremental`, after every restart the build it replaced is deleted, and nothing else.** One save leaves
exactly one new file in the cache — `.zig-cache/o/<hash>/<exe>`, the whole
Debug binary, 27 MB for `examples/hello` and the size of the program for
anything else — and Zig never removes it. So at every start the runner
finds the directory whose copy of the binary is byte for byte the one it
just started, and at every restart it deletes the directory it found the
time before. Four saves that alternated an edit and its undo left the
cache 0.0 MB larger, with one directory in it at every step.

What makes that directory, and only that one, safe to delete is how Zig's
cache names things. There is one manifest per configuration
(`.zig-cache/h/<hash>`, the hash of the compile's options, not of its
sources), and each names exactly one output directory, the one its
current sources hash to. A rebuild of the same configuration rewrites the
manifest, so the directory it named before is named by nothing, and an
undo back to it is a miss that rebuilds into the same directory rather
than a hit on a directory that is gone. Both were tried before they were
relied on: an edit, an undo and a rebuild in a scratch project on Zig
0.17.0, where the manifest's content changed and the count of manifests
did not, and the same under a real `nilo-dev --no-incremental` session. A
plain `zig build` and the watch's rebuilds share the manifest, so the
first start's directory belongs to the same configuration as every
restart's.

A directory the session did not serve from is never touched, however its
binary is named. If the served binary is in no directory, because the
step copies or strips it on the way to `zig-out`, nothing is deleted and
the trail is kept: missing a directory costs its megabytes, deleting a
live one costs a build. A directory that still holds the bytes being
served is kept too. Deleting reads nothing but the new binary to find it,
and runs after a restart, when the build has just finished writing and is
idle. It runs only under `--no-incremental`: an incremental build patches
its one directory in place and nothing is stale. `--keep-cache` turns it
off.

**The build is incremental by default, on the self-hosted backend, and
`--no-incremental` is the way out.** Measured through `nilo-dev`, from the
save to the new string being served, five saves each, on the 2-core machine
([`build.md`](../../bench/result/build.md#what-a-save-costs-on-zig-017)):

| `zig build dev-hello`, 2 cores | Zig 0.16.0 | Zig 0.17.0 |
|---|---|---|
| a full rebuild, pruned (now `--no-incremental`) | 4.1–4.7 s | 3.6–4.5 s |
| incremental | 10.4–11.7 s, and only with `-Dllvm` | **0.56–0.70 s** |

Five to six times faster per save is the trade for 189 MB of resident
compiler per artifact the step builds, which is what a person sitting in
this loop would choose, and the cache stays flat with nothing pruned.
`--incremental`, the flag from when this was opt-in, is still accepted and
changes nothing, so a `build.zig` or a habit that passes it keeps working.
A server that dies within a second of starting is told to try
`--no-incremental`, since the release notes still list incremental
compilation's known bugs.

## What it costs

Against ADR 017's axes: nothing. Not one byte of `nilo_http` changes;
`nilo-dev` is an executable nobody imports. What it costs the machine:

- **Per save, default:** 0.56–0.70 s to a served response here on Zig
  0.17.0, and 0 MB. On 0.16.0 incremental was an LLVM emit, 4.8 s at the
  time of the table and 10.4–11.7 s when re-run beside 0.17.
- **Per save, `--no-incremental`:** one compile of the changed module,
  2.8–3.6 s here, 27 MB written to `.zig-cache` and the previous 27 MB
  deleted after the restart — a read of the new binary to compare it, and
  one `rm -rf`.
- **Resident:** the build runner and, unless `--no-incremental`, one compiler
  kept alive per artifact the step builds — 180 MB for the self-hosted
  backend, 406 MB for LLVM, measured as RSS on Zig 0.16.0; 189 MB for the
  self-hosted one on 0.17.0, where the maker beside it is 8 MB. `zig build
  examples` in this loop would keep nine, which is why the dev steps build
  one example each.
- **The runner itself:** one `stat` every 250 ms.

## Alternatives

**A watcher of nilo's own, summing mtimes, running `zig build` per change.**
The roadmap's sketch, and the first design. Rejected on the first row of
the table: it is the 23 MB row with a second copy of the file list.

**`zig build run --watch`, with the server as the Run step.** The watch
waits for every step to finish before it listens again, and a server never
finishes.

**A full rebuild as the default, with `--incremental` opt-in.** The decision
on Zig 0.16.0, where incremental was refused as the default because a
default that produced a binary that did not run was worse than one that was
slow:

| the same edit to `examples/hello`, 2 cores, Zig 0.16.0 | rebuild | `.zig-cache` per save | binary |
|---|---|---|---|
| `zig build` per save, self-hosted | 2.8 s | +23 MB | runs |
| `--watch`, self-hosted | 3.6 s | +23 MB | runs |
| `--watch -fincremental`, self-hosted, new ELF linker | 0.12 s | 0 | **does not run** |
| `--watch -fincremental`, self-hosted, old ELF linker | never finishes | 0 | not written |
| `--watch -fincremental`, LLVM + LLD | 7.4–9.4 s | 0 | runs |

The 0.12 s row's binary died at exec with `undefined symbol: main`: the new
ELF linker's incremental output did not run when libc was linked, and every
nilo server links libc through zio (`zig build-exe main.zig -lc
-fincremental` reproduced it). So the flag asked for `exe.use_llvm = true`
beside it on 0.16, and the default was the 23 MB row with the 23 MB deleted
afterwards. Zig 0.17.0 fixed the row, and the table at the top of this
decision is what moved the default: under a second against about four.

**Watching the sources as well as the binary**, so the restart could be
announced before the build finished. Nothing to announce: the server keeps
serving until there is a new one.
That is true of every save after the first, and was not of the first start, which is why the loop now builds before it serves rather than watching more.

**`dev.step.dependOn(&install.step)` in `build.zig`**, so the outer `zig build dev` builds before `nilo-dev` runs at all. Every dependent's four lines would change, one that never re-reads the guide keeps the stale start through every release, and a tree that does not compile fails `zig build dev` before the loop exists rather than waiting for the save that fixes it.

**Logging that the first server may be stale**, and starting it anyway. The database is seeded by the old schema all the same.

**Waiting for a binary newer than the moment the loop started.** A build with nothing to do does not rewrite `zig-out`, so an up-to-date tree would never start.

**A cache directory of the loop's own**, `--cache-dir .zig-cache/dev`,
pruned whole on exit. Race-free by construction, and a second copy of
everything the shared cache already holds — a cold build per machine, and
hundreds of megabytes standing where the per-save leak was 27.

**Pruning by name: every directory holding a file called what the loop
serves, but the one it just started.** The rule this loop shipped with, on
the premise that the only other build of the same binary would be a
concurrent one, which nobody runs beside their dev loop. The premise was
about the wrong thing. A build of the same binary for another target or
mode does not have to be running: the one from yesterday is still named by
its own manifest, and deleting its directory made the next build of that
configuration a cache hit on a file that was gone. `zig build examples
-Dtarget=x86_64-linux-gnu` failed `install` with `FileNotFound` after a
native `dev-hello` session, and on every run after until the cache was
rebuilt; a two-file project reproduced it on Zig 0.16.0 and 0.17.0 alike.

**Deleting the manifest with the directory**, so a pruned build of another
configuration would be a miss rather than a broken hit. Nothing in the
cache maps a directory to its manifest: the directory's name is the
manifest's hasher carried on over the input files' digests, and the
hasher's state before them is not in the manifest, only its digest, so the
name cannot be recomputed from outside the compiler. **Keying the pruning
on the configuration** fails the same way: nothing in `o/` says which
options built it. What the loop does know is which directory it served
from, and that is the whole of the rule.

## Consequences

- `dev/main.zig`: `nilo-dev`, with `--zig`, `--build`, `--incremental`,
  `--keep-cache`, `--trace`, `-D…` pass-through, and `-- <server args>`;
  `dev` in `build.zig.zon`'s `.paths` and in `shipped_roots`.
- `zig build dev-<example>` for each example, `zig build example-<name>` to
  build one, `-Dllvm` for the examples (what `--incremental` needed on
  0.16), `zig build test-dev` on `test`.
- The guide's getting-started page gains the lines; the roadmap loses
  "Reloading the server without a restart" and gains the upstream gap.
- [`bench/result/build.md`](../../bench/result/build.md) carries the table
  and the machine.
- `bench/devloop.py`: a save the build never reads must leave the server up, and a save it reads must restart it; the guide's [What a save has to touch](../guide/getting-started.md#what-triggers-a-restart) is the same line for a reader.
- The first build before the watch: `bench/devloop.py` makes `--inside` stale with the loop stopped and fails on a restart after the first start. Before, the server started and then restarted into the new binary; after, it started once and stayed up for the six seconds watched. A failed first build deletes the binary at the path the loop was given, which is a build output the loop owns while it runs.
