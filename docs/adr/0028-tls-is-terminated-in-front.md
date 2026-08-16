# TLS is terminated in front, and that is the answer rather than the plan

`docs/roadmap.md` carried TLS under "Not decided" with the note that it *may stay out on purpose*. This decides it. **nilo does not speak TLS, and is not going to.** It listens on plaintext HTTP and expects a proxy in front of it wherever the internet is involved.

The question that settled it was not "how hard is TLS" but "what does every other server in the comparison actually do".

## Nobody writes their own

| | TLS? | from where |
|---|---|---|
| Go `net/http` | yes | `crypto/tls`, in the standard library |
| Go Fiber | yes | a thin layer over the same `crypto/tls` |
| **Rust axum** | **no** | needs `axum-server` + `rustls`, or `tokio-rustls` |
| Node | yes | the OpenSSL it ships with |
| Bun | yes | the BoringSSL it ships with |
| http.zig | no | — |

Not one of them implemented TLS. Every yes in that table is a server plugged into a TLS implementation somebody else wrote, funded and had audited — and axum, the one most like nilo in ambition, does not have it at all. Its users bolt on rustls, which is a separately funded project with its own audits.

Zig has no such thing to plug into. `std/crypto/tls/` in 0.16 contains exactly one file, `Client.zig`. The standard library can *make* a TLS connection — that is how `zig fetch` reaches an HTTPS URL — and cannot *accept* one.

## What the options actually were

**Write it.** A record layer, a handshake state machine, X.509 chain validation, session resumption, ALPN, and constant-time everything. Getting it wrong does not produce a bug report, it produces a private key in somebody else's hands, and there is no test suite that tells you which one you shipped. This is the "don't roll your own crypto" case in its most literal form.

**Depend on a Zig TLS library.** `ianic/tls.zig` and `Geun-Oh/zigtls` both exist and both do server-side TLS 1.3. This is the option that deserved a real look, and the thing that decided it against is already written down as the project's first standing risk: *zio is a one-person project*. That risk is survivable because the Bulkhead was fitted before it was needed and because the failure mode is a server that stops working — loudly, at build time or at run time. A one-person crypto library is a second dependency of the same kind at a place where the failure mode is silent and the blast radius is every secret the server has ever handled. The two are not the same risk twice; the second one is worse.

**Link OpenSSL or BoringSSL.** Correct, audited, and what Node and Bun do. It also ends `zig fetch` as the whole installation story: a C toolchain to build, a cross-compilation story to explain, and megabytes of binary for a feature most deployments will never switch on.

## What it would have cost even if it worked

[ADR 0018](./0018-the-trade-budget-has-three-axes.md) has two rows that are invariants rather than budgets: one allocation per request, and a stated memory cost per idle connection. Both are now measured and published — 1 allocation, 8,767 bytes.

TLS takes both. A connection needs record buffers in each direction, 16 KB each at the maximum record size, so the per-connection figure goes from 8,767 bytes to something like five times that. The handshake allocates. The number that `comparison.md` puts third out of nine, and the flatness from 1,000 connections to 10,000 that makes it safe to multiply, are properties of a design with no TLS in it.

That is not a reason to refuse TLS on its own — plenty of servers pay it and are right to. It is a reason to notice that adding TLS would mean deleting the two claims that currently distinguish nilo from anything else in that table.

## And most deployments have already terminated it

The audience for this decision is somebody putting a Zig HTTP server into production. In practice that is Fly.io, Railway, Render, Cloud Run, a Kubernetes ingress, an ALB, or Cloudflare — and every one of those terminates TLS before the request reaches the process. For those deployments nilo speaking TLS would be a feature that is switched off.

What is left is a bare VPS wanting to answer `:443` directly, and the answer there is five lines of Caddy and a certificate that renews itself.

## Consequences

- **The client's address stops being obvious, and that is a real cost.** Behind a proxy every connection appears to come from the proxy, so rate limits, audit logs and blocklists are blind unless something reads `X-Forwarded-For`. This ADR is the reason `Ctx.clientIp()` and `listen(.{ .trusted_hops = … })` exist; they are not a separate feature, they are this decision's other half.
- **HTTP/2 goes with it.** Browsers only speak HTTP/2 over TLS, negotiated with ALPN during the handshake. No handshake, no ALPN, no HTTP/2 — and no gRPC server either, since gRPC is HTTP/2. Somebody reading "no TLS" will not derive "no gRPC" on their own, so both are said out loud in the docs.
- **mTLS between services is not available.** A service mesh that wants client certificates has to terminate them in a sidecar.
- **The deploying guide owes people a working proxy config**, not a suggestion to find one. A refusal that leaves the user to work out the replacement is half a decision.
- **This is reversible in one direction only.** If Zig's standard library grows a TLS server, or a Zig TLS library acquires the funding and the audits that rustls has, the argument above changes and this ADR should be revisited. The memory argument would still stand, which is why it is written down separately from the trust one.
