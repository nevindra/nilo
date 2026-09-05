# 0117 — a guard against a double release is not a Debug trap

**Status:** accepted

## Context

`Streamed.close` gives a pool connection back. It looked like this:

```zig
closed: if (traps_enabled) bool else void = if (traps_enabled) false else {},

pub fn close(self: *Rows) void {
    if (traps_enabled) {
        if (self.closed) return;
        self.closed = true;
        self.db.hold(&self.db.open_streams, .Sub);
    }
    self.w.drain(&self.rows);
}
```

`traps_enabled` is `builtin.mode == .Debug`. So in ReleaseSafe — the mode
people deploy in — the whole guard compiled away and `drain` ran on every call.
On the Postgres Wire that is `result.deinit()` twice and `conn.release()`
twice, which hands the pool a connection it is already holding.

The field's own doc named the case and only counted it: "`close` being called
twice through two copies would take the count below zero." The count was the
part that was protected. The release was not.

**It is reachable from the shape the API teaches.** `rows.close()` on a path
that stops reading early, plus the `defer rows.close()` the doc comment on
`stream` recommends on the line above, is exactly two calls. A `Streamed` is a
value the handler holds, so two copies close twice as readily as one does.

The SQLite Wire's own `Rows.closed` is an unconditional `bool` and never had
this, which is what makes it an oversight rather than a trade.

It was invisible because the test that closes twice — `streamAndClose` — only
ever asserted on `open_streams`, and `open_streams` is Debug-only. In
ReleaseSafe the test ran the buggy path and checked nothing.

## Decision

**`closed` is a plain `bool` and the guard is outside the `if`. The counter
stays Debug-only.**

```zig
closed: bool = false,

pub fn close(self: *Rows) void {
    if (self.closed) return;
    self.closed = true;
    if (traps_enabled) self.db.hold(&self.db.open_streams, .Sub);
    self.w.drain(&self.rows);
}
```

That splits the two things the old code had welded together. `open_streams`
watches a result set nobody closed and is a development aid: paying for it in a
release build would be a trap running where nothing reads it, and it is right
that it is Debug-only. Handing the pool a connection twice is a correctness
failure in the mode people deploy in, and a guard against it is not a trap.

## What was rejected

**Leaving it and documenting the rule** — "close a `Streamed` once". Every
other double-free in this repository is refused rather than written down, and
the shape that provokes it is the shape the doc comment recommends.

**Making `drain` idempotent on each Wire instead.** It moves one guard into two
implementations and puts the obligation on every future Wire, where the caller
that can actually see the double call is right here.

**Making `Streamed` non-copyable**, which is the root cause and which Zig has
no way to express.

## What it costs

**One byte on the stack of a handler that streams, and nothing at all to one
that does not** — `Streamed(Row)` is a value the handler holds, and it already
carries two pointers and the Wire's `Rows`, so in practice the `bool` lands in
padding.

Nothing per request, nothing per connection, no allocation, and one predictable
branch on a call that is about to do a round trip's worth of work.

## What holds it

`wire.Fake` counts drains rather than flagging them, because `Rows.drained`
cannot tell one from two. The test that closes twice now asserts
`db.wire.?.drains == 1` **outside** `if (traps_enabled)`, which is the whole
point: the assertion that was behind the flag is why the bug shipped in the
first place.
