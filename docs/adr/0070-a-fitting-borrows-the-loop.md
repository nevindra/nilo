# 0070 — a Fitting borrows the loop and owns no destination

**Status:** accepted
**Amends:** [ADR 0041](./0041-a-module-sits-where-the-loop-puts-it.md),
[ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md)

## Context

`nilo_s3` needs to speak HTTP to an object store. A handler needs to speak HTTP
to Stripe. Both want the same four things in front of `std.http.Client`, and
neither can reach the other's copy:

- `http/` cannot hold it, because a Service may not import `nilo_http` — that is
  sideways, and `zig build layering` refuses it. This is the wall that already
  sent `percent` down a layer ([ADR 0066](./0066-percent-is-needed-by-two-layers.md)).
- `nilo_core` cannot hold it, because Core does no IO at all and a drain policy
  needs `std.http.Client`.
- A module of its own could not be imported by `nilo_s3` either: it needs the
  event loop, which by ADR 0041 makes it a Service, and a Service importing a
  Service is sideways again.

Three shapes were on the table and every one of them is a repository-level
decision rather than a module's: a fourth layer, a relaxation of the
never-a-sibling rule, or two copies of the policy.

**Nobody had asked how big the thing being housed is.** So it was measured
before it was designed around, which is the check
[`history.md`](../history.md) already records as the one worth copying.

## What was measured

`spike/outbound/`, and `./run.sh` there reproduces it. Zig 0.16.0.

| | lines |
|---|---|
| the policy — everything nilo would add | **65** |
| `std/http/Client.zig` | 1,867 |
| `std/crypto/tls/Client.zig` | 1,670 |

**65 lines against 3,537, under 2%.** `std.http.Client` is already the client:
connection pool, HTTP/1.1, TLS. What is missing is policy, and all of it is the
kind a script does not need and a server does.

The spike also answered the question that decides whether a fourth layer can be
*held* rather than merely declared: **its tests run under `std.Io.Threaded`,
with no engine and an empty dependency list.**

## Decision

**A fourth layer, between the bottom layer and Service, called a Fitting.**

> A Fitting borrows the loop and owns no destination. `nilo_fetch` is a
> Fitting; `nilo_sql` is a Service because it holds a pool to a database named
> in its URL.

| Layer | Modules | The loop | Entry condition |
|---|---|---|---|
| Core | `core/` | needs none | `zig test core/core.zig`, no module graph |
| Tool | `id/`, `config/`, `pw/` | needs none | `zig test <m>/<m>.zig`, no module graph |
| **Fitting** | `fetch/` | **borrows** | **`zig test` under `std.Io.Threaded`, no Engine** |
| Service | `sql/`, and `s3/` when it lands | borrows, and holds a named system | needs the module graph |
| App | `http/` | owns it | — |

**The entry condition is the load-bearing half of this**, and it is why the
layer is a layer rather than a shelf. ADR 0042 bought the bottom layer with a
condition somebody can run: tests under a plain `zig test`. A Fitting borrows
the loop so it cannot meet that one — but `std.Io.Threaded` is std's own, so a
module that only *borrows* an `Io` can be driven by one without an Engine
existing. `fetch/live.zig` opens a real socket at both ends and proves it on
every run. A module that cannot be tested that way is holding a connection to
something, which makes it a Service.

That line is sharp in code rather than only in prose: `Client` holds no
credentials and no endpoint, and is given a URL on every call.

## Why not the alternatives

**Relax the never-a-sibling rule — add `nilo_fetch` to `s3`'s `may_import`.**
One line in the `layers` table. It also turns "a module imports downward only,
never a sibling" into "whatever the table says", and the table is the whole
reason the rule is mechanical rather than a paragraph. The value of the rule is
that it cannot be argued with per case; that is exactly what this would spend.

**Two copies of the policy.** What happens by default. It is the outcome
ADR 0066 was written to avoid one layer down, at forty lines; this is the same
mistake at a few hundred, and the second copy would never be deleted.

**Put it in Core anyway.** Core does no IO — that sentence is what makes
`zig test core/core.zig` the whole of it. A drain policy needs
`std.http.Client`, and admitting it would cost the property every other file
down there is holding up.

**Do nothing until a second Fitting exists.** The honest version of this, and
it was close. What decided against it: `nilo_s3` is being designed *now*, and
the policy would be written inside it now. The layer costs an amendment to two
ADRs; the delay costs the thing the amendment exists to prevent.

## What it costs, and the number that argues against it

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes, a
Fitting costs a program that does not import one **nothing at all** — no
allocation, no per-connection memory, no throughput, and zero bytes, because
`nilo_http` does not name `nilo_fetch` and the linker never sees it.

For a program that *does* import one, all four are measured in
[`bench/result/fetch.md`](../../bench/result/fetch.md), each against the same
call made through a plain `std.http.Client` with none of the policy round it —
because the only honest question about sixty-five lines is what those
sixty-five lines cost, not what `std.http.Client` costs.

| axis | `nilo_fetch` | the call itself (std's) |
|---|---|---|
| allocations per call | **1**, the body into the Scope's arena | connection setup only, pooled |
| memory per idle connection | **+1 byte**, which is noise | **+16,495 bytes** |
| throughput | **within ±1%**, below this harness's drift | −40% off the floor |
| binary size, stripped ReleaseFast | **+1,688 bytes** | +655,600 bytes |

The one that matters is the second column's 16,495 bytes: an outbound call is
the most expensive thing a handler can do to the per-connection axis, and by
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) it is held for as long
as the *inbound* connection stays open. It is fiber stack rather than buffers —
moving the two client buffers into the request arena was tried and is worth −66
bytes — so the lever is in `http/`, giving stack pages back between requests,
and not in this module.

**Arming a deadline is free**: two bytes an idle connection and nothing
measurable on throughput, because a 192-byte slot lands inside a page the fiber
had already touched. That was the number ADR 0065's seam most needed and the
one most likely to have gone the other way.

**The argument against this decision is on the record too: the layer's first
tenant is 65 lines.** A layer housing sixty-five lines does not justify itself
by volume, and this one is not claiming to. It justifies itself by where a rule
can be enforced — `zig build layering` reads the `layers` table and refuses an
import that is not in it, and that is a build step rather than a paragraph.
Whoever re-measures and finds 65 lines should find this paragraph before they
find the ADR wanting.

The second Fitting is what will settle whether this was right. If none ever
arrives, this layer holds one module and the decision was expensive.

## Consequences

- **`nilo_fetch` ships**, with `nilo_core` its only import. A gate on
  connections in flight, a deadline per call
  ([ADR 0065](./0065-the-way-out-was-open-the-clock-was-not.md)), a bounded
  drain, a body ceiling, and a `Str` in the caller's Scope.
- **`build.zig` grows a `layers` row, a `shipped_roots` entry and a
  `test-fetch` step**, and `build.zig.zon` grows a path. The comptime check
  that reads the manifest catches the last of those if it is forgotten.
- **ADR 0041's three-layer question grows a fourth answer.** "Does it need the
  event loop?" becomes "does it need one, and does it hold a destination?" —
  the same question asked twice rather than a different one.
- **ADR 0042's entry condition is generalised rather than replaced.** It said a
  bottom-layer module runs under a plain `zig test`. The rule underneath it is
  *a layer is only a layer if its membership can be checked by running
  something*, and a Fitting's version of that is `std.Io.Threaded`.
- **`nilo_s3` will import `nilo_fetch` rather than write its own client.** The
  gate, the drain policy and the deadline arming come off its plate; what is
  left there is signing and the bucket, which is what is actually S3.
- **`std.Io.Threaded` cannot park a caller that is not its own task**, which is
  what ADR 0062 found through pg.zig's reconnector. So the entry condition
  holds only for a module with no background work of its own — which is part of
  the definition rather than a caveat on it: something with a background task
  is minding a destination.
