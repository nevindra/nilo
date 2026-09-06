# A route can say how long it has

[ADR 0023](0023-a-deadline-belongs-to-an-operation-not-to-a-request.md)
gave the Engine four deadlines, and every one of them bounds an *operation*: a
head, one read of a body, one write, a gap between requests. None of them
bounds the **request**. A handler that reads a body slowly, calls two services
and writes a large response is inside all four of them all afternoon.

Fiber has a `timeout` middleware and Gin has the request context. nilo had
`block_warning_ms`, which only ever logs
([ADR 0034](0034-the-thing-a-handler-holds-is-watched-at-run-time.md)).

```zig
try app.with(nilo.deadline(2000)).get("/report", buildReport);
```

## The clamp is one place, not six

`Deadlines.set` is what every `arm*` goes through, so the deadline is applied
there: a limit is whichever of the two comes first, and `none` — "as long as it
takes", which is what an idle connection and a WebSocket ask for — becomes the
deadline itself.

Nothing had to be remembered at the call sites, and a wait added later gets the
deadline without anybody wiring it up. The clamp only ever shortens: a deadline
that lengthened a limit would loosen the server's own protection against a slow
client, which is the opposite of what it is for.

## A running handler is not interrupted, and deliberately is not

This is the half worth being plain about, because it is what Fiber's middleware
does and this does not.

Fiber runs the handler in a goroutine and abandons it. Zig has no runtime to
abandon it into. The alternative is cancelling the fiber, and a cancel that
fires mid-handler is a cancel that **every** handler, every `nilo.Mutex`, every
`nilo.sleep` and every Service has to survive at every line —
[ADR 0104](0104-a-cleanup-path-is-not-cancellable.md) has already had to carve
the cleanup path out of cancellation once, for a much narrower case.

So what this catches is the two shapes a request actually overruns in:

- **a client that is slow**, on either side — the read and the write are
  clamped;
- **a response that is large**, where the stream's pieces are clamped one at a
  time and the deadline is what ends the sequence.

And the third — a handler doing its own work — is handed to the handler as a
question:

```zig
while (try rows.next()) |row| {
    if (c.overdue()) return fail.status(503, "too many rows to do in time", .{});
    try out.json(row);
}
```

`c.timeLeftMs()` is the same answer as a number, for a handler with a budget to
pass on to somebody else — an outbound call that should not be given longer
than the request has.

**Both answer safely on a route with no deadline**: `overdue()` is false and
`timeLeftMs()` is null, so asking does not require knowing what the route was
registered with.

## What happens when it runs out

**A handler that fails while overdue, with nothing sent, gets a 503** naming
the budget rather than whatever the failed read or write happened to raise.
That is the status an operator can act on.

**A handler that fails while overdue after sending is left alone.** A half-sent
response cannot be taken back and turned into a 503.

**A handler that finishes late without noticing still answers**, and the
lateness is a `std.log.warn`. The answer is on the wire and is correct; what is
over budget is the route or the work in it, and both are somebody's afternoon
rather than this request's. Throwing away work that is already done would be
the worse of the two.

## What it costs

**Nothing for a route with no deadline.** `until_ns` is zero and `clamped`
returns its argument on the first line.

**For a route with one**: one comparison and, on the `within_ms` arm, one clock
read per limit armed — which is per body read and per write, next to a syscall.
Nothing is allocated. `Deadlines` grows one `u64`, and it lives on the `Ctx`,
which is on the fiber's frame and unwound before the connection waits
([ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md)).

**Binary size**: `deadline.with` is generic on `ms`, so a program that never
calls it links none of it.

## What was rejected

**Cancelling the fiber.** Above.

**A `request_timeout_ms` in `listen()`.** One number for every route is the
wrong shape: an upload and a health check do not have the same budget, and a
number loose enough for the slowest route bounds none of the others. A route
that wants the deadline says so, which is what `with` is for
([ADR 0126](0126-a-route-can-say-what-covers-it.md)).

**Refusing the request at the start of every framework call once overdue** —
`c.send` returning an error because the clock ran out. It turns a correct
response that was late into no response at all, and it puts a branch on the
hottest path in the framework for a case that is rare.

**A deadline that also covers `nilo.sleep` and `nilo.Mutex.lock`.** They park
and would honour one, and it is the obvious next step. It is not here because
the two of them return `error.Canceled` today and a caller cannot tell a
shutdown from a deadline apart by that name — which wants a second error and a
pass over every handler that catches the first. Worth doing; worth doing on
purpose.

## What is still open

**Nothing tells a handler its client has gone.** The other half of the gap this
came from, and it is not simply unbuilt — the obvious implementation is wrong.
A read-side EOF is *not* "the client left": a client that sent
`Connection: close` and then `shutdown(SHUT_WR)` produces exactly that byte
pattern and is still waiting for its response. Answering "peer gone" from it
would abandon correct requests.

What is real is a write that fails, which a handler already sees. What would be
worth building is a signal that separates "the client half-closed and is
waiting" from "the socket is gone", and that is a design rather than a call to
make. The roadmap keeps a sentence.
