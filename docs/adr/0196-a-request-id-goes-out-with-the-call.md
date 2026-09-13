# A request id goes out with the call

`c.requestId()` is the one thing that ties a log line, a response and a
client's report of "it was slow at 14:02" to each other
([ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md) is where the
logger got it). It stopped at this process. A handler that called somebody
else's API through `nilo_fetch` sent nothing that named the request it was
serving, so the other side's log had a line for the call and nothing to line it
up against — and the other side, for anybody running two nilo services, is
often the same person.

This is what `tracing`'s span context does in the tokio stack: the id is a
property of the work, not of the process, and it follows the work across a
socket. Here it is one header:

```
X-Request-Id: 7f3a9c1e5b2d4086
```

sent on every `client.get`, `post`, `put`, `delete` and `send` made under a
`*Ctx`. The id is whichever one the request already has — the one a proxy in
front sent and nilo checked, or the one nilo minted — so a request that came
in with an id leaves with the same one, on every hop.

## The Scope is where it travels

`nilo_fetch` is a Fitting: it imports `nilo_core` and nothing above it
([ADR 0070](0070-a-fitting-borrows-the-loop.md)), so it cannot name `Ctx` and
does not know what a request is. What it is handed is a Scope, and a Scope is a
shape checked while compiling — `arena()` and `str()`, with `entropyInto` as
the one optional extra ([ADR 0166](0166-entropy-a-function-pointer-can-carry.md)).

`requestId` is the second optional extra. A Scope that has it is asked; one
that has not is not. `Ctx` has it already. A `Run` does not — a CLI, a
scheduled tick and a test have no request to name, and inventing an id for
them would be a number nothing else ever sees. `AnyScope` carries a slot for it
in its table, filled from the Scope it was made of, so an id crosses a function
pointer the way entropy does and a bus reaction that dials out still names the
request that fired it.

So the check is `@hasDecl` on the Scope's type, resolved while compiling, and
a `Run` costs nothing for a declaration it has not got.

## What it costs

**On the ordinary call, nothing measurable.** A call that passes no headers of
its own — which is `client.get(c, url, .{})` — gets the id through a
one-element array on the stack: 32 bytes on a frame that already holds 6 KiB
of buffers, and no allocation.

**A call that passes headers of its own** spends one allocation in the Scope's
arena on the merge: its headers plus one. The arena is the request's and is
reset when it ends, so this is a bump and not a `malloc`. It is an allocation
on a path that did not ask for it, and it is the one place this decision
spends that axis; the alternative was a fixed stack array wide enough for
"most" header lists, which is bytes on every connection that ever dials out
([ADR 0063](0063-a-handlers-stack-is-per-connection.md)) to save an arena bump
on the calls that pass headers, and that is the wrong trade here.

**Off by one field.** `fetch.Client.Settings.forward_request_id = false` sends
nothing and merges nothing.

**Binary size: +0 on a program that does not import `nilo_fetch`**, which is
`hello` and `rest`, and about **+1,456 bytes of `.text`** on one that does —
`examples/outbound`, stripped `ReleaseFast`, measured as the part of its
+2,416 that `hello` did not also pay ([ADR 0018](0018-the-trade-budget-has-three-axes.md)).

**`c.requestId()` on a request nobody asked it of before** mints an id: sixteen
shifts on a counter, no clock, no entropy. It is then kept on the `Ctx`, so
the logger — if it is on — writes the same one.

## What was rejected

**`traceparent`.** W3C Trace Context is the header a tracing backend wants,
and it carries a trace id, a parent span id and flags. nilo has no spans, so
two of the three fields would be invented, and an invented parent span is worse
than none — a collector would draw an edge to a node that does not exist.
`X-Request-Id` says exactly what nilo knows. The day nilo has a span, this
header is where the trace id goes, and nothing about that day is decided here.

**Forwarding only when the logger's `request_id` is on.** It reads as
sensible — why send an id nobody on this side logs — and it makes the outbound
header depend on a logging option, which is the kind of coupling that gets
found by the person who turned the logger off and lost their correlation.
The id is a property of the request; the logger is one reader of it.

**Sending it from `Exchange.begin` as well.** An `Exchange` is what `nilo_s3`
signs requests with, and a signed request has to say exactly what it signed;
a header the Fitting added underneath the signature is a request the other
end rejects. `Exchange` sends the headers it is given and nothing else, as
it always has.

**Forwarding the deadline too.** `c.timeLeftMs()` is the obvious second thing
to send, and `Call.timeout_ms` is where a caller puts it today. Making it
automatic would give every outbound call the *whole* of the request's
remaining time, which is right for the last call a handler makes and wrong for
the first. The caller knows which it is.
