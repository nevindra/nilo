# A statement that is a constant can be prepared once

Every statement `nilo_sql` sends is settled while compiling
([ADR 0039](./0039-the-shape-of-a-query-is-settled-while-compiling.md)). That
was decided for the compiler's sake — a query whose shape is known can be
type-checked — and it turns out to hand over a second property nobody was
asking for: **the set of distinct statements a binary can ever send is fixed
when the binary is built.**

That is exactly the precondition a per-connection prepared-statement cache
wants and exactly what a library assembling SQL per request cannot have. Its
key would be a string it had just built, and the cache would grow with traffic
rather than with the program.

`docs/roadmap.md` carried this as the SQL module's Next 1 with one condition
on it: **measure first.** [ADR 0001](./0001-dx-wins-below-the-10-percent-threshold.md)
cuts both ways — a feature buying less than 10% is not worth the surface it
adds either.

## What was measured

`bench/sql.zig`, 20,000 rounds a side after 2,000 warm-up, one connection,
Postgres 16 over a loopback socket:

| | parsed every time | prepared once | saved |
|---|---|---|---|
| a key lookup | 37,690 ns | 26,506 ns | 11,184 ns (**29.7%**) |
| a page with a sort | 94,539 ns | 81,210 ns | 13,329 ns (**14.1%**) |
| `db.find`, whole module | 37,788 ns | 26,432 ns | 11,356 ns (**30.1%**) |

Three things are worth reading off that table rather than the summary.

**The saving is a fixed cost, not a share.** ~12 µs either way. It is Parse and
Describe, and those do not care how much work the statement then does — which
is why the cheap query saves 30% and the expensive one 14%. A service's request
mix is mostly cheap queries, so the number that matters is the first row.

**Even the worst case clears the bar.** 14.1% on a sort-and-range page is
comfortably over ADR 0001's 10%, and that is the *floor* measured here rather
than the headline.

**The module does not eat it.** The third row is the honest check on the first
two: `db.find` builds a parameter tuple, fills a Row and copies its text into
the arena, all of it identical on both sides of the subtraction. If the typed
layer were expensive, the ratio would have collapsed up there. It came out
0.4 points *higher*, and `db.find` costs **about 100 ns more than the raw
driver call it wraps** — a quarter of one percent of a key lookup. That number
is the whole run-time price of the typed layer over this driver, and it had
never been measured before.

## What was decided

**On by default, keyed by a 128-bit hash of the statement text.**

```zig
fn planOf(self: *Self, comptime stmt: statement.Statement) ?[]const u8 {
    if (!self.opts.prepared) return null;
    return comptime statement.planName(stmt.sql);
}
```

The name is a comptime constant, so the run-time cost of the whole feature is
one load and one test per query.

### Why the name is the text, and why it is 128 bits

A cache hit re-binds against the **stored** describe without looking at the SQL
again. Two statements sharing a name therefore means one of them silently runs
the other's plan.

This is not theoretical. `bench/sql.zig` reused one `cache_name` for two
statements while it was being written, and pg.zig answered
`WrongNumberOfParameters` — it compares the parameter *count* against the
cached describe and nothing else. **Two statements with the same arity would
have said nothing at all** and returned the wrong rows.

So the name has to be unique by construction rather than by luck:

```zig
const low = std.hash.Wyhash.hash(0, sql);
const high = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, sql);
break :blk std.fmt.comptimePrint("nilo_{x:0>16}{x:0>16}", .{ low, high });
```

Two independent 64-bit hashes. At 128 bits a thousand distinct statements
collide with probability around 10⁻³⁴; at 64 it would be 10⁻¹⁴, which is small
and is not the same kind of small as impossible. The result is 37 characters,
comfortably inside Postgres's 63-byte identifier limit — over it the name is
*truncated*, which turns a unique name back into a colliding one, so the length
is asserted rather than assumed.

Hashing the text rather than the Row or the call site is the other half: the
cache is keyed by what Postgres parsed, so anything else would be unique and
still wrong.

### Why `db.raw` is never prepared

Its text arrives at run time. There is no comptime name to derive, and no bound
on how many there would be — which is the property this whole design rests on.
`db.raw` passes `null` and always will.

### Why there is an off switch

**A connection pooler in transaction mode.** pgbouncer hands out a different
server connection per transaction, so a statement prepared on one is missing on
the next. `Opts.prepared = false` is the escape hatch, and it exists because
that deployment is common rather than exotic.

The failure it avoids is *loud* — Postgres says the prepared statement does not
exist — which is why the default is the fast one. A silent failure mode would
have argued the other way.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes:

- **Allocations per request.** None. The name is a comptime constant; the
  driver's cache is per connection and allocated when the connection is.
- **Memory per idle connection.** Nothing on an HTTP connection. On a *database*
  connection it is one entry per distinct statement that connection has sent —
  bounded by the program, and paid by pg.zig rather than by nilo.
- **Throughput and p99.** −11.4 µs on a key lookup through `db.find` (30.1%),
  −13.3 µs on a page with a sort (14.1%). This is the one axis a feature has
  ever *bought* rather than spent.
- **Binary size.** +0 stripped ReleaseFast on every example — the name is a
  string constant per distinct statement, and a program that sends none pays
  nothing.

## Consequences

- `wire.run` and `wire.exec` take a `plan: ?[]const u8`. A second driver either
  honours it or ignores it; the Fake records it, which is how the tests hold
  the name without a database.
- The number in the third row of the table above is the typed layer's run-time
  cost, and `bench/sql.zig` now measures it every time it runs. If a DX feature
  ever makes `db.find` expensive, that is where it shows up.
- A pooler in transaction mode is now a documented configuration rather than a
  discovered one.
