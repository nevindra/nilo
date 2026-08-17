# The way out was open; the clock was not

`docs/roadmap.md` has carried the same blocker under `nilo_core`'s known gaps
and again under "Modules that do not exist yet", and every module that dials
has been parked behind it:

> **A Service has no supported way to dial out.** The Bulkhead covers the way
> in and nothing covers the way out, so `sql` reaches the network through
> pg.zig's own zio and a Service written here would have to name zio.

> **`nilo_s3` — object storage.** Blocked, and not on the same thing. It needs
> an outbound socket, and the Bulkhead covers the way in only.

**Both paragraphs are false, and they were false when they were written.** The
way out has been open since ADR 0040. What is actually missing is the clock.

## What the files say

pg.zig does not depend on zio. Its `build.zig.zon` names four dependencies —
`buffer`, `metrics`, `xsync`, `tls` — and none of them is zio. `pg/src/stream.zig`
dials with `std.Io.net.Stream`, `std.Io.net.HostName` and `std.Io.net.UnixAddress`,
and takes the `std.Io` it is handed.

That `std.Io` is nilo's. `bulkhead.serve` runs `ready(state, io)` once the port
is taken, and `http/service.zig` erases the hook to
`*const fn (*anyopaque, std.Io) anyerror!void` — the `nilo_start` marker
ADR 0040 added. zio fills the `netConnectIp` slot of the `std.Io` vtable
(`zio/src/io.zig:243`), so a socket opened through that interface is opened on
nilo's event loop without anybody naming zio.

So `nilo_sql` reaches the network the supported way today, and any other
Service can. The gap was recorded from the wrong end: what was noticed was
that nilo has no `dial` of its own, and what was concluded was that a Service
cannot dial. std had grown the door in between.

## What is actually missing

**Nothing can stop an outbound operation that will not finish.**

- `std.Io.net.Stream.Reader` has no per-read timeout. `Socket.receiveTimeout`
  is for datagrams and `HostName.connectMany` bounds the connect only.
- `std.http.Client` has no deadline field anywhere in it.
- Cancellation, though, *does* reach: every operation in `std.Io.net` carries
  `Io.Cancelable`, and `std/http/Client.zig` says at the top of the file that
  `error.Canceled` was added to more error sets. A cancelled read comes back.

This is [ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)'s
rule against a wall it has not met before. Inbound, an operation is a read or
a write on a connection nilo holds, and `Deadlines.limit` bounds it. Outbound,
the connection belongs to a driver, and there is nothing to hold.

**It matters more here than it did for SQL.** `Db.Opts.timeout_ms` bounds the
wait for a free connection and stops the moment one is handed over
([ADR 0047](./0047-a-deadline-needs-a-connection-you-hold.md)); the statement
itself is bounded by `SET LOCAL statement_timeout`, which is the *server's*
clock. HTTP has no equivalent. An S3 endpoint that accepts a connection and
then says nothing holds a handler until the process dies, and
[ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md)'s
watchdog reports that; it cannot end it.

## What was decided

**`core.Limits` — a Service is handed something that bounds the unit of work
it is running on, through the same door it is handed `std.Io`.**

```zig
// in a Service
pub fn nilo_start(self: *Self, io: std.Io, limits: core.Limits) !void {
    self.io = io;
    self.limits = limits;
}

// at the call site, per operation
var bound: core.Limits.Bound = .idle;
defer bound.release();
bound.arm(self.limits, 2_000);

const res = self.client.request(...) catch |err| switch (err) {
    error.Canceled => if (bound.fired()) return error.TimedOut else return err,
    else => return err,
};
```

> **Corrected when it was built.** This sketch first read
> `var bound = self.limits.arm(2_000);` — a `Bound` returned by value — and
> **that cannot be implemented safely.** zio's `AutoCancel` stores `&self` as
> its timer's userdata and hands `&self.timer` to the event loop, so a struct
> armed at one address and then copied to another leaves the loop pointing at a
> slot nobody owns. Returning it by value arms the temporary. Arming therefore
> takes `*Bound` and the caller declares the storage first. The mistake the new
> shape allows — forgetting the `arm` line — leaves the operation unbounded,
> which is what it would have been with none of the lines written; the mistake
> the old one allowed was a live timer holding a dangling pointer.
>
> The slot size was owed a measurement and now has one: **zio's `AutoCancel` is
> 176 bytes**, not the smaller figure guessed while writing `core/limits.zig`.
> The `comptime` check in `http/bulkhead.zig` caught the guess on the first
> build and named the right number, which is the whole reason it is a build
> step. `Limits.slot_size` is 192.

Three parts, and each is placed where it already has a precedent.

**The type lives in `nilo_core`.** It is a struct and a vtable — no IO, no
allocation, no engine. `Str` is vocabulary about how long text lives and
`Scope` is vocabulary about where a Service allocates; this is vocabulary
about when an operation gives up. It earns the layer the way every other file
there does, by being needed by two of them: the App fills it, the Service
reads it. It changes nothing about `zig test core/core.zig`.

**The implementation is `zio.AutoCancel`, and only `http/engine/zio.zig` names
it.** It is public (`zio/src/zio.zig:27`), stack-allocated, managed by `defer`,
nestable with an independent timer each, and it carries a `triggered` flag so a
caller can tell a timeout from a cancellation somebody else asked for. That last
field is what makes `bound.fired()` honest rather than a guess about why
`error.Canceled` arrived.

`Bound` holds the engine's state in fixed opaque storage, so arming costs no
allocation. Core cannot know `@sizeOf(zio.AutoCancel)`, so it declares a slot
and `bulkhead.zig` — which does name the engine — holds a `comptime` check that
refuses an engine whose state does not fit, in nilo's own words. **The slot size
is one of the numbers this decision owes** and is measured before the first
caller ships, not after.

**`nilo_start` accepts either arity.** `startHook` already reads
`@hasDecl(T, "nilo_start")`; it also reads the parameter count, and erases a
two-parameter hook to the old shape and a three-parameter one to the new. A
Service that does not want a clock is unchanged and `sql/db.zig` compiles
untouched. A `nilo_start` of any other shape is a compile error nilo wrote,
which is a row in `refusals/` rather than a paragraph here (ADR 0027).

## Why not the alternatives

**`io.async` + `future.cancel`, entirely inside std.** This works and needs no
seam at all — race the operation against a timer, cancel the loser. It costs a
fiber. `zio/src/io.zig:283`'s `asyncImpl` reaches `spawnTask` through
`concurrentImpl`, and
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) has just finished
establishing that a fiber holds its stack at its high-water mark, carved out of
a slab of 64. That is a per-in-flight-operation cost on the axis ADR 0018 treats
as an invariant rather than a budget, paid forever, to avoid one struct in Core.

**Widening `nilo_start` to three parameters for everybody.** One line in
`sql/db.zig` and a `!` on the commit — and every Service anybody has already
written outside this repository breaks at once, for a parameter most of them
will not use. The two-arity hook costs one `comptime` branch at startup and
breaks nothing.

**A second marker, `nilo_limits(self, limits)`.** Additive and simple, and it
splits one moment into two hooks that are always called together. A Service
that declared one and forgot the other would build, run, and never bound
anything — a failure that is silent, which is the shape this repository spends
its refusals on.

**Leaving it out, and saying so.** ADR 0047 refused
`Db.Opts.statement_timeout_ms` on the grounds that an option declared, plumbed
and silently doing nothing is a defect. That argument bites the other way here:
cancellation *does* reach through `std.Io.net` and `std.http.Client`, so a
deadline built on it is enforced rather than decorative. There is no honest
version of shipping an outbound module without one.

**Fitting it to `nilo_s3` alone.** The roadmap's own instruction was that this
seam gets designed once against two callers or it gets fitted to whichever
turned up first. The second caller is already here and is not S3: `db.select`
outside a transaction has no deadline today, and ADR 0047 refused the
*mechanism* it would have used, not the need. `Limits` gives it one that does
not depend on Postgres cancelling anything.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes.

| Axis | Cost |
|---|---|
| Allocations per request | **None.** `Bound` is fixed storage on the caller's stack; arming and releasing allocate nothing. Nothing on the HTTP request path changes. |
| Memory per idle connection | **None.** No new field on `Ctx` and none on a pooled connection. `Limits` is two words held once per Service. Per ADR 0063, `Bound`'s storage is stack a handler touches — so it is a per-connection cost for a handler that arms one, and the slot size is the number that bounds it. |
| Throughput and p99 | **None** for a handler that never arms one. One indirect call and one timer registration for one that does, against an operation whose floor is a network round trip. The same trade `Deadlines` already makes inbound, which is also a vtable. |
| Binary size | **Zero** for a program that arms nothing: the vtable is filled with the no-op pair `Deadlines` already uses as `off`, and the engine's timer is not reachable. To be measured as a stripped `ReleaseFast` delta for a program that does, and added to the running total. |

## Consequences

- **The roadmap's two paragraphs are wrong and are corrected in the same change
  as this file.** Not softened — replaced. A Service *can* dial out; what it
  could not do is give up. This is the third time this repository has published
  a claim with no run behind it, after `connect_on_init`
  ([ADR 0062](./0062-a-pool-that-dialled-itself-whatever-it-was-told.md)) and
  the flat per-connection figure
  ([ADR 0063](./0063-a-handlers-stack-is-per-connection.md)), and it is the
  first one found by reading somebody else's `build.zig.zon` rather than by
  measuring.
- **`nilo_mail` and `nilo_redis` are unblocked by this and were never blocked
  by the other thing.** Whoever writes one takes `Limits` through `nilo_start`
  and owes an ADR about what it bounds, not about how it opens a socket.
- **`nilo_sql` gains a deadline it could not have.** Not in this change — the
  seam arrives first and `Db` picks it up on its own schedule — but ADR 0047's
  "a deadline on `db.select`, outside any transaction" was refused because two
  round trips per query is worse than not having the feature. A client-side
  bound is neither round trip.
- **The Bulkhead's contract list grows by one item**, and the header comment of
  `http/bulkhead.zig` says what it is and why, the way it does for every other
  item on that list. That file is the whole of what nilo asks of an Engine, and an
  engine that cannot cancel an operation in flight can no longer meet it.
- **A cancelled outbound connection is not returned to any pool.** Whatever was
  half-read is half-read; the caller marks it closing and pays a fresh
  handshake. A timeout that poisoned a pooled connection would be worse than
  the hang.
