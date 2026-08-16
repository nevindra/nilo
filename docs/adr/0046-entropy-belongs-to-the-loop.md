# Entropy belongs to the loop, so a handler asks for it and a module below does not

[ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md) shipped
`nilo_id` with `v4(entropy)` and `v7(entropy, ms)` — the format and not the
source — and recorded the bill it left: **`Ctx` exposes no entropy, so a
handler had nowhere to get the argument.** A UUID module a handler could not
call is a thin thing to ship, and this is the half that fixes it.

[ADR 0045](./0045-core-knows-what-time-it-is.md) settled the millisecond by
putting a clock in Core. Entropy does not go the same way, and why it does not
is the whole of this decision.

## What was decided

**`Ctx.entropy(comptime n)` answers `[n]u8`**, through
`bulkhead.randomSecure`. A handler writes one expression:

```zig
const key = id.v7(try c.entropy(id.Uuid.v7_entropy), nilo.nowMillis());
```

**`nilo.randomSecure(buf)` is re-exported** for a buffer already in hand — a
32-byte session secret at startup, say — alongside `Mutex`, `blocking` and
`sleep`, which are there for the same reason: every one of them is a call whose
*waiting* the Bulkhead has an opinion about.

**A method rather than a free function, and that is the point.** Entropy comes
from the operating system, and an operating system call made straight from a
fiber stops every request sharing that thread
([ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 0014](./0014-handlers-must-not-block-the-thread.md)). Going through the
Bulkhead parks the fiber on the Engine's blocking pool and tells the detector
the handler is not the one holding its thread
([ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md)). Being
reachable only from a `Ctx` is what says *this call costs a wait, and here is
where the wait is paid for*.

**A `Run` gets nothing, and that is the interesting half.** ADR 0042 left this
open — *either `Run` holds an `Io`, which is Core doing IO, or the second pair
belongs to something that is not a Scope*. It turns out to be neither, because
the question was wrong: **a program holding a `Run` already has an `Io`**, since
in Zig 0.16 it cannot read a file or write a line without one, and
`std.Io.randomSecure` is right there. Core adding a passthrough would be
ceremony around a call std already offers.

So the rule reads: **entropy is an App-layer call, because the only thing there
is to decide about entropy is how the wait gets paid for, and only the App has
a loop to pay it out of.** A program with no loop has no problem to solve.

**`nilo_id` does not change.** It keeps taking its randomness as an argument,
which is now an argument that exists.

## Why not the alternatives

**`id.v4()` with no arguments, over a source `nilo_id` holds.** What the module
looks like it should offer, and it needs global mutable state, a seeding moment
a CLI does not have, and a `@import` of something that can reach the operating
system. The last one is fatal on its own:
[ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
established that a tool module naming `nilo_core` gives up running under a
plain `zig test`, which ADR 0042 made the entry condition for the layer.
Reaching further than `nilo_core` would give up more.

**A per-thread CSPRNG, seeded once at `listen()`.** The version that makes a
UUID cost no operating-system call at all, and the measurement is why it is not
here. `getrandom` for sixteen bytes is **56ns** on this machine, because Linux
6.11 and later serve it from a vDSO-backed pool rather than as a real syscall.
A cache would be saving 56ns, and it would cost stored state per thread, a
seeding moment, a fork hazard — a forked child inherits the parent's state and
generates the parent's ids — and it would disagree with what
`std.Io.randomSecure` says about itself: *always makes a syscall, or otherwise
avoids dependency on process memory. Does not rely on stored RNG state.*

The number is the argument, and it is also why this is written down rather than
refused: on a kernel without that vDSO the same call is a real syscall and
costs roughly twenty times more. **The Bulkhead is exactly where a cost that
varies by platform gets absorbed**, which is what makes it the right place for
this whether or not the cache ever becomes worth building.

**A second Scope-shaped pair — an `Entropy` checked while compiling**, so that
`id.v4(source)` takes anything able to supply bytes. Symmetrical with the
Scope, and wrong twice: it would make `nilo_id` import `nilo_core` for the
check, costing the standalone `zig test` above, and it would have exactly one
implementer. The Scope exists because two unrelated things really are Scopes; a
shape with one implementer is an indirection with a comment on it.

**Fill a buffer the caller declares — `c.entropy(&buf)`.** What the Bulkhead
call underneath does, and it makes the caller write two statements where one
would do, with an `undefined` in the first. Returning `[n]u8` by value costs
nothing — `n` is comptime, the array is on the stack, nothing is allocated —
and it fits inside the expression that wants it, which is the only reason the
one-line form above reads.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none.** The array is on the caller's stack; the framework never calls this. |
| Memory per idle connection | **none.** No new field on `Ctx` — a method costs nothing per instance. |
| Throughput and p99 | **none** for a request that does not ask. |
| Binary size | **zero**, measured. |

`example-hello` 885,504, `example-rest` 1,031,744, `nilo-hello` 890,384 —
byte for byte the parent commit's numbers, stripped `ReleaseFast`, built in a
`git worktree`.

What a caller pays is **56ns per call** on this machine for the bytes
themselves, plus whatever the Engine charges to park and resume a fiber, which
is not measured here because nothing in the suite runs one. A handler making
one UUID per request is not on any path worth thinking about; a handler making
one in a loop is, and the note is at the function.

## Consequences

- **`nilo_pw` is unblocked, in the same shape as `nilo_id`.** Hashing a
  password needs a salt, which is this, and argon2 needs to get *off* the loop,
  which `nilo.blocking` has always offered. So it is the same division: the
  algorithm is a pure function in a tool module, and the caller supplies the
  entropy and wraps the call. Nothing new has to be decided.
- **`nilo_s3` is not unblocked**, and it was wrong to say the two waited on the
  same thing. Reaching *out* to a socket is a different missing seam — the
  Bulkhead covers the way in and nothing covers the way out — and it is still
  its own decision (ADR 0041's last consequence).
- A handler now has a supported source of randomness for anything else it
  wanted one for: an idempotency key, a nonce, a one-time token. None of that
  is a feature nilo has an opinion about; it is a call that used to be missing.
- `Ctx.entropy` and `Session`'s nonce now reach the same Bulkhead call by two
  routes. That is the intended shape rather than a duplication: one is nilo
  sealing a cookie, the other is a handler asking, and both are the Engine's
  business rather than the caller's.
