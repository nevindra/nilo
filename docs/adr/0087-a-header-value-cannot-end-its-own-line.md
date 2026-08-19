# 0087 — a header value cannot end its own line

**Status:** accepted
**Amends:** [ADR 0030](./0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md)

## Context

A response header is `name: value\r\n`. There is no escaping in that grammar. So
a value carrying a `\r\n` does not produce a broken header — it produces a
**second header**, and a value carrying two of them ends the head and starts a
**second response**. That is response splitting, and it has been the same bug
since 2004.

nilo had already decided this twice, and both times it decided it correctly:

- **`cookie.check`** refuses a `;` in a cookie value, and its comment says why:
  *"That is response splitting with extra steps, and it is refused here rather
  than escaped, because there is no escaping in this grammar to do it with."*
- **`Ctx.requestId`** refuses a client-supplied `X-Request-Id` that is not 1–64
  bytes of `[A-Za-z0-9._-]`, and its comment says why: *"a newline forges a line
  of its own, and in a response header it splits the response."*

**What neither of them covered was the general case.** `putHeader` — the one
function every response header goes through — checked `isReservedHeader` and
nothing else. `Ctx.setHeader`, `Ctx.setStaticHeader`, a `Response(T)`'s
`.headers`, a `Redirect(status)`'s `.headers` and every built-in middleware all
wrote whatever bytes they were handed, and `http1.writeHead` printed them with
`{s}: {s}\r\n`.

Two things made this worse than a missing check usually is.

**The framework's own documented example feeds it untrusted text.** From
`redirect.zig`'s header comment, repeated in `docs/guide/responses.md`:

```zig
fn shortLink(db: *Db, code: nilo.Str) !nilo.Redirect(302) {
    return .to(try db.target(code.view()));
}
```

`location` goes to `setHeader` unexamined. The doc comment beside it reads
*"nilo passes it through untouched, because what counts as a sensible
destination is the application's business"* — which is right about *which URL*
and wrong about *whether it is one header*.

**`Set-Cookie` had a way past its own check.** `c.setCookie` validates through
`cookie.check`; a `Set-Cookie` written as a plain header — which is exactly what
`Redirect.with("/welcome", .of(&.{.{ .name = "Set-Cookie", .value = session }}))`
does, and it is the documented way a sign-in answers — reaches `putHeader`
directly and never sees it.

## Decision

**`putHeader` is the choke point, and it checks the name and the value.** Three
refusals, one shape:

| | Refused | Because |
|---|---|---|
| reserved name | `Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection` | as before — two of any is malformed, and two `Content-Length` is smuggling |
| the name | anything that is not RFC 9110 §5.1 `token` | a space or a colon ends the name early and starts a field nobody wrote |
| the value | anything below `0x21` that is not SP or HTAB, and `0x7F` | CR and LF start a second header; NUL and DEL mean the value came from somewhere it should not have |

`obs-text` — everything from `0x80` — is **allowed**. It is deprecated and it is
also what a UTF-8 filename in a `Content-Disposition` is made of, and it cannot
terminate a line, which is the only thing being defended.

**The choke point is the decision, not the predicate.** It is `aboutToRead`'s
shape (ADR 0004): one place that every path already goes through, so a new way
to set a header gets the check without anybody remembering to give it one. There
were five callers and one of them — `Response.headers` — was added a year after
`setHeader` and would have been the one to forget.

**All three refusals are `fail.internal`**, matching `setCookie`. A malformed
header is a mistake in the server, not in the request, and a bare
`error.ReservedHeader` reached the client as `"internal server error"` and sent
whoever read it looking through their handler for something that was not there.
Now the 500 names the header and says which rule it broke. **The value is never
quoted back** — it is the half most likely to have come from a request, and a
response echoing it would hand the sender a way to read what the check caught.

`error.ReservedHeader` is gone. It was never in `docs/reference.md`; only the
behaviour was, and the behaviour is unchanged.

## What was rejected

**Escaping instead of refusing.** There is nothing to escape *to*. RFC 9110
retired `obs-fold`, so a value cannot legally span two lines at all, and
inventing an encoding would mean the client has to know about it.

**Stripping the bad bytes and carrying on.** A `Location` with the newline
deleted is a *different URL*, sent silently. Refusing is louder and the loudness
is the point — the handler is passing text it did not check.

**Checking in `http1.writeHead` instead.** It is one layer lower and would catch
the same bytes, but it runs while the response is being written, where there is
nothing left to answer with: the status line has already gone out. `putHeader`
runs before anything is sent, which is what makes a 500 possible.

**A `Debug`-only check, the way `Str`'s lifetime trap is.** That trap catches a
bug in *your* code, which a test run will reach. This one catches bytes that
arrive from outside at three in the morning, and a check that is off in the mode
people deploy in is not a check (ADR 0033).

## What it costs

**Throughput: one pass over bytes already in L1, on a path that was going to
write them anyway.** A header is set two or three times on a response that sets
any, and the values are tens of bytes. The primary metric is a route that sets
none.

**Allocations per request: unchanged at zero.** Both predicates are a loop over
a slice.

**Memory per idle connection: unchanged.** Nothing is stored.

**Binary size: 0 bytes.** Stripped `ReleaseFast`, built against `HEAD` in a
scratch tree rather than quoted, and measured on four examples:

| | before | after | delta |
|---|---|---|---|
| `hello` | 650,720 | 650,720 | 0 |
| `rest` | 782,256 | 782,256 | 0 |
| `orders` | 897,360 | 897,360 | 0 |
| `forms` | 732,880 | 732,880 | 0 |

The binaries differ — the checksums are not the same — so this is two byte loops
fitting inside padding that was already there, not a build that did not happen.
Nothing to add to ADR 0018's running total.

The one behaviour change a user can see: a handler that was writing a header
with a control byte in it now gets a 500 instead of a response somebody else can
forge. There is no version of that trade worth arguing about.
