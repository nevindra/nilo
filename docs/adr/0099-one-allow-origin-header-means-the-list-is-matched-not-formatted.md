# One Allow-Origin header means the list is matched, not formatted

`cors.Options.origin` was a single compile-time string, so a server with a
production front end and a staging one could not use the middleware at all and
wrote its own. The obvious repair is a list.

**`origins: []const []const u8` replaces it, and the list is matched against the
request's `Origin` rather than joined into a header value.**

## Why matching, and not a longer header

`Access-Control-Allow-Origin` carries one origin or `*` and nothing else. It is
not a comma list — the Fetch standard defines it as a single serialized origin,
and every browser reads it that way. So a server that answers two front ends has
to decide *per request* which one it is talking to, which means reading the
`Origin` header the browser sent and sending that same value back.

That is the whole of the design and it is why the field could not stay a string.

## What it costs

The compare is an `inline for` over what the application wrote, so N `mem.eql`s
against short literals with no loop and no indirection, paid only by a request
that carries an `Origin`. Nothing per connection. Nothing allocated: the value
that goes out is one of the caller's own literals, handed to `setStaticHeader`
like every other value in this file, so the request arena is untouched.

`&.{"*"}` is recognised while compiling and takes the old path exactly — one
static header, no header read, no `Vary`. The whole matching branch is behind
`if (comptime any)`, so an application on the default does not compile it at
all, which is every example in the repository and the benchmark server.

**The roadmap said "nothing per request that is not cross-origin", and that is
not quite true.** An application with a named list pays one walk of the request
headers on *every* request, because the only way to find out a request has no
`Origin` is to look for one. That is inherent to matching rather than a choice
in how it was built: a header that decides the answer has to be read. It is
below the 10% bar in
[ADR 0001](./0001-dx-wins-below-the-10-percent-threshold.md) by a wide margin —
one scan of a handful of short names against a whole request — but it is
reasoned rather than measured, and nobody should quote it as measured.
`bench/main.zig` uses `permissive` and so cannot see it; giving it a named
origin to find out would move the published throughput baseline for everything
else in the file.

## Two places this differs from the design as written down

`roadmap.md` sketched this before anybody built it, and two of its sentences did
not survive contact.

**It said `eqlIgnoreCase`, and the compare is exact.** Case-insensitive matching
sounds strictly more forgiving and is a trap here. The value sent back has to be
the bytes the browser sent — a browser compares `Access-Control-Allow-Origin`
against its own origin exactly — so matching `https://EXAMPLE.com` against a
configured `https://example.com` and then echoing the configured spelling
produces a response the browser rejects, with a CORS error that names nothing.
The alternative, echoing what arrived, means putting request-lifetime bytes into
`setStaticHeader`, which is documented for text that outlives the request.

So the compare is `mem.eql`, and **an origin with a capital letter in it is
refused while compiling**, with the lowercase form in the message. A browser
lowercases the scheme and host before it sends them, so a configured origin with
a capital in it could never have matched anything; what was a silent failure in
production is now a build error naming the fix. Three more refusals go with it:
an empty list, an empty entry, and `*` sitting beside a name it already covers.

**It said "a list of one behaves exactly as today", and it does not.** The
single string was sent on *every* response, including requests with no `Origin`
at all. A named list is sent only to an origin that matched. Browsers cannot
tell the difference — they ignore the header unless they sent an `Origin` — but
`curl` can, and so can a test, which is why this is written down rather than
left as a surprise. Sending one origin's name to a request from somewhere else
was never right; it was just invisible.

## The refusal is the browser's, not the server's

An `Origin` that matched nothing gets an ordinary response — the handler runs,
the status is whatever it would have been — without the header that would let
the page read it. A preflight is answered 204 the same way, without the header.

Refusing with a 403 was rejected. CORS is a rule a browser enforces on behalf of
a user, and a server that answered differently to `curl` and to a browser would
be doing something else: an access control decision, on the strength of a header
the client chooses. Anything that must be denied to a stranger is denied by
authentication, which does not consult `Origin` at all.

## `Vary: Origin` is sent on the misses too

A named list sets `Vary: Origin` whether or not anything matched, which is what
stops a shared cache storing a refusal under a key that an allowed origin will
later read — the same argument as
[ADR 0089](./0089-two-layers-can-each-name-a-vary-axis.md), which is why the
caching half of this was already done. `*` sends no `Vary`, because that
response really is the same for everybody.

## It breaks a shipped signature, deliberately

`origin` shipped in 0.2.0 and is gone rather than kept beside `origins`. Two
fields for one job would need a rule for what happens when both are set, which
is the shape this repository keeps refusing — most recently over `pw.verify`.
Inside the repo the rename touched three files; outside it, a program that wrote
`.origin` gets a compile error at the call site.

The cost is the release: `CHANGELOG.md` promised that no source change was
needed to move a 0.2.0 program to this, and that promise is withdrawn.
