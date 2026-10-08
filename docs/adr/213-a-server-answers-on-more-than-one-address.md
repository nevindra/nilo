# A server answers on more than one address

**Status:** accepted
**Topic:** [engine](../design/engine.md)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md)
(what a feature spends, and the number), [ADR 200](./200-every-executor-accepts.md)
(an acceptor per executor), [ADR 212](./212-tls-is-an-option-a-build-asks-for.md)
(one certificate per listener)
**Extends:** [ADR 103](./103-a-path-is-an-address-to-listen-on.md)
(a path is an address), [ADR 001](./001-zio-as-the-engine-behind-the-bulkhead.md)
(the Engine is behind a seam)

## Context

`listen()` took one address and blocked. That is the whole of what a server
needed for as long as the deployment nilo was written for had a proxy in
front of it: the proxy holds 443, terminates TLS, and reaches one port or
one socket file behind it ([ADR 027](./027-tls-is-terminated-in-front.md)).

[ADR 212](./212-tls-is-an-option-a-build-asks-for.md) changed what a
deployment can be without changing this. A build that asks for TLS can now
serve HTTPS itself, and the moment it can, the first thing anybody wants is
the other half: **a cleartext port beside the encrypted one**. Not as a
second process. The two share a route table, a service registry, a
connection budget and a thread pool, and splitting them across processes
means splitting all four and then reconciling them.

The case that forced it is concrete rather than hypothetical. nilo's entry
in HttpArena is one container, started once, driven at every profile in
turn. Three of the scored HTTP/1.1 profiles want port 8081 with TLS on it
(`json-tls`, `8gbit`) while the other eight want 8080 in cleartext, and
nothing tells the binary which profile is about to run. One process, two
ports, or the entry cannot subscribe to the scored set at all.

Two listeners is also the plainest reading of several things already in the
file. ADR 212 already says "one certificate per listener" and "a listener
serving two names needs two listeners", which names a thing that could not
exist. ADR 103 already made `address` carry a path as well as an IP, so
"which address" was already a richer question than "which port".

## Decision

**`Options.also` is a list of more addresses to answer on, and each entry
is an address, a port and a certificate and nothing else.**

```zig
try app.listen(.{
    .port = 8080,
    .also = &.{
        .{ .port = 8081, .tls = .{ .cert = "cert.pem", .key = "key.pem" } },
    },
});
```

Three things follow from the shape, and each one was a choice:

**A list beside the existing fields, not a list replacing them.** Every
`listen()` written before this compiles and behaves identically, and the
common case — one address — reads exactly as it did. `Options` gains one
field with an empty default.

**An entry carries what belongs to an address, not the other thirty.** `Listener` is
`address`, `port` and `tls`. (A fourth, `grpc`, made a listener speak h2c
and went when every listener came to answer both framings,
[ADR 259](./259-http2-is-a-framing-of-every-request.md).) Everything else in `Options` is the *server's*
rather than the *address's*: the buffers a connection gets, the deadlines it
runs under, how many connections this process holds, how many threads serve
them. `max_connections` in particular counts sockets across every listener
rather than per port, because what it protects is one descriptor table
(ADR 194).

**A listener decides how bytes are carried, and a request is told only its
number.** `c.listener()` answers `0` for the listener `address` and `port`
name and `n` for `also[n - 1]`, and a route can be bound to listeners at its
registration, which makes it a 404 on the others
([ADR 252](./252-a-request-knows-which-listener-it-came-in-on.md)). Nothing
else about a listener reaches a handler. The first version of this ADR said
the handler was never told, and a program with an ingest port and a public
port was the case it was waiting for.

`boundPort()` answers for the first listener, the one `address` and `port`
name. A caller that asked the kernel to choose asked about that one; an
extra listener that asked for port 0 has no way to report back, and no
caller has wanted one.

### What it costs

Measured on the Ryzen 7 9700X (8 cores, 16 threads), Linux 7.2.5, Zig
0.16.0, `ReleaseFast`, stripped, against the tree at `219d51b`. The build
flag is named per row, because it changes the answer: the connection and
listener rows are from a `-Dtls` build, where a listener's certificate is
real, and the example rows are the ordinary build a dependent has.

| axis | before | after |
|---|---|---|
| memory per idle connection, 10,000 of them | 9,300 B | **9,300 B** |
| resident, one extra listener at 16 threads | — | **+82 KB** |
| binary, `example-hello` stripped, no `-Dtls` | 960,120 B | **+256 B** |
| binary, `example-rest` stripped, no `-Dtls` | 1,150,536 B | **+256 B** |
| binary, `nilo-hello` stripped, `-Dtls` | 1,490,368 B | **+1,872 B** |
| allocations per request | 1 | 1 |

The two binary rows differ by more than they look. Without TLS the loop has
one shape to walk and the certificate branch folds away, and +256 bytes is
the list walk and the repeated-address comparison. With `-Dtls` the
per-listener certificate is real, and the +1,872 is that plus the wider
`Bound` the loop carries. Both are measured; the ADR 017 table takes the
first pair, because that is the build almost every dependent has.

**The per-connection row is the one that had to hold, and it does, to the
byte.** It is not free by construction: the acceptors gained a level of
indirection to reach the connection count, because what one listener holds
(its certificate) had to be separated from what the server holds (the
budget, the descriptor shortage, the first failure). A connection fiber is
handed a `*Accepting` and keeps it live across the handler, and ADR 212
measured that the plain park frame sits under 300 bytes short of a page
boundary — so *anything* added there is a whole page on every idle
connection. Two pointers where there used to be a struct is what keeps it
where it was, and `bench/mem.py` at 2,000, 5,000 and 10,000 connections is
what says so rather than the reasoning.

**The per-listener row is 82 KB and not the 64 KB the stack alone predicts.**
An extra listener is one socket and one acceptor fiber per thread, and an
acceptor's stack is 4 KB, which is 64 KB on sixteen threads. The measured
figure is 330 KB for four extra listeners, so 82 KB each, about 5.3 KB a
thread. The difference is zio's own per-fiber bookkeeping, and it is quoted
as measured rather than as derived because the derived number was wrong by
a third. A server with one listener pays none of it.

## What was rejected

**A second `App` on a second thread.** The obvious shape, and the expensive
one: each `listen()` starts a Runtime with one executor per core, so two
Apps on a sixteen-thread box is thirty-two executors polling. That lands on
the CPU column of every profile, including the eight that have nothing to do
with TLS. It also splits the four things the two listeners were supposed to
share, and `max_connections` would stop meaning what it says.

**Splitting `Options` into engine options and listener options.** The
honest decomposition, and a breaking change to the most-written type in the
API to buy tidiness for a field almost nobody sets. ADR 212's own reasoning
applies: the default build, and the default call, are unchanged to the byte.

**Letting a handler know which listener it came in on, in the first version.**
It is the request every "admin port" design starts with, and it was left out
until somebody brought the case, on the reading that it costs a field on the
hot type and that route prefixes cover two surfaces. A multi-listener port
brought it (a bearer-token ingest route reachable on the public port), and
the cost turned out to be one byte on `Peer` that the frame absorbed to the
byte (ADR 252).

**Letting the kernel report a repeated address.** Two entries naming one
address is a typo in a config file, and `AddressInUse` from the kernel reads
as *another process* holding the port — which sends the reader to `ss -ltnp`
to look for a process that is not there. nilo compares the list against
itself first and names both entries. The comparison uses the other
listener's *bound* port rather than the one it asked for, so two listeners
that both asked for port 0 are two ports and not a collision; `sameListener`
is a pure function so the decision is testable without the log line, the way
`tlsRefusal` is (ADR 212).

## What this does not do

- **No SNI, and still one certificate per listener.** Two names on one
  certificate, or two listeners, which is now a thing that exists. ADR 212's
  row stands.
- **No per-listener buffers, deadlines or limits.** If a caller turns up
  wanting a 64 KB read buffer on one port and 4 KB on another, `Listener`
  is where those fields go, and the memory number in this file is what they
  would have to be measured against.
- **No reporting an extra listener's bound port.** `boundPort()` is the
  first listener's. An extra listener asking for port 0 is legal and its
  number is unknowable from outside, which is why the tests give the second
  one a path instead.
- **No ordering guarantee between listeners.** They are bound in the order
  written, first to last, and a failure anywhere refuses the whole server
  and closes whatever was already open. Nothing accepts until all of them
  are bound.
