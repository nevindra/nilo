# 0116 — a queue per question, not one condition for two

**Status:** accepted
**Amends:** [ADR 0074](./0074-one-writer-is-not-a-setting-it-is-the-database.md)

## Context

The SQLite pool is one writer at index 0 and read-only connections after it
(ADR 0074). Both halves queued on the same `std.Io.Condition`:

```zig
fn takeWriter(self: *Self) wire.Error!usize {
    while (self.conns[0].busy) self.free.wait(self.io, &self.lock) …
}

fn takeReader(self: *Self) wire.Error!usize {
    while (true) {
        for (self.conns[1..], 1..) |*conn, i| { if (!conn.busy) { … return i; } }
        self.free.wait(self.io, &self.lock) …
    }
}

fn release(self: *Self, at: usize) void {
    …
    self.free.signal(self.io);
}
```

Two waits on one condition, testing **different predicates**, woken with
`signal`. So a returning *reader* could wake the fiber queued for the *writer*,
which re-tested `conns[0].busy`, found it still true and went back to sleep —
and the fiber that had asked for a reader was never woken at all, though the
connection it wanted was sitting free. It sleeps until some later release
happens to pick it.

Under a load that both reads and writes that is a request which stalls with
nothing in the log and nothing holding it. Under a load that stops, it is a
request that never finishes.

This is separate from `timeout_ms` doing nothing on this Wire, which is its own
open entry: a deadline would turn the stall into a `TimedOut` rather than stop
it happening.

## Decision

**One `Condition` per predicate, and `broadcast` rather than `signal` within
each.**

`free_writer` and `free_reader`, and `release` picks by which connection came
back:

```zig
if (at == 0) self.free_writer.broadcast(self.io) else self.free_reader.broadcast(self.io);
```

The two cannot serve each other, which is what makes the split exact rather
than a heuristic: there is exactly one writer, so a returning reader can
satisfy nobody in `takeWriter`, and a returning writer can satisfy nobody in
`takeReader`.

**`broadcast` is the second half and it is not redundant.** This Wire's wait is
cancellable on purpose — `takeWriter`'s own doc says a fiber whose request is
gone gives its turn up rather than holding it — and a `signal` consumed by a
waiter that then answers `TimedOut` is a wakeup nobody else receives. That is
the same lost-wakeup arriving by a different road. Waking everybody queued for
the one thing that just became free costs a re-test of one `bool` each, on
fibers that are by definition already waiting.

## What was rejected

**`broadcast` alone, keeping one condition** — the one-word fix the roadmap
named. It is correct, and it wakes every fiber queued for either resource on
every release, so a writer-heavy load repeatedly wakes every reader-waiter to
send it straight back to sleep. Two `Condition` fields cost sixteen bytes on a
`Wire` a program has one of.

**Two conditions with `signal`**, which is the version that looks tightest. It
reintroduces the lost wakeup through cancellation, which is the failure mode
this whole entry is about, and CLAUDE.md's own rule — a wait needs a bound and
the giving-up path needs to set something — is what it violates.

**Recording which fiber holds the writer**, so a self-deadlock could answer
`Locked`. That is the other open entry on this pool and a different question;
this ADR is only about waking the right queue.

## What it costs

Two `std.Io.Condition` fields on the `Wire` instead of one — a pool per
program, not per connection. Nothing on the path that finds a connection free,
which is every path that is not already waiting.

## What holds it

`sql/sqlite.zig` takes every connection, parks one fiber on each queue, gives
back *only* a reader, and requires that the reader-waiter is the one served.
**If that test ever hangs, the pool has lost a wakeup** — that is the failure
it exists to catch, and the diagnosis is `ps -o etime,cputime` showing minutes
of wall against no CPU.

Writing it turned up something worth knowing on its own, and it was **measured
rather than read off the doc comment**, because the first version of this
paragraph was a plausible inference and this repository has been wrong four
times that way. On this box:

```
cpuCount = 2
resolved async_limit = 1
main=3410304 first=3410305 second=3410304
second ran inline on main: true
```

`std.Io.Threaded`'s default `async_limit` is one less than the number of
logical cores, and past that limit `io.async` runs the task **on the caller's
thread** rather than queueing it — documented behaviour, not a fallback for an
error. On a two-core box the limit is one, so a test wanting two parked fibers
deadlocks in a way that looks exactly like the bug it is testing for.
`withIoPair` asks for the room.

**The hazard is latent rather than active, and that distinction was worth
checking.** Every `io.async` in this repository is one per test body —
sixteen in `fetch/live.zig`, fourteen in `s3/canned.zig`, all of the shape
"stand a canned server up, then be the client". Nothing else has ever had two
outstanding, which is why a green suite says nothing about it and why no
existing call site needs changing. What needs to know is the seventeenth.
