# A hash asks for the pages it walks

[ADR 0048](./0048-a-password-hash-is-gated-because-forgetting-is-silent.md)
shipped `nilo_pw` and wrote down what one hash costs: 13.3 ms and 19,922,944
bytes, one allocation, exactly. This decision is about **where those bytes come
from**, which turns out to be a fifth of the time — and about three things in
that module that were true of the default Cost and of nothing else.

## What the measurements said

Ryzen 9700X, Zig 0.16, `ReleaseFast`, argon2id at `Cost.default`, through the
module as it ships:

| the 19 MiB comes from | one hash |
|---|---|
| `std.heap.DebugAllocator` | 13.6 ms |
| `std.heap.page_allocator` | 13.7 ms |
| `std.heap.smp_allocator` | 13.7 ms |
| **`pw.huge_pages`** | **11.0 ms** |

**The 2.6 ms is the faulting-in, not the hashing.** Nineteen megabytes out of
an ordinary allocator is 4,864 pages of 4 KiB, and argon2's first pass writes
every one of them: allocating that and touching each page, with no hashing at
all, measures **2.2 ms** on its own. Asked for with `MADV_HUGEPAGE` it is ten
faults instead of 4,864.

Where the rest of the difference is *not* is worth as much as where it is:

| the same hash | |
|---|---|
| fresh mapping, 4 KiB pages | 12.5 ms |
| fresh mapping, `MADV_HUGEPAGE` | 10.4 ms |
| a mapping kept warm and re-used, 4 KiB pages | 10.5 ms |
| a mapping kept warm and re-used, huge pages | 10.2 ms |

A mapping that is never given back is **no faster than a fresh huge-page one**.
Two megabytes of translation instead of four kilobytes is worth about 0.3 ms;
everything else on the table is the page faults. That is the whole argument
against a pool, and it was measured before the pool was not written.

Under contention, where the Gate holds it to eight (ADR 0048), mean time per
hash:

| at once | ordinary pages | huge pages | |
|---|---|---|---|
| 1 | 13.6 ms | 11.0 ms | −19% |
| 4 | 18.3 ms | 15.3 ms | −16% |
| 8 | 25.4 ms | 23.3 ms | −8% |
| 16 | 50.3 ms | 47.8 ms | −4% |

The gain narrows as the memory bus saturates, which is the same reason ADR
0048's table stops paying after 16. **The band it helps most in is the band the
Gate keeps the server in.**

## What was decided

**`pw.huge_pages` is an allocator, and naming it is the caller's.** It is
`mmap`, one `madvise`, `munmap` — 60 lines in `pw/pages.zig` — and anything
below 2 MiB goes to `std.heap.page_allocator` unchanged, so it stays an
allocator rather than a trapdoor. The memory is handed back at the end of every
hash: **nothing is held between them**, which is what separates this from the
pool the table above rules out.

```zig
const stored = try c.hashPassword(pw.huge_pages, form.password);
```

**`verifyWith` takes the Cost, because the no-account path is timed against
it.** ADR 0048 says `verify(null, …)` "costs exactly what an account costs".
That was true at the default Cost and false at every other one: the decoy hash
was always `.default`, so a deployment storing 46 MiB hashes answered "no such
account" in 13 ms and "wrong password" in 30. **The optional closed the early
return and left the stopwatch open.** `verify` still means `.default`; a
deployment that hashes at anything else passes its Cost to `verifyWith` and the
two paths are the same work again.

**`needsRehash` reads the parameters against the Cost in force**, which closes
the roadmap gap of the same name: the plaintext is in hand exactly once, at the
sign-in that just succeeded, and that is the only moment a row can be written
forward. Weaker means fewer kibibytes, fewer passes, a shorter salt or a
shorter digest. Lanes are not in it — a hash somebody else's library made at
`p = 4` is the same work as one at `p = 1`, and rewriting every row for it
would be churn wearing an upgrade's clothes.

**A Cost with more lanes than memory is a Refusal.** Argon2 gives every lane
four segments of two blocks, so `.lanes` above `.memory_kib / 8` is a hash that
cannot be computed — and `hashWith` answered that with `unreachable`, which is
a panic in Debug and worse in `ReleaseFast`. It is the third row in the `pw`
refusals table, and with it the `unreachable` is sound: every parameter argon2
rejects is now refused while compiling.

**`hash` and `hashWith` return `error{OutOfMemory}`**, not the two-member
`Error`. `NotAHash` is something only a stored string can be, so a caller that
hashes had an arm to write that could never run.

## Why not the alternatives

**A pool of warm buffers behind the Gate.** Eight permits, eight 19 MiB
mappings kept mapped, no `mmap` on the hot path at all. The table above is why
not: a kept mapping is 10.5 ms and a fresh huge-page one is 10.4, so the pool
buys **nothing** for 152 MiB of resident memory — 7.3× what 10,000 idle
connections cost, and the exact number ADR 0048 refused to let 32 concurrent
hashes have.

**`MAP_POPULATE`.** Pre-faults the whole mapping in one syscall, needs no
kernel setting and cannot stall on compaction: 11.9 ms, about half the win. It
is the fallback to reach for if huge pages ever have to be given up, and it is
written down here so that the number does not have to be measured twice.

**Make it what `Ctx.hashPassword` uses when the caller says nothing.** The
allocator is an argument precisely so that 19 MiB is visible at the call site
(ADR 0048), and quietly routing it somewhere else would make that argument a
decoration. There is also a cost to disclose rather than hide: with
`/sys/kernel/mm/transparent_hugepage/defrag` set to anything but `defer`, a
fault that has to compact memory to find a huge page waits for it, and that
wait lands on a sign-in. Opt-in with the trade written down beats a default
that is faster on a quiet machine.

**Vendor a faster argon2.** `std`'s permutation is scalar — `blamkaGeneric`
does sixteen words one at a time. Written as four `@Vector(4, u64)` lanes,
which is the shape the reference implementation has used since 2015, the same
hash is **11.19 ms** instead of 13.78, and **8.98 ms** out of huge pages: a
third off, byte-for-byte identical at t = 1/2/3, m = 8/19456/64 KiB, p = 1/4.
It is refused here anyway. nilo does not own an argon2 — it owns the decision
to use `std`'s (ADR 0048 refused shipping the PHC encoder for the same reason),
and a copy of somebody else's crypto in `pw/` is a copy to keep in step with
every fix upstream makes forever. **The patch belongs in `std`, and the
measurement is recorded here so that whoever sends it does not have to redo
it.**

**A second function for the no-account case.** Still no. ADR 0048's argument
holds and this decision narrows it: the optional is what makes the fast wrong
version unwritable, and `verifyWith` only makes the slow right version cost the
right amount.

**A runtime Cost for `needsRehash`.** It is `comptime` for the reason
`hashWith`'s is: the Cost an application uses is chosen once, and a comparison
against a runtime one would be a comparison nothing checks the floor of.

## What it costs

**Allocations per request: unchanged.** Nothing here is on the request path.

**Memory per idle connection: unchanged.** 8,767 bytes. Nothing is held
between hashes — the mapping goes back to the kernel at the end of the call,
which is the property that made the pool refusable.

**Throughput and p99: −19% on a hash uncontended, −8% at eight at once, and
nothing at all for a request that does not hash.**

**Binary size: 0 bytes for a project that never signs anybody in.** Measured
rather than asserted: a stripped `ReleaseFast` build of the benchmark server
before and after this change is the same file, MD5 for MD5. A program that does
hash pays **+160 bytes** of text for the module changing under it, and **+820**
if it uses all three of `huge_pages`, `verifyWith` and `needsRehash` — against
the 152 KB that argon2id and blake2b already cost it.

## Consequences

**A hash's memory now goes back to the kernel rather than to the next
allocation.** Argon2 does not wipe its blocks, so out of a recycling allocator
the bytes a password was mixed into are whatever asks next. `munmap` is not why
this file exists, but it is a property worth knowing it has.

**`Cost.floor_memory_kib` still only checks memory.** OWASP's weakest published
configuration is 7 MiB *and five passes*, and `.{ .memory_kib = 7 * 1024,
.passes = 1 }` is a quarter of that work and compiles. A floor on
`memory_kib * passes` would catch it — and would refuse this repository's own
test Cost, which is how the suite affords to run in two optimize modes. Left
as it is, deliberately, and written down here so that the half-check is a known
one rather than a discovered one.

**A password over 4 GiB is still `unreachable`.** It is the one argon2
precondition this module cannot refuse while compiling, because a password is a
value. `max_body` bounds a request's at one MiB by default; a program hashing
something else is on its own, and the roadmap still holds the undecided
question of whether nilo should truncate or pre-hash long passwords at all.
