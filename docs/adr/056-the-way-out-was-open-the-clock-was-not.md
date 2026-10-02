# The way out was open; the clock was not

**Status:** accepted
**Topic:** [deadlines](../design/deadlines.md)

## Context

`docs/todo.md` carried the same blocker under `nilo_core`'s known gaps and again under modules that do not exist yet: **"a Service has no supported way to dial out"**, and every module that dials was parked behind it. Both paragraphs were false when they were written. pg.zig does not depend on zio: its `build.zig.zon` names `buffer`, `metrics`, `xsync` and `tls`, and `pg/src/stream.zig` dials with `std.Io.net.Stream` and the `std.Io` it is handed. That `std.Io` is nilo's: `bulkhead.serve` runs `ready(state, io)` once the port is taken, and zio fills the `netConnectIp` slot of the `std.Io` vtable, so a socket opened through that interface is opened on nilo's event loop without anybody naming zio. So `nilo_sql` reaches the network the supported way today, and any other Service can. What was actually missing was noticed from the wrong end: nilo has no `dial` of its own, and the gap that produced was concluded to be "a Service cannot dial", when std had grown the door in between.

**What is actually missing is a clock.** Nothing can stop an outbound operation that will not finish: `std.Io.net.Stream.Reader` has no per-read timeout, `HostName.connectMany` bounds the connect only, and `std.http.Client` has no deadline field anywhere in it. Cancellation, though, does reach: every operation in `std.Io.net` carries `Io.Cancelable`, and `std.http.Client` added `error.Canceled` to its error sets for exactly this. It matters more here than it did for SQL, where `Db.Opts.timeout_ms` bounds the wait for a free connection and the statement itself is bounded by the server's own `SET LOCAL statement_timeout` ([ADR 043](./043-a-deadline-needs-a-connection-you-hold.md)). HTTP has no equivalent: an S3 endpoint that accepts a connection and then says nothing holds a handler until the process dies, and the watchdog ([ADR 013](./013-handlers-must-not-block-the-thread.md)) can report that but not end it.

Two callers found the two ends of the same hole before this shipped. fdm, a download manager on `nilo_fetch`, started a client with `nilo_start(io, .off)`, on a plain `std.Io.Threaded` with no Engine underneath, where a `Limits` arms nothing by design because Core cannot cancel a fiber. A non-zero `timeout_ms` there was a number that meant nothing, and nothing said so: a connection that stopped sending was held forever. fdm wrote its own guard around it, a per-segment stall watchdog across sixteen connections comparing bytes landed every 100ms and cancelling a task when the count had not moved for ten seconds, because the framework's own timeout was silently off. That watchdog is also the second finding: an end-to-end `timeout_ms` is the wrong shape for a transfer, where the segment's call *is* the transfer and may honestly take an hour, so the only honest value is zero, and zero leaves a segment whose peer went quiet with nothing to end it.

## Decision

**`core.Limits`: a Service is handed something that bounds the unit of work it is running on, through the same door it is handed `std.Io`.**

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

const res = self.client.request(...) catch |err| {
    if (bound.fired()) return error.TimedOut;
    return err;
};
```

**Arming takes `*Bound`, and the caller declares the storage first.** A `Bound` returned by value cannot be implemented safely: zio's `AutoCancel` stores `&self` as its timer's userdata and hands `&self.timer` to the event loop, so a struct armed at one address and then copied to another leaves the loop pointing at a slot nobody owns. Forgetting the `arm` line is the one mistake this shape allows, and it is the harmless one: an idle `Bound` releases nothing and reports nothing, so the operation is unbounded exactly as it would have been with none of these lines written.

**The bound is the authority, the error is not.** `std.Io.Reader`'s error set is fixed, so a cancellation crosses it collapsed into an ordinary read failure (`error.ReadFailed`, not `error.Canceled`), with the cause kept on the side. A caller asks `bound.fired()` after the call rather than switching on which error came back.

### Where each part lives

**The type lives in `nilo_core`.** A struct and a vtable, no IO, no allocation, no Engine named: `Str` is vocabulary about how long text lives, `Scope` is vocabulary about where a Service allocates, `Limits` is vocabulary about when an operation gives up. It earns the layer by being needed by two of them, the App fills it and the Service reads it, and it changes nothing about `zig test core/core.zig`.

**The implementation is `zio.AutoCancel`, and only `http/engine/zio.zig` names it.** Public, stack-allocated, managed by `defer`, nestable with an independent timer each, and it carries a `triggered` flag so a caller can tell a timeout from somebody else's cancellation. `Bound` holds the engine's state in fixed opaque storage, so arming costs no allocation. Core cannot know `@sizeOf(zio.AutoCancel)`, so it declares a slot (`Limits.slot_size = 192`) and `http/bulkhead.zig` holds the `comptime` check that refuses an engine whose state does not fit, in nilo's own words rather than a failed `@alignCast` later. **zio's `AutoCancel` measures 176 bytes**, not the smaller figure guessed while writing `core/limits.zig`; the check caught the guess on the first build, which is why it is a build step. The slot is 192 rather than 176 so a second Engine has somewhere to stand without the number in Core changing.

**`nilo_start` accepts either arity.** `startHook` already read `@hasDecl(T, "nilo_start")`; it also reads the parameter count and erases a two-parameter hook to the old shape and a three-parameter one to the new, so a Service that does not want a clock is unchanged and compiles untouched. A `nilo_start` of any other shape is a compile error nilo wrote.

### With no Engine, a deadline cancels a task instead of a fiber

`Limits.none` (the name since 0.5; `.off` is the same value, kept so `nilo_start(io, .off)` still compiles) arms nothing under an Engine-less `Io`, because there is no fiber to interrupt. `std.Io.Threaded` cannot cancel the thread a caller is on, but it can cancel a *task*: `Future.cancel` sends a signal into a blocking syscall and returns once the task has come out of it, and zio can too. **`nilo_fetch`'s `Exchange` bounds each step of a call as a task of the `Io`, cancelled when the clock passes the deadline.** `begin` reads the timeout once and puts it where whichever mechanism can enforce it: `Bound.arm` under an Engine, or an absolute time on Core's monotonic clock when `client.limits.engineless()` says there is none. Every step that can block (the head in `begin`, `take`, `readInto`, `pipe`, the drain in `end`) goes through `bounded`: the call itself when there is no deadline, and otherwise `io.concurrent` of the call plus a futex wait on a word the task sets when it is done, with what is left of the deadline as the wait's timeout. Past it, the task is cancelled, `expired` is set, and `blame` names the failure a timeout the way it does under an Engine. A cancellation of the *caller's* task (a shutdown) comes back through the wait, is passed to the inner task, and is put back with `io.recancel()` so the next `Io` call still sees it. **`nilo_job` bounds a run the same way**: a worker started with `serveOn` on a plain `Io` ran with `Limits.none`, armed nothing, and let the lease lapse under a run still going, so a second worker ran the row beside it; with no Engine, a run with a timeout is now an `io.concurrent` task cancelled at `timeout_ms`, and ends as a timeout.

With no Engine and a bound in place, a task per call is a task the `Io`'s pool counts, and `std.Io.async` may run its function inline whenever that pool is full: `Threaded` allows itself `cpu_count - 1` tasks, one on a two-core machine, and a caller that awaits a bounded call and then `io.async`s a server can find the pool full for a microsecond and get the server run on its own thread, where `accept` waits for a connection the same thread was about to make. That is not a bug in `Threaded`, it is `async`'s contract (the function *may* be called before `async` returns): anything that has to be on another thread asks for `io.concurrent`, which either is or says `ConcurrencyUnavailable`.

### A bound on silence is not a bound on the call

`timeout_ms` bounds a whole call, and for a download that is the wrong shape: the segment's call *is* the transfer, so the only honest `timeout_ms` is zero, and that leaves a segment whose peer went quiet with nothing to end it. `stall_ms`, beside `timeout_ms` on `Settings`, `Call` and `Begin`, ends the call with `error.Stalled` when no byte has reached this side for that long. Zero (the default) means no such bound, and the two compose: `timeout_ms` is the ceiling on the whole call, `stall_ms` is the ceiling on silence inside it, and the clock starts at `begin` so a head that never arrives is silence too. This is not a per-read timeout of the kind rejected below: the earlier rejection is for a server sending one byte a second, which satisfies any per-read limit and never finishes, and *is* slow rather than stalled. `stall_ms` guards a different failure, a peer that sends *nothing* and holds the socket, a CDN edge that lost its origin, a NAT that dropped the mapping, a Wi-Fi handover.

**The chunk is noticed by an unbuffered `std.Io.Reader` in front of std's body reader**, installed only when `stall_ms` is set: its `stream` and `discard` hand through to the inner reader and stamp the moment. Every way of reading the body goes through it, so nothing is rewritten as a loop. Then each mechanism above is armed for the second clock the same way it was for the first. Under an Engine there is one timer, armed for whichever bound is nearer, and the tap re-arms it on every chunk; `stall_armed` remembers which bound it stood for, so `blame` names the failure `Stalled` or `TimedOut` from that rather than from a clock comparison. Without an Engine, the wait in `bounded` is re-read from the last byte: the step still runs as one task, the caller's wait is the shorter of the call's deadline and `last_byte + stall_ms`, and the tap moves `last_byte` from the task's thread, so a moving transfer wakes the waiter once per `stall_ms` and never cancels it. `error.Stalled` is a separate error from `error.TimedOut` because a caller does different things with them: a stalled segment is restarted on a fresh connection and does not count as a failed attempt, a timed-out probe is a server that cannot carry the load. `Exchange.stream(w, limit)` gives a caller writing its own chunk loop, such as fdm's segment loop, a read that runs inside both clocks; reading `ex.reader` directly does not, because there is nothing to cancel out there. A call whose own clock has fired is not drained afterwards, under either mechanism, because a leftover from a peer that went quiet is a read that never returns.

**An upload counts too.** While a `.stream` body goes out nothing arrives from the peer, so without a stamp a transfer longer than `stall_ms` would be `Stalled` however fast it moved. With a `stall_ms` the source is read through the same tap, so every chunk that leaves it moves the silence clock, and the clock starts again at the last byte sent once the head is awaited. The write buffer is a kilobyte, so a chunk out of the source is a chunk on its way to the socket, and a peer that stopped reading blocks the write and stops the stamps.

With this, fdm's segment task returns `error.Stalled` and its own watchdog goes: the `last_seen`, `last_moved_ms` fields, the comparison, and the `future.cancel` it called by hand. The rate sampling across segments stays, because that is a decision across sixteen connections and nilo sees one.

## What was rejected

**`io.async` + `future.cancel`, entirely inside std.** Needs no seam at all, race the operation against a timer, cancel the loser. It costs a fiber: `asyncImpl` reaches `spawnTask`, and a handler's stack is carved out of a slab per connection ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)), a per-in-flight-operation cost on an axis ADR 017 treats as an invariant, paid forever to avoid one struct in Core.

**Widening `nilo_start` to three parameters for everybody.** Breaks every Service already written outside this repository for a parameter most will not use. The two-arity hook costs one `comptime` branch at startup and breaks nothing.

**A second marker, `nilo_limits(self, limits)`.** Splits one moment into two hooks that are always called together; a Service that declared one and forgot the other would build, run, and never bound anything, a silent failure of exactly the shape this repository spends its refusals on.

**Leaving it out, and saying so.** [ADR 043](./043-a-deadline-needs-a-connection-you-hold.md) refused `Db.Opts.statement_timeout_ms` on the grounds that an option declared, plumbed and silently doing nothing is a defect. That argument cuts the other way here, because cancellation *does* reach through `std.Io.net` and `std.http.Client`, so a deadline built on it is enforced rather than decorative.

**Fitting it to `nilo_s3` alone.** The seam wants two callers or the one that turned up first; the second is already here and is not S3: `db.select` outside a transaction has no deadline today, and `Limits` gives it one that does not depend on Postgres cancelling anything.

**Refusing a non-zero `timeout_ms` at `nilo_start` with no Engine.** Honest and cheap, and it leaves every CLI writing its own watchdog, the thing fdm did and the thing this exists to make unnecessary. The refusal is kept as the fallback for an `Io` that cannot spawn at all: a single-threaded one gets `ConcurrencyUnavailable` from `io.concurrent`, and the call then runs unbounded exactly as before.

**A watchdog task that shuts the socket down.** Sleeps and calls `shutdown(2)` on the connection, which unblocks a read on Linux, but cannot reach the connect: before the socket exists there is nothing to shut down, so DNS and the handshake would still be outside the deadline. Cancelling the task covers those too.

**A `Limits` implementation for `Threaded`, so `Bound.arm` works there.** The vtable arms against *the current fiber*, and `std.Io` gives no handle to the current task, only the spawner holds the `Future`. The shape does not fit the API, and forcing it would put a thread-cancel in Core.

**Per-read timeouts, for the call and again for the stall.** `std.Io.net` has none, and a server sending one byte a second satisfies any per-read limit and never finishes, which is why the call's own bound has to be end-to-end and why the stall bound is a clock on silence rather than on reads.

**Re-running each step as a loop of chunk-sized tasks with no Engine.** Costs a thread hop per chunk rather than per call, and makes `take` and `pipe` two implementations each. One atomic and one wait per `stall_ms` gets the same answer from one task.

**A second `Bound` for the stall under the Engine.** 192 bytes of Engine slot on every handler's stack that dials out, for a bound never armed at the same time as the first: at any moment exactly one of the two is nearer, so one timer, re-armed for whichever is closer, is enough.

**Leaving the stall to the caller.** The watchdog fdm wrote, recounting a number, when the last byte landed, that only the reader has.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | None. `Bound` is fixed storage on the caller's stack, and `io.concurrent` on `Threaded` takes memory from its own pool; the live test that counts allocations still counts none. |
| Memory per idle connection | None from a handler that never arms one. `Limits` is two words held once per Service, and `Bound`'s storage is stack a handler touches, so it is a per-connection cost only for a handler that arms one, bounded by the 192-byte slot ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)). `@sizeOf(Exchange)` moved 928 → 992 for the stall tap reader, measured at 5,000 connections against `nilo_fetch`'s own `/call`, and read as unchanged once landed beside the same-diff removal of `Client.send`'s 4 KiB transfer buffer ([`bench/result/fetch.md`](../../bench/result/fetch.md)). |
| Throughput and p99 | None for a call that arms nothing. One indirect call and one timer registration for one that does, against a network round trip. With no Engine and a bound set: one thread hop per step; with `stall_ms` set, one indirect call and one atomic store per chunk, and under an Engine one timer release and arm per chunk. |
| Binary size | Zero for a program that arms nothing: the vtable is the no-op pair `Deadlines` already uses as `off`, and the engine's timer is not reachable. Not separately measured for a program that does. |

`nilo_mail` and `nilo_redis` are unblocked by this, and were never blocked by the absence of a way to dial out: whoever writes one takes `Limits` through `nilo_start` and owes an ADR about what it bounds, not about how it opens a socket. `nilo_sql` gains a deadline it could not have before, on its own schedule: `db.select` outside a transaction, which [ADR 043](./043-a-deadline-needs-a-connection-you-hold.md) refused because two round trips per query was worse than not having the feature, and a client-side bound is neither round trip. The Bulkhead's contract list grows by one item, an Engine that cannot cancel an operation in flight can no longer meet what `http/bulkhead.zig`'s header comment asks of it, and a cancelled outbound connection is not returned to any pool: whatever was half-read is half-read, and the caller marks it closing and pays a fresh handshake.
