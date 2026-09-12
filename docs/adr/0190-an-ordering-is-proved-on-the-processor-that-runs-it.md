# An ordering is proved on the processor that runs it

[ADR 0188](./0188-a-lookup-asks-the-cursor-afterwards-instead-of-taking-a-lock.md)
took the lock off a `nilo_cache` lookup and replaced it with a proof: copy the
value out, read the ring's cursor afterwards, and a cursor that has not passed
the entry means nothing was writing it. The ADR lists every ordering the proof
rests on and says of the first one: *"Not for the processor — x86 would not
reorder two stores — but for the compiler."*

That sentence is true, and it is the bug. It argues about one processor. The
first time the suite ran on another, `test "a lookup that holds no lock never
hands back a value that is not the key's"` — the test ADR 0188 wrote so this
could not happen — reported one to three wrong answers per run, on an Apple M1
Pro, in five of nine runs.

## What the orderings actually say to the hardware

C11's orderings are promises about *one direction* each, and `seq_cst` on a
single load or store adds nothing in the other:

- A `seq_cst` **load** is an acquire: nothing after it moves before it. The
  copy a lookup does is *before* it, and an acquire does not pin what came
  before. So the bytes can be read after the cursor is, and the lookup checks a
  cursor that has not yet moved against a value that has already been
  overwritten.
- A `seq_cst` **store** is a release: nothing before it moves after it. The
  `memcpy` a `put` does is *after* it, and a release does not pin what comes
  after. So the bytes can land before the cursor that announces them, and a
  lookup can copy half of one entry and half of the next while the cursor
  still says nobody has started.

x86 forbids both on its own: it does not reorder loads against loads or stores
against stores, so the compiler was the only thing the orderings had to hold,
and they held it. aarch64 forbids neither. Every word of ADR 0188 was checked
on the processor that could not exhibit the bug.

## What was measured

The harness is `bench/cache_bench.zig`, and the numbers are in [`bench/result/cache.md`](../../bench/result/cache.md). Three
variants, each a separate `ReleaseFast` binary, run interleaved for three
rounds at one and eight threads on the M1 Pro:

| | correct on aarch64 | 1 thread | 8 threads, reads |
|---|---|---|---|
| as shipped | **no** (5 of 9 runs wrong) | — | — |
| both sides a `seq_cst` read-modify-write | yes (0 of 9) | inside the spread | **−30% to −33%** |
| reader `dmb ishld`, writer `swap` | yes (0 of 8) | inside the spread | inside the spread |

The read-modify-write is the portable answer and it is the one ADR 0188
already rejected by measurement on x86, for the same reason it loses here:
every reader writes the cursor's cache line, and eight of them pass it round.
The fence is a load-load barrier and nothing else — every load before it
completes before any load after it — which is precisely the sentence the
reader's proof was missing and not one word more.

## Decision

- `Region.settled`, the reader's second look at the cursor, issues `dmb ishld`
  on aarch64 before the load. On x86 the line compiles to nothing.
- `Region.reserve`, the writer's move of the cursor, is a `swap` everywhere but
  x86_64, where it stays a store. A read-modify-write is acquire and release at
  once, so the `memcpy` after it cannot land first. It is under the shard's
  lock, so the line is not contended, and `put_flat` did not move.
- x86 is byte-for-byte what ADR 0188 measured. Its figures stand.

## Rejected

**The read-modify-write on both sides.** Correct, portable, and a third of the
read throughput at eight threads, for the reason above.

**A fence on the writer too.** `dmb ish` after the store would work and is the
symmetric answer. The swap was measured and the fence was not, and the swap
needs no inline assembly; a second asm line for a path that holds a lock anyway
buys nothing that is known.

**Gating the whole lock-free path to x86 and taking the lock elsewhere.** A
working cache on aarch64 at ADR 0188's pre-change speed. It leaves the module
with two concurrency designs, one of which nobody runs the benchmark against,
and the fence costs nothing measurable — so this is the worse shape with no
number in its favour.

**Relying on `seq_cst` meaning a full barrier.** LLVM emits it that way on
x86 — `xchg` for a store, plain `mov` for a load — and as `ldar`/`stlr` on
aarch64, which are acquire and release and not barriers. The language never
promised more than it delivers here; the ADR read the x86 assembly and called
it the model.

## Consequences

- `zig build test` is green on an aarch64 machine for the first time. Every
  test under `cache/` passes five of five runs with the change and fails three
  of three without it.
- A proof about memory ordering carries the architecture it was argued on, the
  way a benchmark carries its machine. The place to check is the *other*
  direction of every `seq_cst`: what it does not pin is where the next one of
  these is.
- Inline assembly in a tool module, for the first time. One instruction,
  behind a `comptime` arch check, named for the sentence it supplies. The
  alternative that needs none costs a third of the throughput, and that is a
  trade this repository writes down rather than avoids (ADR 0018).
