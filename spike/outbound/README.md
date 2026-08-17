# An outbound HTTP client, measured before it was designed around

Two sessions hit the same wall from opposite sides. `nilo_s3` needs to speak
HTTP to an object store; a handler needs to speak HTTP to Stripe; and a Service
may not import `nilo_http`, because that is sideways and `zig build layering`
refuses it. The proposal on the table was **a fourth layer between Core and
Service**, which costs amendments to ADR 0041 and ADR 0042 — the two ADRs that
decide where every file in the repository goes.

Nobody had asked how big the thing being housed is. This spike asks, with a
compiler.

Run it:

```
./run.sh
```

## What was measured

**`std.http.Client` is already the client.** Connection pool, HTTP/1.1, TLS.
What nilo would add is policy, and the policy is between the `BEGIN POLICY` and
`END POLICY` markers in `main.zig` so it can be counted rather than claimed.

Three policies, and each one closes a hole that is real:

- **A gate.** The pool bounds *idle* connections (`free_size`, 32 by default)
  and does not bound in-use ones at all. 500 concurrent handlers is 500 live
  connections at 59,151 bytes of buffers each — 29.6 MB nobody asked for.
- **A bounded drain.** `Request.deinit` calls `discardRemaining()` with no
  limit when the head was read and the body was not, so refusing a 500 MB
  object still downloads it. Past `max_drain` the connection is dropped
  instead: losing it costs one handshake, reading it costs the whole object.
- **A body ceiling**, enforced while reading rather than checked after, so a
  sender lying about `content-length` cannot get past it.

## The numbers

Zig 0.16.0, this machine, at the commit this file landed in.

| | lines |
|---|---|
| **nilo's policy, code only** | **65** |
| nilo's policy, with comments and blanks | 104 |
| `std/http/Client.zig` | 1,867 |
| `std/crypto/tls/Client.zig` | 1,670 |

**65 lines against 3,537.** nilo's share of an outbound HTTP client is under
2% of it, and that share is entirely policy — no protocol, no framing, no TLS,
no pool.

## And it needs no engine

The entry condition proposed for the fourth layer was `zig test <m>/<m>.zig`
under `std.Io.Threaded` — ADR 0042's shape, one tier up. Nobody had checked
whether an HTTP client can pass it, so this spike is built to fail loudly if it
cannot: **`build.zig.zon` declares no dependencies at all.**

It passes. Three tests drive the policy against a loopback server, all on
`std.Io.Threaded`, with no zio and no module graph. So the proposed entry
condition is satisfiable — that half of the layer design holds up.

## What is missing, and what it would add

Two things are deliberately absent, and neither moves the answer much:

- **The deadline.** ADR 0065 does not exist as code yet. Where it would be
  armed is marked in `fetch` — one bind around the block, released with the
  permit. Call it a handful of lines.
- **TLS.** It is a field on `std.http.Client`, not code here. Enabling it costs
  this layer nothing; it costs 59,151 bytes per connection, which is the number
  the gate exists for.

A finished version wires results into a Scope and returns `Str` rather than
`[]u8`. Estimate the whole thing at **90–100 lines**, not 300.

## What this does not decide

Whether the fourth layer is worth it. That is a repository-level decision and
it belongs to the people who own ADR 0041 and 0042, not to this file. What this
file removes is the option of deciding it without knowing the size of the first
tenant — **a layer whose first tenant is 65 lines has to justify itself on
something other than volume**, and it may well be able to: the argument for a
layer is about where a rule can be enforced, not about how much code sits
inside it.

The spike stays here as the thing to re-run when the answer changes.
