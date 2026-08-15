# The thing a handler holds is watched at run time

[ADR 0014](./0014-handlers-must-not-block-the-thread.md) established the rule
— many requests share one OS thread, so a handler that waits on the operating
system directly stops all of them — and then said this about it:

> **Nothing forces it.** A handler calling the driver directly still compiles
> and still passes its tests.

It considered detection and rejected it, in one line:

> **Detect blocking calls at compile time.** Zig has no effect system and no
> way to mark a function as blocking. Nothing to detect with.

That is correct and it is about the wrong kind of detection. The question it
answers is "can the compiler prove a function blocks", and the answer is no.
The question nobody asked is "can the server notice that one just did", and
the answer is yes, cheaply, with a stopwatch.

## Why it matters more than the wording suggests

This bug is invisible in development, and it is invisible *because* there is
no load. One `curl` against a handler that queries a database synchronously
returns the right answer at the right speed. It is correct in every way a
person can check by looking at it. The bug only exists in the presence of a
second request, which arrives for the first time in production.

Everything else zfast gets wrong announces itself: a bad route 404s, a bad
header parse fails a test. This one waits.

## The decision

A debug aid in the shape of the `Str` staleness trap (ADR 0004) — a rule the
type system cannot hold, held instead by something that watches at run time
and says so in words.

`src/watchdog.zig` measures **elapsed time minus time the fiber spent
parked**, per request, and warns when what is left crosses
`block_warning_ms` (default 250):

```
handler GET /users/7 held its thread for 2003ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
zfast.blocking (ADR 0014).
```

Parked time is not guessed at. It is reported by the small set of things a
request waits on that are not the handler's own code:

| what waits | where it says so |
|---|---|
| `zfast.blocking` | `bulkhead.blocking` |
| `zfast.sleep` | `bulkhead.sleep` |
| `zfast.Mutex.lock` | `bulkhead.Mutex` |
| asking the OS for entropy | `bulkhead.randomSecure` |
| reading the request body | `Ctx.body` |
| writing the response | `Ctx.send`, `App.sendDirect` |

Whatever is left over is the handler running. A handler that ran for a
quarter of a second without yielding once is either blocking or doing CPU work
it should have handed to `zfast.blocking` — and since that is the same advice
either way, both are worth saying.

Three of those six turned `Mutex`, `sleep` and `randomSecure` from re-exports
into wrappers. That is the entire structural cost.

## What it looks like against a real server

Two handlers, both waiting 600ms, on a server with two executor threads. One
holds the thread; the other hands the wait to `zfast.blocking`. Everything
else about them is identical, including what the client sees:

```
$ curl -w '%{time_total}\n' localhost:8799/slow      # holds the thread
0.600718
$ curl -w '%{time_total}\n' localhost:8799/proper    # zfast.blocking
0.603396
```

Three milliseconds apart, and nothing in the response distinguishes them.
That is the whole difficulty with this bug: from the outside, with one
request, the wrong version is indistinguishable from the right one.

The difference is what happens to everybody else. Four requests in flight,
then one that does nothing at all:

```
/quick behind 4x /slow      1.654528s
/quick behind 4x /proper    0.002606s
```

**Six hundred times slower**, paid by a request that had nothing to wait for.
And the log, of its own accord, from the single-`curl` run above:

```
warning: handler GET /slow held its thread for 600ms. Every other request being
served on that thread waited the whole time. Hand the call that waits to
zfast.blocking (ADR 0014).
```

Nothing was said about `/proper`, on any run.

Under the four-at-once load the rate limit does its job:

```
warning: handler GET /slow held its thread for 602ms, and 2 more did in the
second before it. …
```

## Why the whole chain, and not just the handler

The clock starts before the middleware chain and stops after it, rather than
around the terminal handler. A middleware that writes an audit row to a file
after `next.run` stops the thread exactly as dead as a handler that does, and
it is the second most common way to make this mistake. There is a test for it.

## The measurement, and what it changed

The first working version cost **116ns per request out of 612** — 19%, well
past [ADR 0001](./0001-what-zfast-optimises-for.md)'s 10% budget for anything
that buys DX. It read a clock four times per request, and the Bulkhead's
`monotonicNanos` costs 27ns a read because `CLOCK_MONOTONIC` does the full
timekeeping arithmetic every time.

Two changes brought it down to 58ns:

**A coarse clock.** `CLOCK_MONOTONIC_COARSE` costs a measured **5ns** and only
moves once a millisecond. Against a quarter-second threshold, one millisecond
of resolution is not a compromise at all. `bulkhead.coarseNanos` is that
clock, falling back to `monotonicNanos` where the platform has no such thing.

There is a trap inside the trap, worth writing down: reached through
`std.os.linux.clock_gettime` it costs **571ns**, not 5ns, because zfast links
libc and that path skips the vDSO. Through `std.posix.system` it is 5ns. The
first version of this was a hundred times slower than the thing it replaced,
and it looked identical on the page.

**Holding the pointer instead of looking it up.** The remaining cost was not
the clock at all — it was `fail.inFlight()`, which finds the request through
the fiber slot, called twice on the response-write path. `Ctx` now carries
`_watch` directly. Code with no `Ctx` to hand — `zfast.blocking` and friends —
still pays the lookup, and does not care, because a request reaching one of
those is about to park anyway.

**610ns before, 668ns after — 58ns, or 9.5%.** Six runs of each, interleaved,
`zig build profile -Doptimize=ReleaseFast`, the before taken from a
`git worktree` at the parent commit rather than by stashing, so that neither
side is measured against a machine in a different mood than the other. That
matters more than it sounds: an earlier, uninterleaved pass on this same
machine read 612 and 728 half an hour apart and 681 and 673 ten minutes
later, and the second pair is the one that would have been quoted.

9.5% is inside ADR 0001's budget and not comfortably. It is enough to be on
by default in every optimize mode, which is what makes it worth having at
all — the bug lives in production. Had it stayed at 19% it would have gone on
in `Debug` and `ReleaseSafe` only, where the load that causes the damage never
arrives.

About 20ns of the 58 is the four clock reads. The rest is two more fields on
the `Ctx` built per request, twenty-four more bytes on the `InFlight`, and two
calls that are not there today. Nobody has been back for it.

## What it does not see

**A request that took the connection over** — a stream, a body reader, a
WebSocket — is excused entirely. All three hold their fiber legitimately, for
as long as they like, and nearly all of that time is socket I/O none of the
six rows above account for. A blocking call inside a WebSocket loop is real
and is not reported. `Ctx._took_over` is the flag, set in the three places
that take over; it is deliberately separate from `_stream`, which a properly
finished stream clears.

**A handler that blocks for less than the threshold, every time.** Ten
milliseconds of synchronous file read on every request is a real ceiling on
throughput and goes unmentioned. The threshold is a knob, not a claim.

**Fibers as a whole.** This reports one request holding its thread. It does
not report a thread that is oversubscribed, or a pool that is saturated, both
of which are throughput problems that look nothing like this.

## Consequences

- `zfast.Mutex` is now zfast's own struct rather than the Engine's, with three
  methods forwarded. `.init` and `.{}` both still work, so nothing a user
  wrote changes.
- `bulkhead.coarseNanos` exists and is the clock to reach for when the
  question is "has a long time passed" rather than "how long exactly".
- `block_warning_ms = 0` turns it off, and then `begin` stores nothing and
  every `waiting` call is a null check.
- The warning is rate-limited to one a second with a count of the rest,
  because a handler that blocks blocks on every request, and ten thousand
  copies of a message is a good way to lose it.
- `watchdog.caught` counts what was detected before that rate limit throws any
  away. It exists because the suite runs with warnings off, and a detector
  nobody can watch fail is a detector nobody should trust (ADR 0033).
