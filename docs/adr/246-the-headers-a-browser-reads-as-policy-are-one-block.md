# The headers a browser reads as policy are one block

**Status:** accepted
**Topic:** [cors-proxy](../design/cors-proxy.md)
**Closes:** the roadmap's open question "Whether nilo ships the response headers a browser reads as policy".

`X-Content-Type-Options`, `Content-Security-Policy`, `Strict-Transport-Security`, `X-Frame-Options`, `Referrer-Policy` and the three `Cross-Origin-*` headers are constants for the whole of a deployment, and every framework nilo is compared with ships them: Express has helmet, Fiber `helmet`, Echo `Secure`, Gin `secure`. The roadmap held the question open on two arguments. The proxy in front ([ADR 027](./027-tls-is-terminated-in-front.md)) is where an operator already writes these, and a framework that sets half of them invites the belief that it set all of them.

The first stopped being true of most deployments. A platform that terminates TLS in front (Fly, Render, Railway, Cloud Run, a load balancer) adds none of these, so the application is the only place they can come from, and a `-Dtls` listener ([ADR 212](./212-tls-is-an-option-a-build-asks-for.md)) has nothing in front at all. The second is an argument about the shape, so the shape answers it: one middleware writes the whole set, and each header is a field that is either sent or explicitly `null`.

## Decision

`nilo.secure.api(.{})` and `nilo.secure.pages(.{})`, two presets of one middleware:

```zig
try app.use(nilo.secure.api(.{}));     // JSON, and nothing a browser renders
try app.use(nilo.secure.pages(.{ .csp = "default-src 'self'; img-src 'self' https://cdn.example.com" }));
```

| header | `api` | `pages` |
|---|---|---|
| `X-Content-Type-Options` | `nosniff`, always, no field | the same |
| `Content-Security-Policy` | `default-src 'none'; frame-ancestors 'none'` | `'self'` for scripts, styles, fonts, images and forms; inline and `https:` styles; no plugins, no inline script, framing by this origin only |
| `Strict-Transport-Security` | `max-age=31536000` | the same |
| `X-Frame-Options` | `DENY` | `SAMEORIGIN` |
| `Referrer-Policy` | `no-referrer` | `strict-origin-when-cross-origin` |
| `Cross-Origin-Opener-Policy` | not sent | `same-origin-allow-popups` |
| `Cross-Origin-Resource-Policy` | not sent | `same-origin` |
| `Cross-Origin-Embedder-Policy`, `Permissions-Policy` | not sent | not sent |

**The whole block is assembled while compiling and kept as one of the seven header slots on the Ctx.** `Ctx.putPolicy` stores it as an entry with an empty name, which `headerNameOk` refuses for anything else, and `http1.writeExtra` writes such an entry as it is. The middleware is one store. A second `nilo.secure` on a group replaces the block, so a group of pages can carry `pages` under an App that carries `api`.

**A handler that sets one of these headers replaces that line of the block.** When `putHeader` meets the block, it calls the function `putPolicy` left on the Ctx (`_policy_edit`). That function asks `http1.isPolicyHeader` (a switch on the length, then a compare) and takes the line out with `http1.withoutLine`, one arena allocation on the route that did it. It is a pointer rather than a call because a call behind a runtime check is still linked: this way a program with no `nilo.secure` carries none of the matching. Sending both would not be "the handler's wins": a browser enforces every `Content-Security-Policy` it is given, so the page would get the intersection, the policy nobody wrote.

**A value with a closed set is an enum.** `Referrer-Policy`, the three `Cross-Origin-*` and `X-Frame-Options` cannot be misspelt into a header the browser ignores. The two with an open grammar, the CSP and `Permissions-Policy`, are text, refused while compiling when empty or holding a control byte. `hsts.preload` without `include_subdomains` and a year is refused, because hstspreload.org refuses it.

**HSTS goes out on plain HTTP too.** RFC 6797 §8.1 has a browser ignore it on a connection that was not TLS, so sending it from a server behind a TLS-terminating platform is exactly when it does its job, and sending it on `http://localhost` does nothing.

## Why these presets

`pages` is helmet's default, which is the set most of the web already runs, with four changes. `X-XSS-Protection`, `X-Download-Options` and `X-Permitted-Cross-Domain-Policies` are gone because no browser reads them. `upgrade-insecure-requests` is gone because on a plain `http://localhost` page it turns every asset into a failed load. `Referrer-Policy` is `strict-origin-when-cross-origin`, the browsers' own default, rather than `no-referrer`, because an embed that checks where it is shown (a YouTube player) refuses to play without one. `Cross-Origin-Opener-Policy` is `same-origin-allow-popups` rather than `same-origin`, because the stricter value cuts the handle a "Sign in with Google" popup reports back through.

`api` is OWASP's REST Security Cheat Sheet: an answer that is data should not be rendered, framed, sniffed or given a referrer.

## What was rejected

**One header a slot, through `setStaticHeader`.** It was the obvious shape, `cors.zig`'s exactly, and it costs the allocation axis. `pages` is six headers, and CORS with a named origin is two more; the Ctx holds seven ([ADR 029](./029-a-header-is-checked-once-and-two-of-them-repeat.md)), so every request on an App with both would spill to the arena, which is an allocation on a path that did not ask for one. `test "nilo.secure beside a named-origin CORS adds nothing to the request path's allocations"` is the shape that would have failed, with eight distinct headers.

**One middleware, with every field defaulting to the `pages` value.** An API would then carry 515 bytes of policy written for a page. Two presets cost a second struct and say which kind of server it is.

**A CSP built from typed directives** (`.script_src = &.{.self}`). A CSP is a grammar with nonces, hashes, schemes and host patterns, and a type for all of it is a second language to learn for a header people copy from the browser's own console. The text is checked for the two mistakes that break the header line and passed through.

**Setting the CSP only on `text/html`.** It would save the bytes on a JSON answer, and it cannot be done in a middleware: the content type is chosen when the handler sends, and the head is written then ([ADR 008](./008-middleware-is-an-onion-of-ctx-functions.md)).

**On by default.** A default CSP breaks every page that loads a script from a CDN, the day it upgrades. One line opts in.

## A policy that is a fact about the deployment

`.csp` is a `nilo.Late([]const u8)` ([ADR 264](./264-a-deployment-fact-is-a-late-value.md)): text settled while compiling, which is part of the one block as above, or the address of a `[]const u8` filled before `listen()`, which is set beside the block with `setStaticHeader` (one more header slot, no copy). The two refusals for a stated policy run on the first request for a held one.

## What it costs

- **Allocations per request:** none, beside CORS with a named origin, held by the test above. A handler that overrides one line spends one arena allocation for the rest of the block.
- **Memory per idle connection:** none. The block is a constant in the binary, and the slot is on the Ctx, which is unwound before the connection waits ([ADR 062](./062-where-a-connection-waits-is-what-it-costs.md)).
- **Throughput:** two stores, and the block's bytes on the wire: 200 for `api` and 515 for `pages`, held by `test "what each preset adds to a response is the number its header says"`. `putHeader` on a route behind the block makes one indirect call per header set, and `isPolicyHeader` behind it is a length switch that rejects nearly every name on the first compare. Not benchmarked; the primary metric does not install it.
- **Binary size:** in a program that does not name `nilo.secure`, the `writeExtra` branch and the null check on `_policy_edit`, both one compare. The first build put the matching in `putHeader` directly and every program paid about 1.2 KB for it; behind the pointer it went. In a program that does name it, the block and a few hundred bytes of code. The Ctx is 8 bytes larger for the pointer, on a frame unwound before the connection waits.

## What it breaks

Nothing: it is opt-in. A page behind `pages` that loads a script from another origin is refused by the browser, which says so in the console naming the directive; the fix is a `.csp` that names the origin.
