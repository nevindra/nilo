# A connection is ended after a number of requests

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md),
[ADR 062](./062-where-a-connection-waits-is-what-it-costs.md),
[ADR 195](./195-a-refused-request-is-hung-up-on-with-a-fin.md),
[ADR 199](./199-a-connection-is-served-by-the-thread-it-was-dealt-to.md).
**Found by:** reading nginx's `keepalive_requests`, fasthttp's `MaxRequestsPerConn` and axum's connection age cap against a server that never ended a keep-alive connection, then running it (`bench/keepalive.py`, `bench/result/http.md`).

## Context

A connection is served by the executor it was dealt to (ADR 199) and nothing on the server's side ended a keep-alive connection, so where a connection was put on the day it opened is where it stayed, for as long as its client kept it. Two consequences were measured.

Inside one instance, connections are dealt round-robin by arrival order, so the dealing is even in count and uneven in load whenever busy connections are a minority and their arrival order is not independent of the executor count. Four busy connections among sixteen, on four executors: opened in a stride of four, all four busy ones sit on one executor (hottest executor 4.00 times the mean, for all 45 s); opened in six random orders, the hottest executor is 1.99, 2.00, 2.00, 2.96, 2.99 and 2.99 times the mean, in every window. Sixteen busy among sixty-four: 1.50 to 1.75 times, unchanged between windows. With the load raised until the hottest executor saturates, the three busy connections on it ran at a p50 of 0.82 ms where 0.43 ms was possible, and the run carried 78,000 requests where the same clients carried 110,000 once connections were redealt.

Across instances, an instance added behind a balancer that balances connections receives only new connections. Two instances, thirty-two connections open to the first, the second joined at 15 s: it took **0.0%** CPU and no connection to the end of the run, 45 s.

## Decision

**`Options.max_requests_per_connection`, default 1,000, 0 for never.** The answer to a connection's last request carries `Connection: close` on HTTP/1.1, as if the client had asked for it, and the connection is closed after it. On HTTP/2 (`-Dhttp2`) the connection is sent a GOAWAY with `NO_ERROR` naming the last call it will answer; the calls behind it are refused with `REFUSED_STREAM`, which a client may send again on a new connection (RFC 9113 section 6.8), the path a stopping server already takes.

**The number each connection gets is up to a tenth below the option**, drawn per connection from a counter put through a mixer and the clock (`bulkhead.connectionBudget`), so that a pool of connections opened together does not end on the same request and come back together. Below ten there is no spread.

**What it counts is requests, so what it follows is load.** A busy connection reaches it in seconds and is dealt again; a connection that sends a request a minute does not reach it for sixteen hours, and carries no load while it waits.

**A handler that takes the socket over is not ended by it.** The WebSocket's 101 is written by the upgrade and not by the `Connection` line the cap sets, and a connection that has been a WebSocket is not HTTP again, so the cap never reaches it (tested). A stream or an event stream on the last request is answered `Connection: close` and ends with its connection, as it would for a client that asked.

**Pipelined requests behind the last are not answered.** They are in the read buffer, so the connection hangs up the way a refused request does (ADR 195): send side first, then waits for the peer, so the last answer is not taken back by a reset. A client that pipelines sends them again, as RFC 9112 section 9.3.2 requires of it after any `Connection: close`.

**Cost, on the four axes.** Allocations per request: none added (the budget test holds). Memory per idle connection: unchanged to the byte, 4,678 bytes at 10,000 connections before and after, and `park-check` reads one page in all four builds; the counter is a `u32` in the connection loop's frame and a `bool` in `InFlight`, both inside padding that was already there. Throughput: a connection costs the server about 6.3 microseconds (a request at 1 per connection costs 8.66 against 2.45 at 1,000 per connection, on the cheapest route), so one in a thousand is 0.26% of a request, and the busy-connection runs show no loss of throughput. Binary: 328 bytes. Length of the cap's effect on balance: hottest executor 4.00 times the mean before, 1.01 after one redealing cycle.

## What was rejected

**Age, as axum does and with jitter.** A connection older than so many minutes is ended on its next request. It would move the quiet connections count cannot, and the instance that was added would receive them too. It needs the connection's start time (8 bytes against 4) and a clock read per request, and it ends a busy connection and a connection that has done three requests at the same cadence, so the busy one's cost to the client is paid on wall time rather than on work. What a balancer that balances connections wants moved is load, which count follows, and a quiet connection holds 4,678 bytes and no CPU. It is the same option shape if it is wanted later (`max_connection_age_ms`), and neither excludes the other; nothing measured needs it.

**Off by default, as net/http, hyper and actix have it.** The imbalance was measured at the defaults, a server's user does not know the dealing is by arrival order, and the cost is 0.26% of a request. nginx moved its default from 100 to 1,000 and fasthttp ships with it off; 1,000 is nginx's. A user whose clients cannot take a `Connection: close` sets 0.

**Redealing the connection to another executor without closing it.** Pinned scheduling (ADR 199) is what makes the executor's thread a property the handler may rely on; moving a live connection undoes it, and says nothing about the instance.

**A first GOAWAY with the maximum stream id, then a second.** The polite two-step avoids refusing a call in flight. The stopping path does not take it, a refused call is safe to send again, and the cap does not need a stricter promise than the stop does.

## Consequences

Every client now sees a connection end once in about a thousand requests: a client that does not reconnect on `Connection: close` or a GOAWAY, or a proxy that pipelines, has a setting to turn off (0). `Options` gains a field; nothing else a user wrote changes. Quiet connections still stay where they were dealt, which is the one thing left over from the todo item this closes, and an age cap is the answer if it matters.
