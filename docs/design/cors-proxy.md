# CORS and the proxy in front

**Browsers and proxies each read a header on the server's behalf, and nilo answers each exactly as its protocol defines: CORS echoes back the one origin that matched, a proxy's `X-Forwarded-For` is trusted by which machine sent it, CSRF is checked against the browser's own `Sec-Fetch-Site` and `Origin` headers, with no token, and the headers a browser reads as policy go out as one block written while compiling.**

**Guide:** [The ones that come with it](../guide/middleware.md#built-in-logger-and-cors), [Who the client is](../guide/deploying.md#client-ip-address-behind-a-proxy) · **Reference:** [Middleware](../reference/middleware.md), [`listen` options](../reference/app.md#listen-options)

The code is `http/cors.zig` (`Options`, `Origins`, `with`, `reading`, `permissive`), `http/csrf.zig` (`Options`, `with`, `reading`, `sameOrigin`) and `http/proxies.zig` (`Cidr`, `Forwarded`, `holds`).

## Overview

All three answer the same kind of question: which of several possible answers is true for *this* request. Each is decided by matching against a list, not by a single fixed value or a bare count.

```
  CORS: which origin gets the header
    request's Origin ──► compared against origins (comptime list or reading())
                            match  → that origin echoed back, Vary: Origin
                            no match → ordinary response, no header at all

  CSRF: whether a request that changes something may run
    GET, HEAD, OPTIONS ──► through, nothing read
    Sec-Fetch-Site ──► same-origin, none → through
                       anything else     → through only if Origin is named
    no Sec-Fetch-Site, Origin ──► named, or names the Host → through
    neither header ──► through (not a browser)

  Proxy trust: which address is the client
    X-Forwarded-For, walked right to left ──► trusted_proxies (CIDRs, "private", "loopback")
                            entry is ours   → skip, keep walking
                            entry is not    → that is the client; stop
```

## Rules

1. **`Access-Control-Allow-Origin` can carry only one origin.** A server with several front ends matches the request's `Origin` against a list and echoes the one that matched, instead of joining the list into the header. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
2. **The comparison is exact, never case-insensitive**, because the value sent back must be the exact bytes the browser compares against its own origin. A configured origin with a capital letter is rejected while compiling. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
3. **An `Origin` that matches nothing gets a normal response without `Access-Control-Allow-Origin`, never a 403.** CORS is a rule the browser enforces for the user. A server that answered `curl` and a browser differently would be doing access control based on a header the client picks, and that is authentication's job. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
4. **A named list sends `Vary: Origin` on every response, matched or not**, so a shared cache never serves one origin's refusal to another origin that would have matched. `&.{"*"}` reads nothing and sends no `Vary`, because the answer really is the same for everyone. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md)
5. **`*` next to a named origin, an empty list, an empty entry, and `credentials` together with `*` are all rejected while compiling.** The last one is what makes credentials safe without a separate check: the combination browsers themselves reject cannot be built. [ADR 078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md), [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
6. **A front end's address belongs to the deployment, not the program, so `cors.reading(&origins, .{…})` reads its list from a variable the caller fills before `listen()`**, the same way `nilo_config` reads any other setting. Everything else (methods, headers, credentials, max age) stays compile-time, because none of it differs between deployments of the same service. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
6a. **The same holds for a rate limit's numbers and a CSP: `nilo.Late(T)` is a value stated in the program or the address of one filled before `listen()`**, one idiom for `cors.reading`'s cousin `maxBody`, `allowance` and `secure`. What cannot be refused while compiling is refused on the first request as a 500. [ADR 264](../adr/264-a-deployment-fact-is-a-late-value.md)
7. **The list is borrowed, not copied**, so its text must live as long as the server, like `.env` text and the environment block. That is what lets a matched origin go out through `setStaticHeader`, and it keeps a cross-origin request at zero allocations under `reading`, the same as under `with`. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
8. **A list nobody filled rejects every cross-origin request and logs it once**, using an atomic flag on a path a correctly configured server never reaches. [ADR 088](../adr/088-an-origin-is-a-fact-about-the-deployment.md)
9. **`X-Forwarded-For` is trusted by listing which machines may have written it, not by counting hops.** `.trusted_proxies` takes CIDRs, single addresses, or the names `"private"` and `"loopback"`, and it wins over the older `.trusted_hops` when both are set. `host()` and `scheme()` trust `X-Forwarded-Host` and `X-Forwarded-Proto` by the same rule, so no accessor believes a header another one rejects. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
10. **The header is read only when the connection itself comes from a trusted address.** A machine on the open internet cannot claim who it is forwarding for, whatever it writes in the header. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
11. **The list is walked from the right, skipping every entry that is a trusted address; the first entry that is not trusted is the client, and everything to its left is unverified.** If every entry is trusted, the connection's own address is the honest answer, because there is no client behind them. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
12. **All `X-Forwarded-For` fields are read as one list, in the order they arrived.** A proxy may add its own field instead of appending to the client's, and reading only the first field would let a forged entry through an honest proxy. The last eight fields are read (the proxies' end), so padding the front with extra fields cannot push the answer onto a proxy's own address. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
13. **A `trusted_proxies` entry that is not an address stops the server at `listen()`, naming the entry**, before the port is taken, instead of reporting the wrong client address for the life of the deployment. [ADR 102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md)
14. **CSRF is checked against what the browser says about where the request came from, not against a token.** A page cannot set `Sec-Fetch-Site` or `Origin`; the browser writes them. So the check keeps no state, needs no randomness, and puts nothing in the session or the form (which a sealed session and a server with no templates could not carry anyway). [ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)
15. **Only `POST`, `PUT`, `PATCH`, `DELETE` and methods nilo does not name are checked.** A cross-site `GET` is just a link; a `GET` that changes something is a bug in that route, and no CSRF check covers it. [ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)
16. **`Sec-Fetch-Site: same-site` is rejected unless its `Origin` is in the list**, because that is exactly what `SameSite=Lax` lets through: a page on a sibling subdomain posting with the session cookie. When the browser says `cross-site`, an `Origin` that matches the `Host` does not override it. [ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)
17. **A request with neither header is allowed**, because it does not come from a browser and carries nobody else's cookie. Comparing against the `Host` (ignoring the scheme) is only the fallback for a browser that sends `Origin` but no `Sec-Fetch-Site`. [ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)
18. **CSRF is opt-in, and when its trusted list is read at run time it is the same list as CORS**: `csrf.reading(&origins)` takes the same `cors.Origins`. `csrf.with` rejects `"*"`, an empty entry and an entry with a path while compiling. [ADR 224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md)
19. **The headers a browser reads as policy are written by one middleware as one block, in one of two presets**: `nilo.secure.api` for an answer that is data, `nilo.secure.pages` for a server that serves its own front end. Each header is a field, sent or `null`; a value with a closed set is an enum, and `nosniff` has no field because it is never wrong. [ADR 246](../adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)
20. **The block is assembled while compiling and takes one header slot on the Ctx however many lines it has**, so it adds no allocation beside CORS. A second `nilo.secure` on a group replaces the block; a handler that sets one of its headers replaces that line, because two `Content-Security-Policy` lines are enforced together. [ADR 246](../adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)
21. **`Strict-Transport-Security` goes out on plain HTTP too**, which a browser ignores there (RFC 6797 §8.1), because behind a platform that terminates TLS and adds nothing it is the only place the header comes from. [ADR 246](../adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)

## Decisions

| ADR | What it decides |
|---|---|
| [078](../adr/078-one-allow-origin-header-means-the-list-is-matched-not-formatted.md) | `origins` is a list to match, not a string to format, and what happens when nothing matches |
| [088](../adr/088-an-origin-is-a-fact-about-the-deployment.md) | `cors.reading`, a list read at run time for the one setting that differs by deployment |
| [264](../adr/264-a-deployment-fact-is-a-late-value.md) | `nilo.Late(T)`: a value stated in the program or filled before `listen()`, for the rate limit and the CSP as well |
| [102](../adr/102-a-proxy-is-trusted-by-which-one-it-is.md) | `trusted_proxies`: trust by address instead of by hop count |
| [224](../adr/224-a-request-that-changes-something-says-where-it-came-from.md) | `csrf`: a request that changes something is checked against `Sec-Fetch-Site` and `Origin`, and why not a token |
| [246](../adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md) | `secure`: the policy headers as one block in two presets, and why not one header a slot |

Related topics: the header caching rule that makes `Vary: Origin` necessary even when nothing matched is [ADR 029](../adr/029-a-header-is-checked-once-and-two-of-them-repeat.md). A `Middleware` is a bare function pointer, which is why `cors.reading` needs a variable the caller owns instead of a Service; that is decided in [ADR 008](../adr/008-middleware-is-an-onion-of-ctx-functions.md). A repeated `Host` or a smuggled request is rejected for the same reason `trusted_proxies` rejects a forged hop: [ADR 070](../adr/070-a-request-nobody-else-would-answer-is-refused.md).

## Open questions

Nothing is open.
