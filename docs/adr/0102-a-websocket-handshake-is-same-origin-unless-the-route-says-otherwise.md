# A WebSocket handshake is same-origin unless the route says otherwise

`Ctx.handshake` checked the method, `Upgrade`, `Connection`,
`Sec-WebSocket-Version` and `Sec-WebSocket-Key`, and stopped. It never looked at
`Origin`.

**A handshake carrying an `Origin` is now refused with a 403 unless that origin
is the one the request's `Host` named, or one the route listed in
`websocket.Options.origins`.**

## Why this is not the CORS story it looks like

A browser applies no CORS to a WebSocket. It sends no preflight, it honours no
`Access-Control-Allow-Origin`, and it opens the socket whatever the server said.
So a `cors.with(…)` middleware in front of an upgrade route sets headers nobody
enforces, and the socket opens anyway — **carrying the session cookie**, because
the handshake is an ordinary GET and cookies are ambient.

An application with `Session(T)` and `c.upgrade` on the same server was
therefore open to a page on any other origin reading and writing that user's
socket for as long as the tab was open. There was no step at which anything
refused it.

That is the whole difference from
[ADR 0099](./0099-one-allow-origin-header-means-the-list-is-matched-not-formatted.md),
which refused a 403 for CORS on the grounds that "CORS is a rule a browser
enforces on behalf of a user, and a server that answered differently to `curl`
and to a browser would be doing something else". That argument holds exactly
because the browser *does* enforce CORS. Here it enforces nothing, so the whole
check has to be the server's or there is no check.

## Why the default is same-origin rather than "allow everything"

Leaving `origins` empty and meaning "no check" was the compatible option and it
would have shipped the hole with a switch beside it. The people who need the
switch are the ones who already know; the people at risk are the ones who never
read this file.

So the default is the rule almost every deployment already satisfies: the page
and the socket are the same server, so `Origin` names the authority `Host`
named. An application with no session on its sockets and a genuine cross-origin
audience writes `.origins = &.{"*"}`, which is one line and says out loud what
it is doing.

The roadmap's objection to a same-origin default was that "a socket served from
a different host to the page … is an ordinary deployment". It is, and it is
served by naming the page's origin — a line at the call site, with an error
message that names the option when it is missing. What that objection actually
rules out is a default of *refuse every cross-origin request with no way to
allow one*, which is not what this is.

## The scheme is not compared

`Origin` is a scheme, a host and a port. `Host` is a host and a port. This
compares everything after `://` and ignores the scheme, so
`https://example.dev` and `example.dev` are the same place.

That is not laxness, it is the only thing nilo can do: TLS is terminated in
front ([ADR 0028](./0028-tls-is-terminated-in-front.md)), so the server never
learns which scheme the browser used. Requiring `https` would refuse every
deployment; deriving it from `X-Forwarded-Proto` would be trusting a header, and
`trusted_hops` exists precisely because nilo does not do that by default.

What it lets through is a page on `http://example.dev` opening a socket on
`https://example.dev`. An attacker who can serve that page is already a network
attacker on the same host and has cheaper things to do.

## A request with no `Origin` is allowed

`wstest`, `curl`, a Go client, `bench/ws_idle.py` — none of them sends one, and
none of them has an ambient cookie to be borrowed. The whole problem this
addresses is a browser's, and a browser always sends `Origin` on a handshake.

Refusing a missing `Origin` would break every non-browser client and every
benchmark in `bench/`, in exchange for closing nothing.

`null` — what a browser sends from a sandboxed iframe or a `file://` page — is
an `Origin` and matches no authority, so it is refused.

## Where the list lives, and why it is not comptime

On `websocket.Options`, which is per-call, rather than per-App like
`cors.with`.

Per-App was the shape the roadmap sketched. What decided against it is that with
a same-origin default the App-wide list has nothing to say in the ordinary case:
the only application that needs one is the one whose page and socket are on
different hosts, and which page a socket serves is a fact about that route. An
App-wide setting would also need new `App` machinery to carry it, for a value
one call site already has in hand.

It is read at run time, not unrolled while compiling. `cors.with` is comptime
because the value that matched goes back out in a header and has to be one of
the caller's own literals; here nothing goes back out. A handshake happens once
per connection rather than once per request, so an unrolled compare would buy
nothing measurable — and a runtime list is one that can come from
`nilo_config`, which is the thing the CORS list still cannot do.

The compare is case-insensitive for the same reason it is exact in `cors.zig`,
read the other way: nothing is echoed, so there is no spelling that has to
survive.

## What it costs

Nothing per request and nothing per connection. One `indexOf` for `://` and one
`eqlIgnoreCase`, on the handshake, once — plus N more compares if the route
named N origins. No allocation. `websocket.Options` grows a slice header, which
is in the handshake's frame and not the connection's.

## What it breaks

An application serving its socket from a different host to its page, with no
`.origins`, stops working — 403, with a message naming the option and both
origins. That is a deliberate break of a shipped behaviour: the alternative is
that the same application keeps working and so does the attack it is open to.
