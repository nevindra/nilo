# Most of an S3 client is not S3

S3 is an HTTP API, so a module that speaks it needs an HTTP client. nilo has
an HTTP *server* and cannot lend it: `http/http1.zig` parses request lines and
writes responses, which is the other direction, and `s3/` sits in the Service
layer where `nilo_http` is a sibling that `zig build layering` refuses.

The tempting reading is that the missing piece is small — nilo already knows
how to find the end of a head and how to decode a chunked body, and that code
is measured and fast. This decision is what happened when that reading was
checked.

## What the file actually contains

`http/http1.zig` is 1,068 lines: 686 of code and 382 of tests across 28 of
them. Split by whether a client could use it:

| | lines | for a client? |
|---|---|---|
| `readHead`, `findEndOfHead`, `HeaderIterator`, `takeLine`, the chunked codec | **~165** | yes |
| `Method`, `Request`, `parseHead` and its three helpers, the header dispatch | ~140 | no — this parses a *request line*; a client parses a status line |
| `isReservedHeader`, `repeats` | ~20 | no — policy for writing a response |
| `statusText`, `bodyless`, `writeResponse`, `staticResponse`, `writeResponseHeadOnly` | ~225 | no — writing responses |

**Twenty-four per cent.** And the fast part is not in that 165 either: the
measured work lives in `scan.zig`, which imports only `std` and says its own
numbers in its header — *finding the end of a request head went 183ns → 51ns,
and parsing it 303ns → 163ns*.

Those numbers are about a server's problem: a hostile client dribbling an 8 KB
head in a byte at a time, thousands of 121-byte heads a second. An S3 client
reads one response head of a few hundred bytes per call, across a round trip
of 5–50 ms. **Saving 130 ns on a 20 ms operation is 0.0007%**, and
[ADR 0001](./0001-dx-wins-below-the-10-percent-threshold.md) puts the bar at
ten per cent.

Then there is what reuse would not have helped with at all:

| | write it in `s3/` | share a `nilo_http1` | `std.http.Client` |
|---|---|---|---|
| HTTP framing | ~165 | borrowed | 0 |
| status line | ~20 | ~20 | 0 |
| TLS plumbing | **~380** (cf. `pg/src/stream.zig`) | ~380 | 0 |
| connection pool | **~250** | ~250 | 0 |
| **non-S3 lines** | **~815** | **~650** | **0** |

Framing is a fifth of the job. The two expensive parts — where the bugs and
the memory are — get nothing from sharing anything.

## What was decided

**`nilo_s3` is SigV4, S3's semantics, and nothing else. The HTTP is
`std.http.Client` and the TLS underneath it is `std.crypto.tls.Client`.**

That keeps the module's dependency count at **zero**. Not one, zero: the
framework's single dependency is zio and this module does not even need that.
`pg.zig` had to be marked `.lazy = true` so a program serving HTTP would not
fetch it ([ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md));
there is nothing here to make lazy.

Three properties were checked before this was chosen, because any one of them
failing would have ended it.

**SigV4 needs the request written byte for byte.** A client that reorders or
adds headers invalidates the signature. Every default header in
`std/http/Client.zig` is overridable — `host`, `authorization`, `user-agent`,
`connection`, `accept-encoding`, `content-type` — and `extra_headers` is
written out verbatim, in order.

**A handler must not block its thread ([ADR 0014](./0014-handlers-must-not-block-the-thread.md)).**
The connection pool takes an `Io.Mutex`, not a `std.Thread.Mutex`. Under zio
that parks the fiber.

**One allocation per connection.** All four buffers are sliced out of a single
`alignedAlloc`.

## What it costs per connection, and why that needs a gate

One pooled HTTPS connection, at the defaults:

```
tls_read_buffer    = tls_buffer_size + read_buffer_size = 16,645 + 8,192 = 24,837
tls_write_buffer   = tls_buffer_size                                     = 16,645
socket_read_buffer = tls_buffer_size                                     = 16,645
socket_write_buffer= write_buffer_size                                   =  1,024
                                                                          ───────
                                                                           59,151 B
```

plus `@sizeOf(Tls)` and the host name. `tls_buffer_size` cannot go below
`std.crypto.tls.Client.min_buffer_len` — 16,645, which is a `TLS` record at its
maximum plus its header — and that floor is the same whichever TLS
implementation is underneath. ianic's `tls.zig`, which `pg.zig` already brings,
wants 16,645 + 16,469 = 33,114 for the same job against std's 16,645 × 2 =
33,290. **A hundred and seventy-six bytes apart**, so memory decided nothing
between them; what decided it is below.

**The pool does not bound connections in use.** `free_size = 32` caps idle
ones — 32 × 59,151 = 1,892,832 bytes sitting there — and `used` is an unbounded
list. Five hundred handlers calling S3 at once open five hundred TLS
connections: 29.6 MB and five hundred handshakes, and S3 starts answering
`503 SlowDown` well before that.

That is the exact shape ADR 0018 exists to refuse — a per-request resource with
no ceiling — against a framework whose published figure is 8,767 bytes per idle
connection, flat from one thousand connections to ten thousand.

**So `nilo_s3` puts a gate in front of it: `max_in_flight`, held by a
`std.Io.Semaphore`.** Pure std, `Io.Mutex` and `Io.Condition` underneath so it
parks the fiber, and `wait` returns `Io.Cancelable!void` so a caller bounded by
[ADR 0065](./0065-the-way-out-was-open-the-clock-was-not.md) comes back out of
the queue when its clock runs out. **The ceiling is `max_in_flight × 59,151`
bytes and that number goes in the docs**, because a number nobody wrote down is
a number nobody chose.

> **Amended by [ADR 0070](./0070-a-fitting-borrows-the-loop.md) and
> [ADR 0072](./0072-an-object-store-is-a-service-that-dials.md).** The gate,
> the deadline, the bounded drain and the body ceiling are `nilo_fetch`'s now,
> and `nilo_s3` is a caller of it rather than the owner of them. Nothing a
> user writes moved: `max_in_flight` and `max_drain` are still options on
> `s3.open`, passed straight through, which is why this went four ADRs
> without anybody noticing the text was stale. What survives here unchanged
> is the *reasoning*: the 59,151 bytes, the ceiling being per process, and
> why a gate has to exist at all. That argument is about
> `std.http.Client` rather than about which module holds the semaphore.

## Retries: only the one that is not a policy

`Request.deinit` decides whether a connection is reusable, and one branch of it
is a trap:

```zig
connection.closing = connection.closing or switch (r.reader.state) {
    .ready => false,
    .received_head => c: {
        …
        _ = reader.discardRemaining() catch …;   // no limit
        break :c r.reader.state != .ready;
    },
    else => true,
};
```

A `get` refused for being over `max_bytes` has read the head and touched no
body — so `deinit` downloads the whole object anyway, to keep a connection. A
10 MB limit and a 500 MB object means 500 MB of egress for a request that
already failed, silently.

This is `sql/wire.zig`'s `drain(rows)` again, and worse: pg.zig destroys a
connection left dirty, where std sips the whole thing. **`nilo_s3` drains only
when what is left is under a stated threshold and marks the connection closing
otherwise.** `Request.connection` and `Connection.closing` are both public, so
this needs no fork. The threshold is a number rather than a guess and is
measured before it is written down — at what leftover size does reading it beat
a fresh TLS handshake.

**Beyond that, one retry and no more: a pooled connection S3 has already
closed.** An idle keep-alive connection being reaped is normal, and the first
write to it fails; not retrying that once turns every idle timeout into a
spurious error. That is correctness.

> **This was decided here and then not built, for two releases.** ADR 0070
> gave the policy to `nilo_fetch` under the heading "no retries", which is
> right about somebody else's *service* and swallowed this one, which is about
> a socket this side had already stopped using. Nothing noticed, because the
> failure needs an idle period to appear and every test dialled a server it
> had just started.
>
> What found it was a benchmark: a `wrk` run against `bench/s3_server.zig`
> after 80 seconds idle answered **exactly 32 requests non-2xx**, warm zero,
> and 32 is `std.http.Client.ConnectionPool.free_size`. The whole pool reaped,
> one spurious 500 each.
>
> It is built now, in `fetch/fetch.zig` where the connection is, and the shape
> corrects one word of the paragraph above: **"one retry" is not enough.**
> When a pool goes stale together, a single retry draws a second corpse as
> often as a live socket (measured, 32 became 13), because an attempt can
> only evict the connection it was handed. The bound is the pool's own
> `free_size`, which is at most one attempt per connection it could be
> holding, and it takes the same run to **zero**.

**A `503 SlowDown` or a 5xx comes back to the handler as `error.Throttled` or
`error.Unavailable`.** Backing off is refused here, and the reason is the gate
above rather than taste: a fiber that sleeps while holding a permit turns
throttling into a queue, and the queue into a timeout for every request behind
it. Returning immediately is what lets a handler shed load, answer from a
cache, or serve a default. And a streamed `put` cannot be retried anyway — its
reader has been consumed — so a retrying client would have two behaviours in
one API.

## Why not the alternatives

**Write an HTTP/1.1 client inside `s3/`.** ~815 lines of code whose subject is
not S3, to save about 17 KB per pooled connection (a hand-rolled one shares the
ciphertext and plaintext buffers std keeps separate: ~42,300 against 59,151).
At a pool of eight that is 136 KB, bought with a TLS state machine and a
connection pool to keep correct forever.

**A shared `nilo_http1` in the bottom layer.** Better than the above — copying
a chunked codec into two files is the fourth copy this repository warns about —
and still dominated, because it shares the fifth of the work that was never the
problem. It also forces `readHead`'s signature open: it takes
`bulkhead.Deadlines` and arms the header clock exactly once, on the first byte,
and the reason is written in its doc comment. A bottom-layer module cannot name
the Bulkhead, so that becomes a callback with the armed-once flag crossing a
module boundary, or an inverted loop that reintroduces the rescan the `scanned`
cursor exists to prevent.

**ianic's `tls.zig` instead of std's.** More mature, tested against badssl,
with levers std has none of — cipher suite selection, `insecure_skip_verify`,
client certificates, key logging — and chosen by the author of zio for pg.zig.
Refused on one mechanical fact: pg.zig pins it at `5452bafc`, Zig deduplicates
packages by hash, and a program using both `nilo_sql` and `nilo_s3` under two
different pins compiles **two TLS implementations into one binary**. Avoiding
that means locking nilo's upgrade schedule to somebody else's forever. std's
`Options` also ask for exactly two things this repository has already decided
how to provide — `entropy` (ADR 0046) and `realtime_now` (ADR 0045) — and
`ca: .self_signed` covers the development case that looked like std's hole.

**Terminating outbound TLS in front, mirroring
[ADR 0028](./0028-tls-is-terminated-in-front.md).** A sidecar that originates
TLS is a real deployment shape, and a module that only reaches S3 through one
does not do the ordinary job the module exists for.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes.

| Axis | Cost |
|---|---|
| Allocations per request | **None** for a handler that never calls S3 — nothing on the HTTP request path changes. A bounded `get`: **one**, in the request arena, sized from `Content-Length`. A streamed `get`: **none**. A `put` from a slice: **none**. Opening a pooled connection is one `alignedAlloc`, amortised across every request that reuses it. |
| Memory per idle connection | **None** on an inbound connection: no field on `Ctx`, none on a pooled connection. It adds a per-process ceiling instead — `max_in_flight × 59,151` bytes plus one `std.crypto.Certificate.Bundle`. Both are stated numbers and the bundle is measured before this ships. Per [ADR 0063](./0063-a-handlers-stack-is-per-connection.md) a handler that calls S3 also adds its stack high-water mark to every connection it runs on, and an S3 route is measured the way `/people/:id` was. |
| Throughput and p99 | **None** for a handler that never calls S3. For one that does, the floor is a network round trip; what this module adds on top is one HMAC-SHA256 ([ADR 0069](./0069-a-signing-key-changes-once-a-day.md)), one shared `Io.RwLock`, one `Io.Semaphore.wait`, and one indirect call to arm a deadline. |
| Binary size | **Zero** for a program that never imports `nilo_s3` — no dependency to fetch, and nothing referenced for the linker to keep. To be measured as a stripped `ReleaseFast` delta for one that does, and added to the running total. |

## Consequences

- **`std.http.Client`'s pool policy is not nilo's**, and that is the price of
  the zero. Redirect handling, LRU eviction and proxy-environment behaviour are
  std's. The two places it would have hurt — no ceiling on connections in use,
  and an unbounded drain on `deinit` — are both reachable through public fields
  and are both handled here.
- **The version of Zig is now part of this module's behaviour** in a way it is
  not for the rest of nilo. A change to `std.http.Client` between releases is a
  change to `nilo_s3`, and the live tests are what will find it.
- **`scan.zig` is not moved anywhere by this decision.** It could go to the
  bottom layer cheaply and this is not the caller that justifies it; that stays
  an open question with no S3 in it.
- **The 24% measurement is the reusable part of this ADR.** The next module
  that wants to borrow the server's parser should count first. Sharing the
  cheap fifth of a job is not sharing.
- **A decision recorded here and implemented elsewhere is a decision that can
  go missing.** The retry above was argued, written down, and then handed to a
  module whose own ADR refused the category it belonged to. Neither document
  was wrong on its own. What was missing is that nothing re-read this one when
  the ownership moved, which is the case for an amendment being part of the
  move rather than a follow-up, and for `bench/result/` existing, since a
  benchmark is what eventually noticed.
