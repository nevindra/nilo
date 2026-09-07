# A check pays for its own branches

Sixteen `named` routes on one group stopped compiling:

```
http/app.zig:2015:9: error: evaluation exceeded 1000 backwards branches
```

Line 2015 is inside `checkName`, which walks an `operationId` a byte at a time
to be sure a client generator can turn it into a method name (ADR 0149). The
message names a file in nilo and whichever route the walk happened to be on, so
it reads as a problem with that route. The caller's fix was
`@setEvalBranchQuota(20_000)` at the top of their own `register`, and finding it
took a while.

## Whose budget it is

`@setEvalBranchQuota` raises a ceiling on the **caller's whole comptime
evaluation**, not on one call: a comptime function call is analysed inside the
caller's evaluation, so every route's bytes count against one budget. Two things
follow, and they were both measured before this was written rather than assumed:

- a value set inside a comptime-called function does reach the caller;
- a later, smaller value does not lower it — the compiler keeps the larger.

So a framework that spends a caller's budget can raise it, and only the
framework knows how much it is about to spend.

## What it does now

```zig
@setEvalBranchQuota(10_000 + 1_000 * (name.len + 1));
```

**Generous rather than exact**, and that is what the quota is. An exact
`name.len` would be right for the first route and short by the two hundredth,
because the budget is shared and the consumption accumulates. What this buys is
that nilo's own walk is never the thing that runs out; a caller whose comptime
work genuinely needs more still raises it themselves, and their number wins
because the compiler keeps the larger.

`row.zig`'s `distance` has sized its own quota from its input since it was
written — `@setEvalBranchQuota(10_000 + 64 * (a.len + 1) * (b.len + 1))` — so
this is a rule the repository already had in one module and not in the other.

## The alternatives that were rejected

**One large constant at the top of `register`.** It fixes the same routes and
puts the number where nobody can see what it is for. The next check that walks
something per route would silently eat it.

**Leaving it to the caller and documenting it.** That is the state this came
from. The error names a line in nilo, so the caller has no way to know the
budget is nilo's to raise — and a documented workaround for a compile error is
the thing a build step exists to replace.

## Consequences

- One line in `checkName`, and a test registering twenty long names on one
  group. No run-time cost: a branch quota is a compile-time ceiling.
- The same reasoning applied to `row.isProjection`, where comparing two enum
  literals with `std.mem.eql` on their tag names spent a caller's branches on a
  ten-byte comparison. `==` settles it in one step.
- `operation()` in `typed.zig` already raises its own to 20,000 for a related
  reason and says so; this is the second instance of the same idea, not a new
  one.
