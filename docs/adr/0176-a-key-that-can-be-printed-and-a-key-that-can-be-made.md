# A key that can be printed, and a key that can be made

Two reports about `Uuid` from the same port, a fortnight apart, and they are one
decision: the type carried a value it could not spell and could not produce.

## Printing it

```
error: no field or member function named 'format' in 'uuid.Uuid'
```

So every refusal that named the record it could not find was written the long
way:

```zig
return nilo.fail.notFound("partner {s} not found", .{&id.toText()});
```

An ampersand and a call, five times in one context, in the one place where a
reader is being told what went wrong.

**Two things landed before this and neither reached it.** `writeText(w)` is a
*method*: it answers a caller who already holds a writer and answers nothing at
all to `{f}`, because Zig looks for a declaration called `format` and finds one
or gives up. `testing.show` (ADR 0169) answers the failure-message half, which
was the other place this hurt and is not this place.

`Str` was given `format` for exactly this reason and its comment says why:
printing the value is the first thing anybody writes. `{s}` cannot be made to
work — Zig reserves it for byte slices and a `Uuid` is a struct — so it is `{f}`
here, four lines, and the same thirty-six characters `toText` produces.

## Making one

```zig
const seed = try c.entropy(nid.Uuid.v7_entropy);
const key = nid.v7(seed, @intCast(nilo.nowMillis()));
```

Six times in one context — `partner.create`, `contact.add`, `comment.write`,
`events.insert` and both fixture writers. Neither half is a decision a caller
makes. The `@intCast` is in all six because `nowMillis` answers `i64` and the
field it goes in is a `u48`.

```zig
pub fn v7Now(scope: anytype) !Uuid
```

`scope` is the `*Ctx` a handler was given or a `nilo.Run` built with `initIo`.
The randomness comes from it, the millisecond from the clock, and the cast is
gone.

## The clock is read twice, and that is the cost

`nilo_id` **imports nothing at all**, which is what `zig build layering` holds
and what keeps `zig test id/id.zig` running with no module graph (ADR 0043). So
`v7Now` cannot call `core/clock.zig`, and the alternative to twelve lines of
`clock_gettime` here is an import that moves the module out of its layer.

`http/bulkhead.zig` already keeps its own monotonic clock beside Core's for the
same reason and says so. The two cannot drift in a way that matters: both are
`CLOCK_REALTIME`, and what a caller gets from either is the same instant.

**`v7` stays**, for the caller who has the millisecond already — a backfill, a
key made for a row that existed before it did.

## What it asks for, and where the refusal lives

`v7Now` checks for `entropy` and not for a whole Scope, because that is the whole
of what it uses — and because a second reading of *what a Scope is*, living in a
module that cannot import `core/scope.zig`, is a rule that can drift from the one
the compiler is really enforcing.

The refusal file is in `sql/refusals/` rather than `refusals/`, and that is worth
a sentence: `nilo_id` has no table of its own, the framework's refusals are built
against `nilo_http` alone, and `sql.Uuid` is `nilo_id`'s `Uuid` — the same
declaration, through an import line `sql.zig` documents. A seventh table and a
seventh build step to hold one message would cost more than it checks.

## Against ADR 0018's four axes

Zero on the first two. `format` and `v7Now` are called from handler code, never
from a path nilo takes itself, and neither allocates. Binary size: both are
dropped by the linker in a program that names neither, which is what `nilo_id`
being a module of its own already buys.

## Consequences

- `Uuid` prints with `{f}` wherever `Str` does, which is every fail function and
  every `std.log` line.
- `writeText` stays. It is the same bytes and it is the call for a writer already
  in hand; nothing in the repository had to change.
- `id.v7Now(scope)` is the spelling for a key, and `id.v7(entropy, ms)` is the
  spelling for a key at a time somebody chose.
