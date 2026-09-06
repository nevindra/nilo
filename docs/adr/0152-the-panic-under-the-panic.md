# The panic under the panic

A caller reported that nilo panics on the way out when it decides **not** to
start — a bad connection string, or `db.checking` finding a Row that disagrees
with its table. The trace named a dependency:

```
xsync/src/Mutex.zig:66:17: in unlock
        else => unreachable,
pg/src/pool.zig:318:32: in run
        defer self.mutex.unlock(io);
```

That is pg.zig's `Reconnector.run`, and the bug is four lines of it:

```zig
self.mutex.lockUncancelable(io);
defer self.mutex.unlock(io);      // 318
loop: while (self.count > 0) {
    const stopped = self.stopped;
    self.mutex.unlock(io);        // 321 — unlocked here
    if (stopped == true) return;  // 323 — returns unlocked; the defer unlocks again
```

`xsync.Mutex.unlock` swaps in `unlocked` and switches on what was there.
`unlocked` is the third arm, and the third arm is `unreachable`. An eight-line
program that locks once and unlocks twice reproduces the frame exactly.

**Fixed upstream** in
[`91d0705`](https://github.com/lalinsky/pg.zig/commit/91d07055c57b80de1fb4c91129d56ecd9799bce8),
"Fix double-unlock in the pool's reconnector", eight days before it was
reported here. The pin was two commits behind. It is now on that commit.

## The part worth writing down

Bumping the pin did not fix the reported symptom. It changed it.

The same commit moved the reconnector from `Thread.spawn` to `Io.Group`, so
what used to be an OS thread became a task on nilo's own event loop — and
nilo had no way to stop a service before tearing that loop down. The panic came
straight back from a different file, as zio's `task_count == 0` assert
([ADR 0151](0151-a-service-is-stopped-before-the-loop-is.md) is that fix).

So there were two bugs stacked, one hiding the other, and **the upstream one
was on top**. The obvious move — read the trace, see a dependency, report it
upstream, stop — would have been right about the frame and wrong about the
afternoon.

What made the difference was reproducing it rather than reasoning about it. Two
programs: one that refuses to start, one that boots with the database down and
is then stopped normally. Running both against **both pins** is what turned
"upstream fixed it" into a table:

| | old pin | new pin | now |
|---|---|---|---|
| refuses to start | panic (double unlock) | panic (task_count) | exit 0 |
| ordinary shutdown, database never up | panic (double unlock) | panic (task_count) | exit 0 |
| ordinary shutdown, database healthy | clean | clean | clean |

The middle row is the one nobody reported and nobody would have predicted from
the trace. It is also the row that says how wide this was: every deploy where
Postgres is down.

**A dependency bump is not verified by the suite that passes after it.**
`zig build test-all` was green on the new pin while both reproductions still
panicked, because neither of them is a thing the suite does — the suite has a
database, and it never watches a server refuse to start. The verification that
counted was two throwaway programs and four runs.

## Why not vendor the patch instead

It was one line and the temptation was real. Copying a fix into a vendored
dependency means carrying it forever, re-applying it on every bump, and being
the only person who knows it is there. Upstream had already fixed it, the pin
was two commits behind with `behind_by: 0`, and both commits were small.

The general rule this repository keeps
([ADR 0063](0063-a-handlers-stack-is-per-connection.md)'s lesson): **a blocker
that names somebody else gets checked before it is believed.** Here the check
took one request and the answer was "fixed eight days ago".

## Consequences

- `build.zig.zon` pins pg.zig at `91d07055`, which also brings
  "Use std.Io for socket shutdown".
- `sql/live.zig` still opens its pool with `connect_on_init = 2`, and the
  comment above it still says why — that the reconnector cannot park under
  `std.Io.Threaded`. **That may no longer be true** now that it is an
  `Io.Group` task rather than a thread, and it has not been re-tested. It is a
  harness constraint either way, so it costs nothing to leave; somebody
  removing it should run `test-sql` against a real Postgres and watch it, not
  assume.
- No axis moves. Nothing here is on a request path.
