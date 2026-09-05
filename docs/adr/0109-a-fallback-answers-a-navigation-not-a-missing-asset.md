# A fallback answers a navigation, not a missing asset

`staticWith(.{ .spa_fallback = "index.html" })` answered **every** path under
its prefix that named no file. That is what a single-page app asks for on a
reload of `/users/42`, and it is also what turns a build that has moved on into
a lie:

- `index.html` refers to `app.abc123.js`; the directory now holds
  `app.def456.js`. The browser fetches the old name, gets **200 and a page**,
  and reports a syntax error on line 1 of something that was never JavaScript.
- A `fetch("/api/orders")` against a path with no route gets a page and reports
  a JSON parse error.

Neither names the missing file, which is the whole cost: the server had the
information and answered with something else.

**The fallback now answers a request that could be a browser opening a page,
and nothing else.** Everything else under the prefix is the 404 it always
should have been, and the 404 says which path.

## The rule

Two tests, in the order a client makes them answerable.

**What the request said it wants.** A browser opening a page sends an `Accept`
naming `text/html`. No asset request does: a `<script src>`, a `<link>` and an
`<img>` send `*/*` or their own type, and a `fetch` for JSON usually says
`application/json`. So a request that **names** HTML gets the page, and one
that names some other type does not. That half is exact, and it is what
`http/accept.zig` was written for.

**What the path looks like, when the client said nothing.** `curl`, a health
checker and an old crawler send `*/*` or no `Accept` at all, and then the path
is the only evidence there is. A last segment with an extension in it is an
asset; one without is a deep link. That keeps `curl /users/42` answering the
page it answered before while `/app.abc123.js` becomes a 404.

The two combine as an OR rather than an AND, and that is a decision rather than
a detail. Requiring both would refuse `/releases/v1.2` to a browser, because a
dot in a route segment is not rare. Taking either lets one case through that a
stricter rule would catch — somebody **typing** `/app.abc123.js` into the
address bar gets the page — and nothing fetches a script that way, so the case
that motivated the change is unaffected.

## What it does not catch

A `fetch()` that sends `*/*` to an extensionless path is indistinguishable from
a deep link at this layer, and gets the page. That is unchanged behaviour, said
out loud in [the guide](../guide/static-files.md#the-fallback-and-what-it-is-for)
rather than left to be discovered. Sending `Accept: application/json` — which
most clients do — is what separates them, and is worth doing for reasons that
have nothing to do with this.

## Why an option, and why it defaults the other way

`.spa_fallback_for = .any_path` is what shipped before, and this is a change in
what a running server answers rather than a compile error, so an application
that depends on the old behaviour can say so in one field. The default is
`.navigations` because the failure it prevents is silent and the failure it
introduces is not: a deep link that 404s is reported by whoever hit it, where a
stale asset served as HTML is reported by nobody and diagnosed by nobody.

## Where the seam moved

`static.Set.find` used to return the fallback, so a caller could not tell a
file that exists from a miss — which is why nothing could decide anything about
the miss. `find` now answers only with a file the set really holds, and
`fallbackFor(path, accept)` is the second half.

`App.findStatic` asks **every** set for the file before it asks any set for its
fallback. That is a second behaviour change and a strictly better one: a
single-page app mounted at `/` no longer answers `/assets/app.css` from its
`index.html` before the directory holding that file is reached. It is the same
ordering rule `docs_set` already had for `/openapi.json`, generalised.

## What it costs

Nothing on the path that finds a file, which is every request an asset makes.
The `Accept` header is read only when a request has already missed every set,
and it is read without allocating: `accept.asks` walks the header once and
answers about one media type. A directory with no `spa_fallback` never reaches
any of it.

`http/accept.zig` is ~90 lines and generic over nothing, so it dead-strips out
of a program that serves no single-page app.
