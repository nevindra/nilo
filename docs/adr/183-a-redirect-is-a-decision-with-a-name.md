# A redirect is a decision with a name, and a followed one says where it ended

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)

## Context

An empty `redirect_buffer` meant redirects were not followed and a 3xx came back as itself. For anything signed that is the right default. But "I do not want this followed" and "I did not think about redirects" were the same absence, and the symptom of the second was a `Head` with status 301 that a caller read as a bad upstream and reported as one. fdm did think about it, because `mirrors.kernel.org` made it, and the next CLI on nilo would find it the same way, in the first week, from a server that was right.

Once redirects had a name of their own, following one still lost where it ended. fdm needs it: the sixteen connections after a probe should hit the final URL rather than repeat the chain sixteen times. It got there by reaching through the `Exchange` into `std.http.Client.Request.uri`, which nilo does not promise, and formatting it before the `redirect_buffer` went out of scope; the comment explaining the lifetime was longer than the code.

## Decision

### `Begin.redirects` is a union with three arms, and the default says so out loud

- **`.refuse`, the default:** a 3xx with a `Location` is `error.RedirectRefused`. A 304 has no `Location`, is an answer to `if-none-match`, and is handed over as itself.
- **`.follow = &buf`:** walked by `nilo_fetch` itself, three deep at most, the `Location` resolved in the buffer, `head.redirected` saying where it ended (below), and each hop held to the origin rule (below).
- **`.expose`:** the 3xx as itself, 302 and all, for the signed request that checks where an object moved and for the client that reads the body of the answer, which is where S3 puts the reason for a 301; `s3/bucket.zig` says it on every call, because a signature is over one host and following would send it elsewhere.

The intent has a name, the buffer goes where the one intent that needs it is, and the absence of a decision is no longer spelled like one. `Client.get` and the rest follow it as they did.

### A followed redirect leaves its credentials at the origin they were written for

`std.http.Client` walks a redirect inside `receiveHead` and strips only its own `privileged_headers` when the next domain is not the same parent domain. `nilo_fetch` never fills that list: a Target's `authorization` goes in std's own slot and a call's `Authorization` in `extra_headers`, so both were written again on every hop, including one from `https` to `http`. A third-party API that answers with a redirect to a file host was all it took to hand a token to a stranger.

So `.follow` is std's `.unhandled` and `Exchange.begin` walks the chain, one request a hop, under the permit and the deadline the call already holds. Each hop is compared with the one before it:

- **Another place is another origin**: scheme, host or port, as reqwest and the Fetch standard have it, not std's `sameParentDomain`, which is Go's looser rule and counts a subdomain. A port left out is the scheme's own; hosts compared without regard to case; anything that cannot be shown equal counts as different.
- **Past another origin** the `authorization`, `cookie`, `proxy-authorization` and `www-authenticate` lines, the `host` the call named, the `authorization` and `host` fields of `Begin`, and every header named in `Begin.origin_only` are dropped. `Client.send` puts a Target's standing headers there, because nilo cannot tell an `x-api-key` from an `accept`. What is dropped stays dropped: the hop is rewritten in place, so a chain that goes out and comes back does not pick it up again.
- **`https` to `http` is `error.InsecureRedirect`**, whatever the host. A caller who means it asks for the `http://` address.
- **The method and the body change as std's did**: a 303, and a 301 or 302 on a POST, become a GET with no body (and `content-type` and `content-length` lines go with it); any other redirect of a call with a body is `error.RedirectRequiresResend`. A HEAD is not followed, as before.

### `Head.redirected` is the `std.Uri` a followed redirect ended at, or null, and `head.location(buf)` writes it out as one string

`begin` counts the redirects it has left; fewer than it started with is a chain it walked, and the address it ended at is then the end of it, resolved by std's own `resolveInPlace` into the `redirect_buffer` the call was given. That is where the text lives: good for as long as the buffer is, which the caller owns.

The string form takes a buffer because a `std.Uri` is components, and writing them out needs somewhere to go. `error.NoSpaceLeft` is a URL longer than the buffer that held it, which is the only way it fails.

## What was rejected

**Keep the field and make a 3xx with an empty buffer the error.** Breaks nobody, and leaves the buffer's emptiness carrying two meanings with an error deciding between them at run time. The union costs every `begin` with a `redirect_buffer` in it one line each, and the alternative left the release untagged.

**An error on every 3xx.** A 304 is not a redirect, and a client sending `if-none-match` is owed it as an answer rather than as a failure with the right name.

**`location: ?[]const u8` on the Head, as a slice.** The obvious shape. There is no memory for it: the resolved URL is components pointing into `redirect_buffer`, and formatting them into the same buffer overwrites what they point at. A slice would need an allocation per redirected call, and `begin` has no Scope to take it from.

**Std's own walk with the credential list filled in.** `Request.privileged_headers` is std's slot for exactly this, but it is one list for every hop, it cannot be filled by a caller who also uses std's `authorization` slot, and the domain rule it applies is the loose one. Walking the chain here costs one loop and decides the rule in the one place that knows what the call carries.

**`redirected` on `Response` was rejected, and is now there.** `Client.send` keeps its redirect buffer on its own stack, so the text had to be copied out before it went, and that was an allocation on a path that did not ask for it. It is one arena allocation on a call that *was* redirected and none on one that was not, which is the trade `head.keep` already makes, and a caller who is told a call ended somewhere else needs to be able to see where. `Response.redirected` is the URL as a string, without its userinfo and fragment.

## What it costs

| Axis | Cost |
|---|---|
| Allocations per request | 0 on a call that is not redirected. A redirected call adds one in the Scope for `Response.redirected`, and one from the client's allocator (freed before the call returns) on a hop that has a header to drop |
| Memory per idle connection | `@sizeOf(?std.Uri)` on a `Head`, a value the caller holds for the head's window and not for the connection |
| Throughput and p99 | 0: a comparison of two integers at `begin` for the union, one more at redirect resolution |
| Binary size | not measured separately; the walk is one loop and three small functions, and it replaces std's `redirect` for this caller |

The union is the same slice and a tag, one error added to the set. The redirect test serves a `302` to `/moved` and a `200` on one connection, and reads `http://127.0.0.1:<port>/moved` back out of the head; the control asks the same of an answer that came from the URL it asked for and gets null. One connection rather than two, because std pools the first and comes back on it: a server that hung up after the `302` handed the client a reaped socket, and the stale-connection retry then sent the *original* URL again, which is a different test and the one that was accidentally written first.
