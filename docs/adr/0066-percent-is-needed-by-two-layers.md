# 0066 — percent encoding is needed by two layers

**Status:** accepted

## Context

`percent.zig` lived in `http/`. It decoded, and nothing encoded, because the
App layer is the only thing that had ever needed either half: a path param and
a query value arrive escaped and are decoded on the way in.

Signing a URL needs the other half. AWS SigV4 builds a canonical request out of
escaped pieces, and `nilo_s3` is being designed around one. That caller is a
Service — it needs the event loop and does not own it, so by
[ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md) it sits beside
`nilo_sql`, and by [ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)
it may import downward only. `nilo_http` is a sibling. `zig build layering`
refuses the import, and the `layers` table in `build.zig` is where that refusal
is written rather than in a paragraph.

So an encoder written in `http/percent.zig` would have been unreachable by the
only caller that wanted one, and the encoder would have been written a second
time in `s3/`. Two implementations of RFC 3986 in one repository, disagreeing
eventually rather than immediately — the failure mode is a signature that is
rejected with no indication of which byte differed.

The roadmap had already named this file for exactly this reason, under
*Where `convert` belongs*: "`percent.zig` is the likelier candidate for the
same reason it always was: signing a URL needs the encoding half, and whoever
signs one is not down here."

## Decision

**`percent.zig` moves to `core/`, and the encoding half is written there.**

`nilo_core` exposes it as a namespace — `percent.decode`, `percent.encodeInto`
— rather than as flat names, because it is the one thing in Core with two
directions and a set to choose between.

Three things about the encoder are behaviour rather than options, and each one
is a silent failure that a parameter would have made reachable:

- **A space is `%20`, never `+`.** The `+` convention is HTML form bodies,
  which this direction does not write.
- **Hex digits are uppercase.** `%2f` and `%2F` are the same character to a
  decoder and different bytes to anything that signs them.
- **There is no allocating encoder.** `decode` has one because the request path
  decodes into an arena whose sizing it does not own. Whoever encodes is
  assembling a canonical string into a buffer it has already measured
  (`encodedLen` + `encodeInto`) or writing it straight out (`encodeWrite`).

What varies is one character: whether `/` is a separator or data. That is
`Set.path` and `Set.unreserved`.

## Why this is allowed, and what it does not decide

The entry condition for the bottom layer is that its tests need no module graph
([ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)).
`percent.zig` imports `std` and takes an allocator as an argument, so
`zig test core/core.zig` still runs the whole of Core — 32 tests, no
`build.zig`. The `.{ .root = "core", .may_import = &.{} }` row is unchanged.

Core's own rule is stricter than the layering: **a file earns its place by
being needed by two layers, not by having nowhere else to live.** This is the
first file admitted by passing that test rather than by being there from the
start. The App layer decodes on every request; a Service encodes when it signs.

**This settles nothing about `convert`.** That file has stayed in the App layer
because it reaches the Bulkhead to say a request failed, and a Core cannot do
that. Neither direction here can fail — an encoder has nothing to reject, and
the decoder is deliberately written not to (a `%` without two hex digits stays
a literal `%`, because servers that are strict there mostly succeed at turning
a harmless URL into a 400). There is no failure to hand upward, which is why
this move was cheap and why the `convert` question is untouched by it.

## What it costs

Nothing on any of [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four
axes.

- **Allocations per request:** unchanged. The decoder is the same code with the
  same single allocation, taken only when there is something to decode.
- **Memory per idle connection:** unchanged. Nothing here is held between
  requests.
- **Throughput and p99:** unchanged. Same functions, same call sites; the
  import line moved.
- **Binary size:** the encoder is three functions nobody calls yet, and the
  linker drops what nobody uses. A server that never signs a URL links none of
  it.

## Alternatives rejected

**Write the encoder in `http/percent.zig` anyway, and a second one in `s3/`.**
The diff is smaller and the outcome is two implementations of one RFC. The
roadmap warns about this shape in advance, which is the whole reason the
warning was written down.

**A sixth module, `nilo_url`.** Forty lines of encoder is not a module, and
[ADR 0043](./0043-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)
is what a module in that layer costs to get right. `percent` has one job and it
already has a home that both callers can reach.

**Leave the file in `http/` and re-export it from `nilo_core`.** Core would
import upward, which is the one thing `zig build layering` exists to refuse.

**Move only the encoder to Core and leave the decoder in `http/`.** One RFC
split across two modules, with `%XX` written in one file and read in another.
The round-trip test that now covers all 256 bytes could not have been written
in either half.

## Consequences

- `http/ctx.zig` reaches it through `nilo_core` rather than a sibling file, and
  its six `percent.decode` calls are otherwise unchanged.
- `http/http.zig`'s `test` block no longer lists `percent.zig`. It never listed
  a Core file — the comment above that block says so — so this is the rule
  being followed rather than an exception being made.
- `zig test http/percent.zig` is gone as a command. `zig test core/core.zig` is
  what runs these tests now, and it is the stronger property of the two.
- `nilo_s3` will name `nilo_core` in its `layers` row. It was going to anyway:
  its `get` returns a `Str`, and a Service reaches request-lifetime memory
  through a Scope. `percent` costs it no import it did not already have.
