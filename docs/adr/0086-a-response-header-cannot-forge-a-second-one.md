# 0086 — a response header cannot forge a second one

**Status:** accepted

## Context

`http1.writeResponse` writes every application-set header as
`"{s}: {s}\r\n"`, with the value exactly as it was handed over. Between
`Ctx.setHeader` and that line, nothing looked at the bytes. `putHeader` checked
`isReservedHeader` and stopped there.

So a value carrying `\r\n` did not sit inside its header. It ended the header
block and began writing whatever came after it as part of the response.

The reachable path is the one `redirect.zig`'s own headline example takes:

```zig
fn shortLink(db: *Db, code: Str) !nilo.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

`Redirect.to` reaches `Ctx.redirect`, which checked the status and refused an
empty location and then called `setHeader("Location", …)`. A shortening service
stores URLs its users submit; one of those users submits
`/welcome%0d%0aSet-Cookie:%20admin=1`, and every visitor who follows that link
is handed a cookie no line in the application sets. `Response.headers` and
`FileBody.headers` reach the same place.

**nilo already knew, and had guarded it twice.** `Ctx.requestId` refuses a
client's `X-Request-Id` unless it is 1 to 64 bytes of letters, digits, `.`, `_`
and `-`, and its comment gives the reason in as many words: "a newline forges a
line of its own, and in a response header it splits the response".
`Cookie.check` refuses the same bytes for the same reason. What was unguarded
was the one API an application actually writes.

That is the argument for the shape of the fix as much as for the fix. Two
correct guards and one gap is not an oversight about the danger. It is the
danger being handled wherever somebody happened to be looking, which is what a
choke point is for.

## Decision

`putHeader` refuses two things, and it is the only place either is checked
because it is the one point every response header goes through.

A **value** carrying `\r`, `\n` or `\0` is `error.BadHeaderValue`. The first two
end the header line. `\0` is there for the hop after nilo: it ends the string
for anything downstream written in C, which makes "the header nilo sent" and
"the header the proxy read" two different headers.

A **name** that is empty, or carries any of those three or `:`, a space or a
tab, is `error.BadHeaderName`.

A handler that lets either error out sends a 500, and that is the right answer
rather than a fallback. The response the handler meant to send cannot be
written, and there is no smaller correct version of it to send instead.

## What was rejected

**Checking in `Debug` and `ReleaseSafe` only**, the way `Str`'s staleness trap
works (ADR 0004). It is the cheaper shape and it was the one this was expected
to take. The argument against is `password.zig`'s, about a different call that
must not be forgotten: a protection the caller has to remember is a protection
that gets forgotten, and this one is not the caller's to remember at all. The
attacker-supplied URL that reaches `Redirect.to` reaches it in ReleaseFast.

The measurement then made the choice easy rather than hard. See **What it
costs**.

**RFC 9110 §5.6.2's `token` for the name.** Strictly, a header name is
`ALPHA / DIGIT / "!#$%&'*+-.^_\`|~"` and nothing else, and the first version of
this checked exactly that with a 256-byte table. It was dropped for the six
bytes above, because the strict rule refuses things that cannot do harm: `X-A(B)`
is not a legal token and still goes out as one header line and is read back as
one header line. The six that are checked are the six with a consequence. A rule
that refuses more than its reason covers is a rule the next person cannot argue
with when it gets in the way.

**Stripping the bad bytes instead of refusing.** A `Location` with the newline
removed is a redirect to somewhere nobody chose. Silence about a value that was
altered is the failure mode ADR 0081 exists to stop.

## What it costs

Allocations per request: none. Memory per idle connection: none, and the table
is 256 bytes of `.rodata` shared by the process.

Throughput: **about 3 to 8ns on a request the profile harness measures at 192ns,
so 2 to 4%.** Quoted as a range because the run-to-run spread on this machine is
the same size as the effect: the same binary came back anywhere from 184 to
213ns across sixteen runs. Eight interleaved triples of HEAD, this change
without the guard, and this change with it put the guard at +8.1ns with the sign
flipping once in eight; an earlier six pairs put it at +0.2ns with the sign
flipping three times. What both agree on is that it is single-digit nanoseconds
and never a win. Measured through `zig build profile`, which is in-process and
not across a socket, so it is a bigger fraction there than in anything served
over a network. A response that sets no header of its own pays nothing, because
the check is per `setHeader` call and not per request.

Within ADR 0018's bar of 10% for a DX feature, and this is not one.

The first version of the scan cost **9ns instead of 3** and the reason is worth
keeping: it used `scan.positionsOf`, which is the right tool for a request head
and the wrong one here. Under one 32-byte block `positionsOf` falls to a scalar
tail loop, so three delimiters over a 27-byte header name is three passes of 27
iterations rather than one vector compare. Header names and header values are
nearly always under a block. One branchless pass over a 256-byte table is the
shape that fits. See [`bench/result/http.md`](../../bench/result/http.md).

Binary size: the 256-byte table and two short functions, none of which the
linker can drop, since every `setHeader` calls them.
