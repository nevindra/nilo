# 0089 — two layers can each name a `Vary` axis

**Status:** accepted
**Amends:** [ADR 0030](./0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md)

## Context

`Ctx.setHeader` replaces: setting a header twice is somebody changing their
mind, and the second call wins. `http1.repeats` was the list of exceptions and
it had one entry, `Set-Cookie`, whose doc comment argued the rule:

> So "last one wins" — which is right for `Vary` or a cache directive, where a
> second call is somebody changing their mind — would mean setting a session
> cookie and a preference cookie silently delivered only the second.

**The parenthesis naming `Vary` as obviously fine was wrong, and the repository
already contained the counter-example.** Two places set it:

- `cors.zig` sets `Vary: Origin` when the origin is named rather than `*`,
  with the comment *"A response that varies by origin must say so, or a shared
  cache will hand one origin's response to another."*
- `app.zig`'s `serveHeldFile` sets `Vary: Accept-Encoding` when a file has a
  gzipped copy, with the comment *"A shared cache that stored the plain answer
  without this would go on handing it to clients that could have had the small
  one, and, worse, the other way round."*

Middleware runs before the handler, always. So on any app with a named-origin
CORS in front of gzipped static files — which is an ordinary way to deploy —
`Vary: Origin` was set, then overwritten, and every such response went out
naming one axis when it depended on two.

The rule was not wrong so much as **written from inside one function.** "A
second call is somebody changing their mind" is true when one author sets a
header twice. `Vary` is set by layers that do not know about each other, each
stating a fact about the response that is independently true, and there "last
one wins" is not a mind being changed — it is a fact being lost.

The impact today is small and that is luck rather than design: `cors.Options.origin`
is a compile-time constant, so the `Access-Control-Allow-Origin` value does not
actually vary by request and the missing `Vary: Origin` misleads no cache. It
stops being luck the moment CORS learns more than one origin, and it was never
true for a user middleware setting a `Vary` of its own.

## Decision

**`Vary` joins `Set-Cookie` in `http1.repeats`, and the response carries two
`Vary` lines.**

The two are on that list for opposite reasons, and the doc comment now says so.
`Set-Cookie` repeats because folding is *forbidden* — RFC 6265 §3, because a
cookie's `Expires` attribute contains a comma. `Vary` repeats because folding is
*allowed*: it is a list field (RFC 9110 §12.5.5), so two lines and one
comma-joined line mean the same thing to every cache.

**Two lines rather than joining with a comma, and the reason is the allocation
budget.** Joining `"Origin"` and `"Accept-Encoding"` means building a third
string, and both inputs are borrowed constants set through `setStaticHeader`
precisely so that nothing is copied. That would put an arena allocation on the
static-file path, which is the path ADR 0018's hard invariant is about. Two
entries in a list that already exists cost nothing.

**An exact duplicate is dropped.** A repeating header whose name *and* value are
already present is not a second fact, and `Vary: Origin, Vary: Origin` is what
two middlewares that both depend on the origin would otherwise produce. The scan
is over at most seven entries, on the path that was already scanning them.

**`inline_headers` goes from six to seven**, and this is the part that was
measured rather than reasoned. The shape above sets seven headers — CORS two,
the file five — so with six held inline the seventh spilled to the arena and the
change cost one allocation per request on exactly the path it was meant to fix.
`test "a gzipped file behind a named-origin CORS still allocates nothing"` was
written first, failed with `expected 0, found 1`, and is what says seven is the
right number. A CORS with `credentials` or `expose` set still spills at nine, as
it did before.

## What was rejected

**Leaving it alone because the CORS origin is a constant.** It is an argument
about today's CORS rather than about `Vary`, and it would have to be
re-discovered by whoever adds multi-origin support — at which point the bug is
silent and in a cache.

**Joining with a comma.** Correct, tidier on the wire, and it spends the one
axis ADR 0018 does not allow spending. See above.

**Making the static file check whether CORS already set a `Vary`.** It couples
two layers that have no business knowing about each other, in the direction that
breaks first.

**Raising `inline_headers` to nine to cover CORS with credentials.** That case
was spilling before this change and still is; paying 64 more bytes on every
request to fix an allocation on a response already carrying nine headers is the
wrong way round.

## What it costs

**Allocations per request: unchanged at zero**, on the path this touches, and
that is measured rather than argued — the test above drives four requests
through `handleRequest` with a counting allocator and asserts zero allocations
and zero resizes.

**Throughput: one extra comparison per repeating header set**, over a list of at
most seven that is already in L1 because it was just written.

**Memory per idle connection: reasoned to be unchanged, and *not* measured
here.** The 32 bytes are two slices on the `Ctx`, which lives in
`serveRequest`'s frame — `noinline`, and unwound before the connection loop
waits for the next request, which is the whole shape
[ADR 0071](./0071-where-a-connection-waits-is-what-it-costs.md) established. An
idle connection is suspended in `waitForRequest`, several frames above it, and
`releaseIdlePages` hands the touched pages back when it goes quiet.

**That is an argument, not a number, and the distinction is this repository's
own.** `bench/mem.py` reads `ss` and `/proc/<pid>/VmRSS`, both Linux, and this
was developed on Darwin, so the harness could not be run. The figure to beat is
4,669 bytes flat. It is on the roadmap under `nilo_http` as **Waiting on: a
machine**, because a 32-byte change to a frame that is unwound before the wait
is exactly the kind of reasoning ADR 0063 was written after getting wrong.
