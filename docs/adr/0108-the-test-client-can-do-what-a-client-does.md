# The test client can do what a client does

`testing.Client` had `get`, `post`, `postWith` and `request`. Every one of them
wrote `Host: test`, a `Content-Length` and nothing else. So a test of a route
behind `Authorization`, behind CORS, or behind a session had to hand-assemble
the raw request text and call `send`, and a sign-in followed by a request *as*
that user meant copying the `Set-Cookie` out of one `Answer` and pasting it into
the next request by hand — which is what `examples/forms` does.

**That is the one place in this framework where the ordinary thing is harder
than the raw thing**, which is the opposite of what the rest of it sells.

Three things are added and they are all additive:

- `client.sendRequest(&app, .{ … })` — a whole request described field by
  field, every field defaulted. The four helpers are now this with defaults.
- `client.setHeader(name, value)` — sent with every request from now on.
- `Options.cookies` — a jar.

## The jar is off by default, and that is the decision

Turning it on for everybody is the shape that reads better and it is not
available. This API shipped without a jar, so every suite written against it has
requests that carry no cookie; switching one on underneath them would change
what those tests assert without changing a line of them. A test that signs in
and then checks it is *not* signed in is rare, and a rare test that silently
stops testing what it says it tests is the worst possible failure for a testing
library to ship.

So a suite that wants the jar says so once, in `init`.

## What the jar reads, and what it deliberately does not

`Max-Age` of zero or less means the cookie is being removed, which is what
`c.clearCookie` sends
([ADR 0030](./0030-a-cookie-is-a-header-and-set-cookie-is-the-one-that-repeats.md))
and is the whole of what a handler here can produce. `Path`, `Domain`, `Secure` and
`Expires` are ignored.

A browser honours all of them. This is not a browser: it is one App on one host
with no TLS under it, and a jar that guessed at scope would be a second
implementation of cookie matching to be subtly wrong in — with the failure
landing as a test that passes for the wrong reason. `answer.setCookie(name)`
still hands back the whole line, attributes and all, for a test that wants to
assert on the scope rather than rely on it.

## Why the helpers had to stop writing headers unconditionally

`sendRequest` writes `Host`, `Content-Type` and `Content-Length` **only if
nothing already named them**. That is not tidiness. Since
[ADR 0101](./0101-a-request-nobody-else-would-answer-is-refused.md) a second
`Host` is a 400 and so is a second `Content-Length`, so a helper that added its
own on top of a header the caller wrote would answer 400 to a test that looked
correct — and the test author would go looking in their handler.

`Content-Length` is still written for a body of nothing, which is what the four
helpers have always sent. Keeping that means the bytes `get`, `post`,
`postWith` and `request` produce are unchanged to the byte.

## `send` is left alone

The raw entry point applies neither the sticky headers nor the jar: the bytes
are the caller's, exactly as given, which is the entire reason it exists. It
does still *read* the answer into the jar, so signing in with a hand-written
request and going on with `get` works.

## What is still missing

A WebSocket route cannot be driven at all — `Client` has no way to hand the App
a reader that answers frames. That is a design of its own rather than a fourth
method, and it stays in the roadmap as its own entry.

## What it costs

Nothing anybody deploys: none of this is on the request path and none of it is
in a release binary. Two `ArrayList`s per `Client`, both empty until used.
