# A body is taken as it arrives

`c.body()` read the announced length out of the request arena before it read a
byte of it:

```zig
if (self._request.content_length > self._limits.max_body) return error.BodyTooLarge;
const b = try self._arena.alloc(u8, @intCast(self._request.content_length));
try self._in.readSliceAll(b);
```

`Content-Length` is a number a stranger typed. A client that announced a
megabyte and then sent one byte a minute held the megabyte for as long as it
kept trickling, and `body_timeout_ms` does not stop it: that limit is per
*read*, not for the body, deliberately
([ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)), so
a client answering inside every window never trips it.

**`readSizedBody` takes one page first and commits the announcement only once
the client has delivered it.**

## What it was actually costing, which is not what the gap said

The gap as filed said ten gigabytes of memory at the default
`max_connections`. That is the wrong resource, and finding out took a second
instrument.

`bench/mem.py` reads `VmRSS`, and **Linux does not count a page nobody has
written to**. The megabyte was mapped and untouched, so the first run said a
stuck connection cost 17,281 bytes with the fix and 17,281 bytes without it.
`bench/slowloris.py` reports `VmData` as well for exactly this reason, and with
both columns the picture is unambiguous — 1,000 connections, each announcing
`max_body` and sending one byte:

| route | `VmData`/conn before | after | `VmRSS`/conn, either |
|---|---|---|---|
| `/echo` — `c.body()` | 1,852,080 | **283,378** | 17,281 |
| `/stream` — `c.bodyStream()` | 275,448 | 275,448 | 17,539 |
| `/drop` — never reads it | 275,120 | 275,120 | 17,281 |

`/drop` is the floor — fiber stack reservation and buffers — so the body's own
share went from **1,576,960 bytes to 8,258**, two pages, and `/echo` is now
within 8 KiB of `/stream`, the shape that never had the problem. At 10,000
connections that is 18.5 GB of address space against 2.8 GB.

**Resident memory does not move, and saying so is part of the finding.** The
attack does not cost the machine RAM either way, because a byte that was never
sent is a page that was never touched. What it costs is anonymous mappings —
which is `vm.max_map_count` (65,530 by default), a strict-overcommit
deployment, and page tables. That is a smaller claim than the one in the
roadmap and it is the true one.

## Why not the obvious growth loop

Three shapes were built and measured before the one that shipped, and all three
were rejected on throughput rather than on memory. `wrk -t2 -c32`, four
interleaved pairs per body size, against `bench/body_server.zig`:

| shape | 1 KB body | 64 KiB body | 1 MB body |
|---|---|---|---|
| before | 35,797 | 8,314 | 814 |
| fixed 16 KiB steps into an `ArrayList` | unchanged | 5,341 (**−36%**) | 442 (**−46%**) |
| explicit doubling from 16 KiB | unchanged | 5,613 (**−32%**) | — |
| one 16 KiB step, then the rest | unchanged | 6,538 (**−21%**) | 754 (**−7.4%**) |
| **one 4 KiB step, then the rest** | unchanged | **8,002 (−1.5%)** | **792 (−2.3%)** |

**The copying was never the cost.** Doubling turns a linear number of copies
into a logarithmic one and bought four points of thirty-six, which is what says
the copies were not where the time went. What costs is the number of
allocations that need a **new arena node**: each one is an `mmap`/`munmap` pair,
and on two cores the TLB shootdown behind it is worth more than the whole rest
of the request.

**Which makes the step size the entire design, and it is 4 KiB rather than 16
for one reason.** `arena_keep` defaults to 16 KiB and a POST has already spent a
little of it on the head, so a 4 KiB first allocation comes out of the block the
arena is already holding and a 16 KiB one does not. Same shape, same two
allocations, and the difference between −21% and −1.5% is whether the first of
them calls the page allocator.

1 KiB was measured too and is equally free — both change sign across three
interleaved pairs. 4 KiB shipped because it buys four times the defence for the
same nothing.

So: one allocation for a body inside the step, which is the overwhelming
majority and is byte-for-byte what happened before, and two for anything
larger.

## What the guarantee actually is now

It is weaker than "hold only what arrived", and the weaker version is the one
that fits.

A client must deliver a page before nilo commits what it announced, so the
amplification a stranger can buy goes from **unbounded to 256×** at the default
`max_body` — and a connection that opens, announces and says nothing holds a
page. To hold ten gigabytes across ten thousand connections an attacker now has
to actually push 40 MB and keep the sockets open, rather than send ten thousand
headers and stop.

That is a rate rather than a wall, and the wall is a different feature: a
deadline for the whole body. `body_timeout_ms` is per read and deliberately so
([ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)), so
a client that keeps answering is never cut off. The roadmap carries that as its
own gap rather than this one pretending to have closed it.

## What is not changed

`c.bodyStream()` already had none of this — it allocates nothing and the
handler's buffer is the ceiling — and the chunked path already grew as chunks
arrived. This brings the third of the three into line rather than inventing
anything.

`max_body` still refuses the announcement itself, before any of this runs, so
the ceiling on a single body is where it was.

## The tests

Two, and the second is the one worth reading. It hands `readSizedBody` an
announcement of ten megabytes, four bytes of body and 64 KiB of allocator to
serve it from — so the old shape cannot pass it: it fails allocating and never
reaches the read. That is a slow-loris with the connection closed instead of
held open, which is the part a unit test can express.
