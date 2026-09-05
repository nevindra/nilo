# A buffered body arrives at a rate

[ADR 0023](./0023-a-deadline-belongs-to-an-operation-not-to-a-request.md) gave
a request body a per-read limit and said why: how long a body legitimately
takes depends on its size and the client's line, and a server may not put a
number on either in advance.

That is right about the number and wrong about what a per-read limit is worth.
**A client sending one byte every twenty-nine seconds is inside a
thirty-second per-read limit forever**, and each of those bytes is delivered on
time. It holds a fiber, the 16 KiB step `c.body()` has committed
([ADR 0105](./0105-a-body-is-taken-as-it-arrives.md)), and a slot against
`max_connections`, for as long as it cares to. This is the slowloris of ADR
0023's own table, moved one phase later: the head is bounded by an absolute
deadline and the body was not.

**A run of reads that assembles a buffered body now gets a deadline of
`body_grace_ms + bytes / body_min_rate`.** Two new `Options`, defaulting to 10
seconds and 8 KiB/s.

## Why the length makes the deadline possible

ADR 0023's argument against a deadline is an argument against a deadline
*nobody can size*. The body of a `Content-Length` request is the one wait in
HTTP where the client has said, in advance and in the request itself, exactly
how much work is coming. A deadline computed from that number is not a guess
about the client — it is a statement about the rate the server is prepared to
sit at, applied to a length the client chose.

That is why this is an amendment rather than a contradiction. ADR 0023's
binding sentence — a deadline is a limit on one wait for the network — still
holds for every other wait, and `armHeader` was already the same shape for the
same reason: all of it, not each read of it.

## The three shapes it has to be right about

**A sized body** gets `grace + announced / rate`, armed per read run rather
than once. `readSizedBody` takes its 16 KiB step before committing the rest,
so the step is bounded on its own terms and a client that announces a megabyte
and goes quiet is refused in ten seconds rather than in the megabyte's worth of
time it never earned.

**A chunked body** announces nothing, so it is sized from `max_body` — the
most it is allowed to be. The alternative of a flat number was rejected: it
would make chunked either the cheap way to hold a connection or the framing
that cannot upload anything large. Sized this way, a chunked body has exactly
the worst case of a body that announced `max_body`, so neither framing is the
better attack.

**Everything that is not a buffered body keeps the per-read limit.**
`bodyStream`, a WebSocket, a held-open stream and the connection's own reads go
through `armBody` untouched. Those are ADR 0020's "a request that lasts is
still one request" and none of them is the framework holding memory on the
client's behalf.

## What a client that misses it is told

**408, not 500.** Both arrive at `c.body()` as `error.ReadFailed` — one
interface, one error, no room for a reason — so `Ctx.slowBody` asks
`deadlines.timedOut()` the way ADR 0023 established and turns the timeout into
`error.BodyTooSlow`, which `fail.statusFor` maps to 408. A 500 would blame the
server for something the client did, and would send whoever reads the log
looking for a bug in a handler that did nothing wrong.

## This is an admission policy, and it says so

`body_min_rate` is not a safety limit that only touches attackers. **8 KiB/s
is the slowest upload this server will sit through**, and a client below it is
refused however honest it is. A server whose clients are on genuinely bad links
should lower the rate, not raise the timeout; `body_min_rate = 0` turns the
whole thing off and leaves ADR 0023's behaviour exactly as it was, and
`body_timeout_ms = 0` still means no clock on a body at all.

The attacker's remaining freedom is the announcement: `Content-Length` is
theirs to choose up to `max_body`, so the largest deadline they can buy is
`grace + max_body / rate` — 138 seconds at the defaults. That is bounded, which
is the whole difference. It was unbounded before.

## What was rejected

**A combined limit — each read gets `body_timeout_ms`, and no read may pass an
absolute instant.** This is the exact semantics, and it needs the Engine:
zio's `Timeout` is `none | duration | deadline` and cannot express both, so it
would have to grow a fourth shape and nilo's `Limit` with it. The roadmap
recorded this feature as blocked on that for a cycle. It is not needed — a
deadline per read *run*, sized from the run's own bytes, catches the same
client, and the cost of the difference is that a client can spend its whole
run's budget on one read rather than being cut at the first slow one. Both end
at the same instant.

**A flat `body_deadline_ms`.** Simple, and it is a number nobody can choose:
large enough for a legitimate upload on a slow line, it is large enough to hold
a connection for; small enough to be a limit, it refuses uploads that are
working.

**Re-arming per chunk on a chunked body.** It reads as the tighter option and
is the looser one: a client sending 1-byte chunks would get a fresh grace on
each, which is the per-read hole again with more steps.

## What it costs

**Allocations per request: none.** Arming a limit is a field store on the
reader (ADR 0023), and this arms it once or twice per body instead of once.

**Per connection: nothing.** Two `u32`s on `Options` and on `Deadlines`, both
of which are per *server* and copied by value into a connection that already
carries four.

**Throughput: one `clock_gettime` per body read run** — the vDSO call
`armHeader` already makes once per head — on requests that have a body. A GET
does not reach it.

**Behaviour: a default changed.** A server upgrading to this that has clients
uploading below 8 KiB/s will see 408s it did not see before, the same way ADR
0023's own defaults did. It is pre-1.0, the number is in `Options`, and zero
turns it off.
