# A response larger than the arena keep is a page fault per page

[`bench/result/s3.md`](../../bench/result/s3.md) recorded that axum answers a
megabyte 2.2× faster than nilo on a route with no object store anywhere near
it, and [`roadmap.md`](../roadmap.md) carried it as **"nobody has looked"**.
Somebody has now. **Most of it was one constant, and the rest was not nilo's
code at all.**

## What was measured

Same machine as the s3 comparison (AMD 9700X, 8 cores), same pinning —
server on `0-2,8-10`, load generator on `3-5,11-13`, `wrk -t4 -c64` — every
figure interleaved so the box's drift is charged to both sides. All of it is
`bench/s3_server.zig`'s `/warm/1m`, which allocates a megabyte from the request
arena, fills it, and answers with it.

**The published 8,215 req/s did not reproduce: the same route on the same box
measured 7,908.** That is the reason the before is built rather than quoted,
and a change measured against the published figure would have claimed 4% it did
not earn.

| | req/s | spread | minor faults/req | user µs/req | sys µs/req |
|---|---|---|---|---|---|
| nilo, `arena_keep` = 16 KiB (the default) | 7,908 | 5.4% | **257.2** | 150.6 | 567.8 |
| nilo, `arena_keep` = 2 MiB | 11,069 | 8.4% | **0.2** | 203.7 | 340.7 |
| axum | 17,235 | 11.1% | 0.0 | 34.5 | 336.9 |

## 1. The arena hands the megabyte back after every request

`arena.reset(.{ .retain_with_limit = arena_keep })` keeps 16 KiB. A megabyte
does not fit in 16 KiB, so the block is returned and the next request takes it
again: **257.2 minor faults per request**, which is 1 MiB / 4 KiB and one page
the kernel has to zero for each of them. It shows up as *system* time, which is
why the default's sys is 567.8 µs against axum's 336.9.

Setting the keep past the response takes the faults to 0.2 and the route from
**7,908 req/s to 11,069, +40%**, with the sign the same in four interleaved
pairs out of four.

**So `arena_keep` becomes a `listen()` option.** The default does not move: the
memory is per *connection*, so a megabyte of keep on a server holding ten
thousand connections is ten gigabytes, and every connection that once served a
big response holds its block until it closes. That is
[ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s per-connection axis, and
it is the axis this framework refuses to spend by default. A caller who knows
their response size and their connection count can spend it deliberately.

Held by two tests in `http/app.zig`: eight requests down one connection allocate
eight times at the default and zero with the option set.

## 2. What is left is not the HTTP server

The remaining gap is entirely *user* time — 203.7 µs against axum's 34.5 — and
four controls say where it is. Each is a route beside `/warm/1m` in
`bench/s3_server.zig` doing one thing differently.

| route | what changes | req/s |
|---|---|---|
| `/warm/1m` | the shipped path | 10,229 |
| `/warms/1m` | `rep stosb` instead of `@memset` | 10,459 |
| `/tls/1m` | one buffer per thread, not per connection | 14,365 |
| `/tlss/1m` | both | **18,054** |
| `/static/1m` | a buffer that exists before the server does | **22,018** |
| axum `/warm/1m` | — | 17,209 |

**`/static/1m` is the answer to the question the roadmap actually asked.** Same
`send`, same megabyte, same socket, nothing assembled per request: nilo answers
**22,018 req/s against axum's 17,209**, +28%, sign the same in three rounds out
of three. Putting a megabyte on the wire was never the slow part. `sys` per
request is within 1% of axum's on every row above, which says the same thing a
second way.

The two things that were slow are both in the *handler*:

- **`@memset` is not the fill glibc uses.** Filling a megabyte over a 64 MiB
  working set, one core: `@memset` 2.01 s per 20 GiB, glibc's `memset` 0.75 s,
  `rep stosb` written by hand 0.66 s. It is not the target ISA —
  `-mcpu=baseline`, `x86_64_v3` and `native` are 2.25, 2.26 and 2.28 s — and it
  is not the allocator, because swapping `page_allocator` for `c_allocator`
  moves nothing. LLVM lowers `@memset` to a vector store loop and recognises a
  call to `memset` well enough to lower that the same way, so an `extern`
  declaration does not escape it either.
- **A per-connection arena scales the working set with connections.** Sixty-four
  connections each retaining a megabyte is 76.6 MB live against axum's 23.2 MB,
  and this chip has 32 MB of L3. axum frees its buffer per request and its
  allocator hands the same warm block to the next one, so its working set is
  bounded by threads. Moving nilo's fill to a per-thread buffer, changing
  nothing else, is worth 10,229 → 14,365.

With both, nilo is **18,054 against axum's 17,209**. That margin is 4.9% and the
two spreads are 8.8% and 7.5%, and the sign flipped in one of three rounds
(+2.0%, +13.6%, −0.4%). **So the honest statement is that they are level**, not
that nilo wins — the rule from `bench/result/http.md` that a margin narrower
than its own spread is quoted as a range or quoted wrong.

## 3. This is why the 1 MB pair was void

`bench/result/s3.md` already refused to use the 1 MB row: subtracting
`/warm/1m` from `/o/1m` gave nilo a **negative** cost for its S3 client, and the
file recorded that "a client cannot cost negative CPU" without saying why it
happened. This is why. **The floor route was more expensive than the route it is
subtracted from**, because `@memset` of a megabyte costs more user CPU than
receiving a megabyte from a socket. The check in `table.py` caught it; the cause
was one layer down.

A control has to be *the same work minus the thing being measured*. `/warm/1m`
is the same work minus the object store **plus** a fill that the store route
does not do, and at a megabyte that addition is larger than the subtraction.

## What was rejected

**Raising the default `arena_keep`.** It buys 40% on this route and spends the
one axis ADR 0018 treats as hard, for every server, including the ones whose
responses fit in 16 KiB and who would notice nothing but the memory.

**Turning the write buffer up.** `Options.write_buffer` is 4 KiB and its own doc
says a larger response "is split across several" writes, so a megabyte through
it looked like 256 writes against axum's one. Setting it to 1 MiB is worth about
6%, inside the spread: `writeAll` already passes a slice larger than the buffer
straight through. The hypothesis was wrong and the doc is what made it look
right.

**Making nilo fill buffers for the caller.** `@memset` being slower than glibc's
`memset` is Zig's, not nilo's, and a framework that quietly substituted inline
assembly for a builtin the caller wrote would be lying about what the code says.
It is recorded here so the next person measuring a large body knows, and
`/warms/1m` stays in the bench server so the number can be re-taken.

**A per-thread block cache under the arena.** It is what would close the last
gap without asking the caller for anything, and it is a real design — an arena
whose big nodes come from a per-thread free list rather than from the gpa. Not
built: it changes where request memory lives, which is
[ADR 0004](./0004-a-str-belongs-to-its-request.md)'s territory, and the option
above covers the case that turned up. Written down so it is not re-derived.

## What this costs

Nothing on any axis by default: one `usize` on the `App`, read once per request
by the connection loop in place of a constant, and the same value in it. The
allocation-budget test is unchanged. A caller who sets it pays exactly the
memory they asked for, per connection, and the option's doc says so in those
words.
