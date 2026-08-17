# 0072 — an object store is a Service that dials

**Status:** accepted
**Carries out:** [ADR 0067](./0067-most-of-an-s3-client-is-not-s3.md),
[ADR 0068](./0068-a-bucket-is-a-type-and-a-key-is-not.md),
[ADR 0069](./0069-a-signing-key-changes-once-a-day.md),
[ADR 0070](./0070-a-fitting-borrows-the-loop.md)
**Amends:** [ADR 0070](./0070-a-fitting-borrows-the-loop.md)

## Context

Three ADRs designed `nilo_s3` before a line of it existed: what belongs in it
(0067), what a bucket and a key are (0068), and how signing works (0069). A
fourth built the layer it would sit on (0070). This is what happened when they
were carried out, and it exists for the two things that could not be decided on
paper.

The first is a contradiction the design left standing. ADR 0067 says *"the HTTP
is `std.http.Client`"* and puts the module's dependency count at zero.
ADR 0070's Consequences say *"`nilo_s3` will import `nilo_fetch` rather than
write its own client"*. Both cannot be read literally at once, and a reader
arriving at this module now finds the two sentences a directory apart.

The second is that **a design cannot tell you whether the thing it depends on
is the right size.** ADR 0070 argued a Fitting into existence on 65 lines of
policy and one caller. `nilo_s3` is the second caller, and the second caller is
what the layer was for.

## Decision

**`nilo_s3` imports `nilo_fetch`, and that is not a departure from ADR 0067 —
it is ADR 0067 read through ADR 0070.** `nilo_fetch` *is* `std.http.Client`,
plus the policy a server needs: a gate on calls in flight, a deadline, a bounded
drain, a body ceiling. The alternative is not "no dependency"; it is a second
copy of those four things inside `s3/`, which is the outcome
[ADR 0066](./0066-percent-is-needed-by-two-layers.md) was written to avoid one
layer down and the outcome ADR 0070 was built to avoid at this one.

The dependency count ADR 0067 was protecting is unchanged in the sense it
actually meant: **`nilo_s3` fetches nothing.** `nilo_fetch` is in this
repository, not in `build.zig.zon`, so a program importing `nilo_s3` still
downloads no package that a program importing `nilo_http` does not.

The layering table is where this stops being an argument:

```zig
.{ .root = "s3", .may_import = &.{ "nilo_core", "nilo_fetch", "s3_config" } },
```

`zig build layering` reads it. `s3/` naming `nilo_http` or `nilo_sql` fails the
build, and it fails it in the same step that has been refusing sideways imports
since ADR 0042.

### The Fitting needed one addition, and no changes

`Client.send` holds the whole body in the caller's Scope. That is right for an
API answering JSON and wrong for an object store, where the body is the point
and may be larger than the process. So **`fetch.Exchange`**: read the response
head, decide, then move the bytes into a writer rather than into memory.

`Client.send` is now written on top of it, so there is one policy path rather
than two that drift. That is the whole of what a second caller cost the
Fitting — **one type added, nothing changed** — and it is the strongest
evidence available that ADR 0070 cut in the right place. Had `nilo_s3` needed
the gate to behave differently, or the deadline to be armed elsewhere, the
layer would have been housing a shape fitted to its first tenant.

## What the second caller found

**`nilo_fetch`'s bounded drain never fired on the case it was written for.**

`Client.close` decided whether a pooled connection was worth keeping by asking
`conn.reader().bufferedLen()` — how much of the body had already arrived in one
8 KiB read buffer — and comparing that to `max_drain`, which defaults to 64 KiB.
A refused 500 MB body has at most 8 KiB buffered. It was therefore never over
the ceiling, and `Request.deinit` dutifully read all five hundred megabytes to
keep the connection.

**The number was in the wrong unit.** The question is not how much has arrived;
it is how much is still owed, which `std.http.Reader.State` knows:

```zig
const left: u64 = switch (self.req.reader.state) {
    .ready => return,
    .body_remaining_content_length => |n| n,
    .received_head => self.announced orelse std.math.maxInt(u64),
    else => std.math.maxInt(u64),
};
if (left > self.client.settings.max_drain) conn.closing = true;
```

Two things about this are worth more than the fix:

- **Nothing could have shown it.** The symptom is a connection that takes a
  long time to come back, which is indistinguishable from a slow server. No
  test failed, no log line appeared, and the module's own tests all used bodies
  small enough that the two readings agree.
- **It was published three times.** *"A bounded drain, so refusing a 500 MB
  response does not download it"* was in the module header, the CHANGELOG and
  `docs/reference.md`. This repository has now been wrong five times in the
  same shape — a sentence with no run behind it — and **not one of the five was
  found by reading the prose that carried it.** Three were found by
  re-measuring, one by reading somebody else's dependency manifest, and this
  one by a second module needing the same code. The prose was reviewed every
  time and said the same wrong thing every time, because a claim about
  behaviour is not checkable by reading a sentence about it.

What holds it now is a pair of tests whose control differs **only** by
`max_drain`: the same refused body, the same server, one connection kept and
one dropped. A single test asserting the drop would have passed against the
broken code for the wrong reason.

## Two things the implementation decided that the design had not

**The canonical request is never assembled as bytes.** `sign.Hashing` is a
`std.Io.Writer` whose sink is SHA-256, so the canonical form is written straight
into the hash. The obvious implementation builds it in a stack buffer first,
and that buffer would be roughly 3 KiB on the stack of every call — which by
[ADR 0063](./0063-a-handlers-stack-is-per-connection.md) is 3 KiB on every idle
connection, held at the high-water mark for as long as the client keeps the
socket open. The streaming version costs a `Writer` vtable and no buffer.

**Correctness is pinned from two independent directions, and it had to be.**
A signer that is wrong is wrong silently — the server answers 403 and every
explanation is plausible.

- **AWS's published vectors pin the arithmetic.** GET, PUT and presigned, each
  verified independently in Python before a line of Zig was written, so the
  crypto was settled before the wire format was.
- **The canned server pins the wire.** `s3/canned.zig` is a fake S3 on loopback
  that **rebuilds the canonical request from the bytes that arrived** — by
  hand, not by calling `canonicalHash` — and answers 403 on disagreement.
  Client and server are two independent implementations, so a bug in the
  shared understanding cannot cancel out.

That split earned itself immediately. `x-amz-date` and `x-amz-content-sha256`
were mandatory fields in `Signed`, so they leaked into the canonical headers of
a *presigned* request, where only `host` is signed. Every test against the
canned server passed, because the canned server agreed with the client about
what it had signed. AWS's published presigned vector is what caught it.

## What it costs

Against [ADR 0018](./0018-the-trade-budget-has-three-axes.md)'s four axes.
**A program that does not import `nilo_s3` pays nothing on any of them** —
`nilo_http` does not name it and the linker never sees it.

For a program that does, the numbers and the harness are in
[`bench/result/s3.md`](../../bench/result/s3.md), measured against three
controls that answer the same bytes with no object store behind them, and
against the same seven routes written in Go and Rust. They were written in Bun
too, and Bun has no row: it retains about one byte per byte its S3 client reads
and the kernel killed it at 27 GB. That is recorded as its result rather than
as a gap.

| axis | what it costs | |
|---|---|---|
| **Allocations per request** | **1** for a bounded `get` | the object's buffer, sized from `content-length`. Held by `test "a bounded get stays inside its allocation budget"` in `s3/canned.zig`, with the counter above the arena rather than below it — below, a warmed arena makes no backing allocation and the test reads 0 whatever the code does. |
| **Memory per idle connection** | **0 B** | 4,670 B with `nilo_s3` linked and a `Store` held, against 4,669 for the framework without it. Holding a store costs the connection nothing. **This is a floor, not a total**: by [ADR 0063](./0063-a-handlers-stack-is-per-connection.md) a handler suspended inside a `get` holds its stack at the high-water mark, and that number has not been taken. |
| **Throughput and p99** | **11,814 ns of CPU** per 1 KB object | `/o/1k` minus a control answering the same bytes from memory. Against 59,086 ns for Rust with the official AWS SDK and 98,392 ns for Go with its own — 5.0× and 8.3×. Signing on its own is 1,010 ns above `/health`, against 23,724 and 59,676. |
| **Binary size** | **not taken** | the two scratch programs for the stripped `ReleaseFast` A/B are written and unrun, so ADR 0018's running total is not yet updated. |

The throughput figure is a **lower bound** rather than the cost: the control
route saturates the core budget and the store route does not, so the subtrahend
is measured under contention the other half never sees. That applies to every
candidate in the same direction, so the ratios survive where the absolute does
not. The 1 MB pair is void outright and `bench/result/s3.md` says why — a check
worth reading before quoting any subtraction from that harness.

**One number in there is nilo's problem and not this module's.** On the control
route with no object store anywhere near it, axum answers a megabyte at
18,160 req/s and nilo at 8,215, on the same cores. That is the HTTP write path
for a large body, it is the biggest gap in the table, and it is ranked first in
that file's levers.

## Why not the alternatives

**Write the HTTP inside `s3/`.** ADR 0067 priced this at ~815 non-S3 lines, of
which the two expensive parts — TLS and a connection pool — are where the bugs
and the memory are. It also means the gate, the deadline and the drain exist
twice, and the second copy is the one that gets the fix late. The drain bug
above is the argument: one copy was wrong for months and fixing it fixed both
callers.

**Put `nilo_s3` in the Fitting layer.** It cannot be. A Fitting owns no
destination and is given an address on every call; a Store holds an endpoint,
a region and credentials, and dials the same system every time. That is the
definition of a Service under ADR 0070, and the entry condition follows it: a
Fitting's tests need only `nilo_core` in the graph, and `nilo_s3`'s need the
module graph regardless because `s3/live.zig` names a build-generated
`s3_config`.

**Let `nilo_s3` read its endpoint from the environment directly.** What
`sql/live.zig` already refused, for the reason it gave: a test binary that
behaves differently depending on who ran it is the opposite of what a test is
for. `build.zig` reads `-Ds3-endpoint` and friends, falling back to `$S3_*`,
because reading them is a *build* input. `std.posix.getenv` does not exist in
Zig 0.16 anyway, which turned a preference into the only option.

**Ship `LIST` in v1.** Refused by ADR 0068 and unchanged by building the rest:
it is the one operation whose *success* path is XML, and a list result is a
type AWS wrote rather than one the caller did. Every other call here reduces to
bytes at a key.

## Consequences

- **`nilo_s3` ships**, with `nilo_core` and `nilo_fetch` its only imports and
  nothing added to `build.zig.zon`'s dependency list. `get`, `getRange`,
  `getIf`, `stream`, `put`, `putStream`, `delete`, `head`, `presign`.
- **`fetch.Exchange` is public API**, and `Client.send` is written on top of it.
  A second Fitting caller now has a way to handle a body it cannot hold, and
  `nilo_fetch`'s reference page documents it as such.
- **`Client.Error` gains `BodyTooShort`**, which `Exchange.readInto` needs and
  `send` never could.
- **A fifth refusals table.** `s3_refusals` and `refusals-s3`, hung off
  `test-s3`. CLAUDE.md's warning — adding a row to one table while running
  another is a check that silently never ran — is now a warning about five.
- **A second benchmark harness**, `bench/compare-s3/`, separate from
  `bench/compare/` rather than more candidates inside it. The object store is a
  third party on the machine and needs cores of its own, and a run needs a
  container up and a bucket seeded; neither is true of the HTTP comparison.
- **ADR 0070's open question is half-answered.** It said *"the second Fitting
  is what will settle whether this was right"*. There is still only one
  Fitting — but there is now a second *caller* of the first, and the cost of
  that caller was one added type and no changes. That is evidence for the cut,
  not for the layer's population.
- **The drain fix changes behaviour for existing `nilo_fetch` users**, in the
  direction they were promised: a refused large body now costs a reconnect
  instead of a download. Nothing shipped in a release with the old behaviour,
  so there is nothing to migrate.
