# A server past its limit says so at once

`max_connections` bounds how many sockets are held, `allowance` bounds how many
requests one address may make, `deadline` bounds how long a route gets. None
of them bounds how many requests the server is *answering* at the same time.
A handler that spends 40 ms in Postgres, under a burst that arrives faster than
40 ms apart, queues: every request past the first is waiting on the pool, then
the pool's timeout, then the next one's, and the p99 that comes out of the
burst is the sum of the queue rather than the cost of the work. Every request
in it eventually gets an answer, and the answer arrives after the client has
given up on it.

tower calls the shape that fixes this `LoadShed`, and puts `ConcurrencyLimit`
beside it: past N in flight, refuse the next one immediately rather than
queue it. The client gets a 503 in a millisecond, the load balancer in front
sends its retry to a replica that has room, and the N already running finish
on time.

```zig
try app.listen(.{ .max_in_flight = 256 });
```

## The count is already there, and so is the moment

`serve.zig` already increments `stop.in_flight` when a request's head has
arrived — it is what a shutdown waits for
([ADR 0098](0098-a-completion-the-loop-holds-outlives-the-frame-that-submitted-it.md))
— and `fetchAdd` hands back the value before the increment. So the check is a
comparison against a number the atomic already returned:

```zig
const before = self.stop.in_flight.fetchAdd(1, .acq_rel);
defer _ = self.stop.in_flight.fetchSub(1, .acq_rel);
if (self.limits.max_in_flight != 0 and before >= self.limits.max_in_flight) {
    sendFinal(out, RESPONSE_503_BUSY);
    …
}
```

No second atomic, no lock, no clock. It runs after the head is parsed and
before anything else — before the arena takes the head, before the router is
asked — so a shed request costs the server one `writeAll` of a constant.

**The answer is a 503 with `Retry-After: 1` and `Connection: close`**, the
same JSON body every other refusal has ([ADR 0025](0025-every-failure-answers-with-the-same-json-body.md)).
The connection is closed rather than kept because a shed request may have a
body behind it that nothing here is going to read, and because a client
whose request was refused for load is a client the balancer should place
somewhere else — a keep-alive would pin its next request to the server that
just said no.

**Counted, when metrics are on**, as a 503 against `<unparsed>`'s neighbour:
the request was parsed and never routed, and a route it never reached should
not carry its number.

## What it costs

**Off by default**, and off is `max_in_flight = 0`, which is one comparison
against a constant on a value the request path already loaded. No bytes per
connection, no allocation, no new atomic.

**On**: the same comparison with a different right-hand side. The 503 is a
compile-time constant written in one call.

**What it does not cost is a queue.** tower's `Buffer` and actix's backlog
both put refused work somewhere to wait; this puts it back on the wire. A
queue is memory per queued request and a second timeout to tune, and the
client already has both.

## What was rejected

**A default other than off.** 256 is right for a server whose handlers take
40 ms and wrong for one whose handlers take 4 ms or 4 s, and a number nilo
picked would be a number an operator finds by being shed at 3 a.m. The gauge
`nilo_requests_in_flight` is what an operator reads to pick one; the option is
what they set afterwards.

**Counting connections rather than requests.** `max_connections` does that
already, at the accept loop, and it is the wrong unit here: ten thousand idle
keep-alive connections hold no work, and a hundred requests in flight on a
hundred of them is the load. `stop.in_flight` counts requests for the same
reason a shutdown waits on requests and not sockets.

**Shedding by queue *time* rather than depth** — refusing a request that has
waited longer than T. It is the better signal and it needs a queue to
measure, which is the thing above. A depth is what can be counted without one.

**Closing without a status, the way `max_connections` does.** The accept loop
closes an over-limit connection unanswered because writing to it would put a
write, with a deadline on it, inside the one loop that must not stall, and
because the client chose that work. Here the request is already on a
connection fiber, its head is read, and the write is a constant behind the
same `write_timeout_ms` every response has. A balancer can act on a 503 and
cannot act on a reset, and that is the difference between the two.

**Shedding before the head is read.** Cheaper by a parse, and it would shed a
client that had connected and not yet asked for anything — which is the idle
tab ADR 0098 refused to make a shutdown wait for, and the same argument reads
the same way here.

**A per-route `max_in_flight`.** `nilo.deadline` and `nilo.maxBody` are per
route because a budget of time or bytes is a property of the work. A
concurrency ceiling is a property of the machine — the pool, the cores — and
one route being at its limit while another has room is what the balancer's
replica is for. A route that wants its own ceiling has `allowance`, and the
number it holds is a different question.
