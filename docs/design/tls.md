# TLS

**nilo is not meant to terminate TLS on the public internet, and the TLS option it does offer costs nothing in a build that does not ask for it.**

**Guide:** [TLS without a proxy](../guide/deploying.md#tls-without-a-proxy) · **Reference:** [The App](../reference/app.md) (the `tls` row)

The code is the Engine's TLS connection loop (the only file allowed to name the library, ADR 001), the key and certificate check at `listen()`, and the fork `nevindra/tls.zig` pinned in `build.zig.zon`.

## Overview

```
                default build: no -Dtls, no -Dhttp2
internet ──► proxy (Caddy, ALB, Cloudflare) ──► nilo, plaintext HTTP/1.1
                                                 (ADR 027: still the recommendation)

                a build that passes .tls = true
client ──TLS 1.3 handshake──► nilo's listener
             │  record layer, state machine        ── on the executor
             └─ signature over the transcript       ── hopped to the blocking pool,
                                                        fiber parked (ADR 217)
          -Dhttp2 as well: ALPN offers "h2" then "http/1.1" ──► HTTP/2 or HTTP/1.1 by what was chosen,
                           from the entry's one frame after the handshake (ADR 259)
```

## Rules

1. **nilo does not act as a TLS server on the public internet, and a proxy in front is still the recommendation.** Every comparable server plugs into someone else's audited implementation; Zig has none to plug into, and writing one is ruled out. [ADR 027](../adr/027-tls-is-terminated-in-front.md)
2. **In a build with `-Dtls` and `-Dhttp2`, a TLS listener offers `h2` and `http/1.1` by ALPN, `h2` first, and serves what was chosen.** A client that sends no ALPN at all is served HTTP/1.1; a client that offers ALPN with neither protocol in it gets RFC 7301's `no_application_protocol` alert. Without `-Dhttp2` the handshake offers `http/1.1` alone, as it always did. A WebSocket stays HTTP/1.1 ([ADR 260](../adr/260-a-request-on-http2-runs-from-its-headers.md)). [ADR 027](../adr/027-tls-is-terminated-in-front.md), [ADR 259](../adr/259-http2-is-a-framing-of-every-request.md)
3. **TLS 1.3 is a listener option in a build that asks for it, and the default build contains none of it.** A dependent passes `.tls = true` to `b.dependency("nilo", …)` (`-Dtls` in this repository). The library is fetched through `b.lazyDependency` only under that flag, so a build without it fetches and links nothing. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
4. **Without the flag, `.tls` is rejected at `listen()` with a one-line message**, like a port that is already taken, and is never served as plain HTTP on a port the caller thought was encrypted. The same message rejects `.tls` on a unix socket. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
5. **A private key that does not belong to the certificate is rejected at `listen()`, before the port is taken.** The public keys are compared by scheme (the EC point, the RSA modulus, the Ed25519 bytes); a scheme the check does not know is accepted rather than rejected. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
6. **The Engine is the only file that names the TLS library**, the same rule that makes it the only file that names zio. A TLS connection is a second entry point for a fiber alongside the plain one, never a branch inside it. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
7. **The handshake is limited by `header_timeout_ms` and `write_timeout_ms`**, the same limits that apply to a client that connects and sends nothing. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
8. **This repository's own http test root is always built with TLS**, whatever flag was passed, so `zig build test` covers the feature instead of relying on someone remembering `-Dtls`. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
9. **The handshake's signature is computed on the Engine's blocking pool, with the connection's fiber parked until it finishes.** The rest of the handshake, which only waits on the socket, stays on the executor. [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
10. **The randomness for RSA-PSS is generated on the fiber before handing off**, because the job may run on a thread with no `Io` to read randomness through. ECDSA and Ed25519 sign deterministically and need none. [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
11. **A `-Dtls` build costs a plain listener nothing per idle connection (4,692 bytes against 4,678), and a TLS connection one extra page (8,843)**: its handshake leaves the connection parked at 3,994 bytes of stack, two pages. The plain listener paid that page too until a change after the run that recorded ADR 212's tables gave it back. The 33 KB of record buffers a live TLS connection needs are returned to the kernel when idle, just like the plain buffers. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
12. **A handshake costs about 300 µs of CPU with an ECDSA P-256 certificate and 2.6 ms with an RSA-2048 one**; a request on an already established connection costs about half a microsecond more either way. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md), [ADR 217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md)
13. **`Ctx.clientIp()` is the client's real address on a TLS listener**, since there is no proxy in front to hide it. For every other deployment, the address-hiding consequence of ADR 027 still applies. [ADR 212](../adr/212-tls-is-an-option-a-build-asks-for.md)
14. **A dependent can supply the TLS library itself with `.tls_own = true`**, writing `nilo.module("nilo_http").addImport("tls", their_module)`; the pin is then not fetched, and forgetting the line fails with a message naming it. [ADR 274](../adr/274-a-dependent-can-bring-its-own-tls-library.md)

## Decisions

| ADR | What it decides |
|---|---|
| [027](../adr/027-tls-is-terminated-in-front.md) | nilo does not act as a TLS server on the internet; a proxy in front is the answer |
| [212](../adr/212-tls-is-an-option-a-build-asks-for.md) | TLS 1.3 as a listener option behind `-Dtls`, the key and certificate check, and what it costs builds with and without it |
| [274](../adr/274-a-dependent-can-bring-its-own-tls-library.md) | `.tls_own = true` leaves the `tls` import to the dependent, who writes one `addImport`; nilo's pin is not fetched, and forgetting the line is a compile error that names it |
| [217](../adr/217-a-handshakes-signature-is-computed-off-the-executor.md) | The handshake's signature runs on the blocking pool, off the executor, so it does not stall every other connection on the same thread |

Related topics: [ADR 220](../adr/220-grpc-is-served-over-h2c-behind-a-flag.md) (topic grpc, no page of its own) is where gRPC runs over h2c or over TLS with ALPN `h2`, behind `-Dhttp2`; [ADR 259](../adr/259-http2-is-a-framing-of-every-request.md) (topic framing) is where a TLS listener came to offer `h2` and `http/1.1` together. The Engine, and the rule that only it may name a dependency, are in [`engine.md`](./engine.md) (ADR 001). The four trade-off axes every cost above is measured against are [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (topic principles, no page). The per-idle-connection minimum that a `-Dtls` build's extra page is added to is in [`memory.md`](./memory.md) (ADR 062).

## Open questions

- **Reloading a TLS listener's certificate without a restart.** Not built. The roadmap describes the design (a second key pair swapped in under the acceptors and freed once the last handshake using the old one ends) and the counting the Engine does not yet do to make it safe.
- **Client certificates on a TLS listener.** The library supports `client_auth`, but nothing in `Options.tls` exposes it yet. The roadmap calls the second half a design question: whether a verified subject should be a typed argument, like `Session(T)`.
- **Session resumption.** The library has no session tickets, so every connection pays for a full handshake. The roadmap has the option's design ready for when it does, and the number to re-measure.
- **A ClientHello split across two records is rejected instead of reassembled**, and there is no HelloRetryRequest for a client that does not offer X25519 first. Both are open issues upstream of the pinned fork.
- **Kernel TLS (`Ktls`)**, which would remove the 33 KB of record buffers and save a syscall on each read and write, is not used: the roadmap notes that the buffers already cost nothing when idle, so the gain has not been measured.
- **The TLS pin is two commits ahead of upstream** (an RSA CRT signing fix, and the `offload` option ADR 217 uses). The roadmap tracks moving back to upstream once both are merged.
