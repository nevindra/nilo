# The bottom layer holds more than one module, and knowledge points down with the imports

[ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md) cut the repository
into three layers and put one module in each. Core was `nilo_core` and nothing
else, so two of its sentences had never been tested against a second module:
*nothing imports a sibling in its own layer*, and *Core is the vocabulary, not
a drawer*.

`nilo_id` is where both come due. It needs no event loop, so the layer table
puts it in Core — beside the vocabulary, which the sibling rule forbids it to
import. And it wants the type `nilo_sql` already has: `sql.Uuid` is sixteen
bytes with a `writeText`, and generating a key is the same sixteen bytes. Two
`Uuid`s in one build is the worst of the available outcomes, because
`db.insert` would refuse a generated key with a message about a type spelled
exactly like the one it wants.

`docs/roadmap.md` had this queued as the item that could not be built until it
was answered — *either the Service imports the tool module, which makes* tool
*a rank between Core and Service, or the type moves into Core, which the
two-layer rule permits and the "not a drawer" rule resists.* It turns out to be
neither.

## What was decided

**The Core layer holds as many modules as it needs, and `nilo_core` is below
all of them.** The vocabulary is not a sibling of anything — that is what a
vocabulary *is*. So the rule reads:

| Module | May import | Imported by |
|---|---|---|
| `nilo_core` | nothing of nilo's | everything |
| a **tool module** — `nilo_id`, and the ones after it | `nilo_core` | an App, a Service, another program |
| an App or a Service | `nilo_core`, any tool module | — |

A tool module still may not import another tool module, and that is the half
of ADR 0041's sentence that is doing the work: it is what keeps two of them
separate pieces of work. Nothing about the vocabulary was ever separate.

**A Service imports a tool module, and that is downward rather than sideways.**
`nilo_sql` names `nilo_id` in `sql/types.zig` and re-exports the type, so
`sql.Uuid` is what it always was and nothing anybody wrote changes.

**A type sits in the lowest module that has a use for it. The opinion about it
stays where the opinion is.** `Uuid` moved down; `pub const nilo_column =
"uuid"` did not move with it. That declaration is a database's opinion about a
value, and a Core-layer type carrying it would be a module in the bottom layer
knowing about a layer above — *imports* would still point downward while
*knowledge* had quietly stopped. `sql/types.zig` answers for it instead, in one
line of `declaredColumn`, which is the general rule:

> **A marker on a type is an import you cannot see.** If a module below has to
> declare something only a module above understands, the type is in the wrong
> place or the marker is.

**A module in the bottom layer runs under plain `zig test` or it is in the
wrong layer.** `zig test id/id.zig` is the whole of `nilo_id`. That was
ADR 0041's claim for `nilo_core`; it is now the entry condition for the layer
rather than a property one module happens to have.

**And the rule is held by a build step.** `zig build layering` reads every
`.zig` under `core/`, `id/` and `sql/`, pulls the module names out of their
`@import`s, and refuses any that is not in that module's row of the `layers`
table in `build.zig`. It hangs off `test`. ADR 0041 said this needed to exist
or the layering was a paragraph; it exists.

## Why not the alternatives

**Leave `Uuid` in `nilo_sql` and have `nilo_id` generate bytes.** `v7` would
answer `[16]u8` and a caller would write `sql.Uuid{ .bytes = id.v7(…) }` at
every insert. Two types for one value, a conversion at each call site, and —
worse — two `parse`s and two `writeText`s to keep in step. The first time they
disagreed about whether hyphens are optional, the bug would be in whichever one
the reader did not open.

**Move `Uuid` into `nilo_core`.** The two-layer rule permits it: an App
returning one from a handler and a Service reading one out of a column is two
callers. The not-a-drawer rule refuses it, and this is exactly the case that
rule was written for. Core is what every layer *agrees about* — `Str` is in
every signature nilo has — and an HTTP server has no opinion about UUIDs at
all. Admit one and `Timestamp` follows on the same argument, and then Core is
the place things go when they fit nowhere, which is the outcome ADR 0041 opened
by refusing.

**A fourth layer, so that "tool" is a rank.** ADR 0041 refused a fourth layer
and the refusal holds, for the reason it gave: a layer is worth having when it
changes what a module may import. A tool module's rule *is* Core's rule — it
needs no loop, it imports `nilo_core`, it runs under plain `zig test`. Naming a
rank "tools" would add a word to the table without adding a rule to the build.

**An umbrella `nilo` module re-exporting the tools**, so that one import brings
`id`, `core` and the rest. Refused in ADR 0041 and refused harder now: with two
tool modules it costs a project the bytes of both, and the whole measurement
below is that a project pays only for what it names.

**Have `nilo_id` fetch its own randomness.** This is the one that changed the
shape of the module, so it gets its own section.

## What `nilo_id` is, and the thing it is not

**In Zig 0.16, entropy and the clock are both IO.** `std.crypto.random` is
gone, `std.time.milliTimestamp` is gone, and what replaced them —
`std.Io.randomSecure`, `Io.Clock.now` — takes an `Io`. That is not an
inconvenience; it is the standard library agreeing with ADR 0041's question.
Asking the operating system for entropy is a syscall, and nilo routes it
through `bulkhead.randomSecure` for exactly one reason: *a syscall made
straight from a fiber stops every request sharing that thread*
([ADR 0002](./0002-zio-as-the-engine-behind-the-bulkhead.md),
[ADR 0014](./0014-handlers-must-not-block-the-thread.md)). A module in the
bottom layer has no Bulkhead to reach through.

So `nilo_id` ships **the format and not the source**:

```zig
pub fn v4(entropy: [16]u8) Uuid
pub fn v7(entropy: [10]u8, ms: u64) Uuid
```

Where the version bits go, which six bytes hold the millisecond, how sixteen
bytes are written as thirty-six characters, and how they are read back. Pure
functions of their arguments, which is also what makes the claim v7 exists for
— *two a millisecond apart sort the way they were made* — a test rather than an
assertion.

**What is missing is a supported way for a handler to get either input**, and
saying so is the point of this section. `Ctx` exposes no clock and no entropy
today, so inside a request the arguments to `v7` have nowhere to come from.
That is the same missing seam ADR 0041 already recorded pointing outward —
*the Bulkhead covers the way in and nothing covers the way out* — arriving from
a third direction, and it is its own decision:

- The shape is known, because ADR 0040 already built one. *A module beside the
  framework needed a supported way to allocate for a request*, and the answer
  was two calls on `Ctx` that Core then named — which is what a Scope is. The
  second pair would be `entropy()` and a wall clock, checked the same way.
- What is not known is what a `Run` does with them. A Scope's `arena()` and
  `str()` are pure bookkeeping and a `Run` implements both in Core with no IO
  at all. Entropy is not, so either `Run` holds an `Io` — Core doing IO, which
  is a real amendment to what Core is — or the second pair belongs to something
  that is not a Scope. Nobody has designed it, and designing it inside the
  session that needed a UUID is how a seam gets fitted to one caller.

**A feature that cannot be made to fit does not ship in a worse shape.** The
shape that fits today is the format; a v4 whose entropy came from a seeded
`DefaultPrng` is a predictable session token, and a `v4()` that quietly did
that would be worse than one that asks. The doc comment says so at the
function.

## What it costs

Put against the four axes
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)).

| Axis | Cost |
|---|---|
| Allocations per request | **none.** Nothing here is on the request path, and nothing in `nilo_id` allocates at all — `toText` answers a `[36]u8` by value. |
| Memory per idle connection | **none.** Nothing is per-connection. |
| Throughput and p99 | **none.** No framework path changed. |
| Binary size | **zero** for a project that does not import `nilo_id`, and **16 bytes** for one that does. |

Both halves measured rather than assumed, stripped `ReleaseFast`, against a
build of the parent commit in a `git worktree` — the method `docs/history.md`
settled on:

| | Before | After |
|---|---|---|
| `example-hello` | 885,504 | 885,504 |
| `example-rest` | 1,031,744 | 1,031,744 |
| `nilo-hello` | 890,384 | 890,384 |

Byte for byte, all three, and the same three numbers ADR 0041 recorded — which
is the property being checked rather than a coincidence: `nilo_sql` gained an
import and no binary that does not name `nilo_sql` can tell.

The 16 bytes are the other direction, measured on two programs identical except
that one calls `v7` and prints the result: 216,568 against 216,584. `toText`
inlines into its caller and what is left is the version bits and a `memcpy`.
The number is small because the module is the format; a generator with a
threadlocal CSPRNG in it would not be.

## What the wiring settled

**A shared module is load-bearing twice now, and the second time has no
symptom either.** `build.zig` builds one `nilo_id` per optimize mode and hands
the *same* one to `nilo_sql` and to anything else in that mode. Two modules
built from one root file are two different modules to Zig, so a second copy
would make `id.Uuid` and `sql.Uuid` distinct types that print identically —
`db.insert` would refuse a generated key with a message naming the type it was
given and the type it wants, and they would be the same words. ADR 0041 hit
this with `core.Str`; `sql/types.zig` now carries the test for this one, which
is the only thing that would notice.

**The scan cannot see a test, so the exception is written down instead.** A
module's tests may name one layer up, because an `@import` reached only from a
`test` block is never analysed in a build that is not a test build (ADR 0041) —
and `sql/db.zig` drives a whole request through a real App that way. Telling
that apart from an ordinary import needs a parser rather than a scan, so the
`layers` table has an `in_tests` list that the step allows and does not verify.
It is weaker than the rest of the step and it is written down at the table, on
the grounds that a rule with a listed exception is still a rule and a rule in a
document is not.

**The scan does have to see a comment.** Every module root in this repository
opens with a doc comment showing how somebody else imports it — `//! const id =
@import("nilo_id");` — and the first run of the step refused two modules for
documenting themselves correctly. Skipping a `//` line is enough; a real
`@import` is never written after one.

## Consequences

- `nilo_id` is the first module a project can import with no server anywhere in
  the process, which is the claim ADR 0041 made about the framing and could not
  demonstrate with one Core module.
- `CONTEXT.md` gains **tool module**. `nilo_core` stops being *the* bottom
  layer and becomes the bottom of it.
- **`sql.Timestamp` is the next one to ask this question**, and the answer is
  probably different: a `Timestamp` is a column type that a handler happens to
  return, where a `Uuid` is a value that a column happens to hold. It stays put
  until something outside `nilo_sql` wants to make one — which is the same
  "second caller" test ADR 0041 applied to `convert.zig` and `percent.zig`.
- A tool module that needs the operating system for anything is blocked on the
  seam above until somebody designs it. `nilo_id` fits because sixteen bytes and
  their spelling need nothing; a password module hashing with argon2 needs to
  get *off* the loop, and an S3 module needs to dial out. All three are the same
  missing decision, and it is now the thing standing in front of the layer
  rather than a footnote in it.
