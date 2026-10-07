# HTTP/2 is a framing of every request, on the port HTTP/1.1 is on

**Status:** accepted
**Topic:** [framing](../design/framing.md)
**Extends:** [ADR 220](./220-grpc-is-served-over-h2c-behind-a-flag.md) (the HTTP/2 connection serves every request, and gRPC becomes an envelope over it), [ADR 027](./027-tls-is-terminated-in-front.md) (HTTP/2 for browsers, revised in place when stage 7 lands), [ADR 253](./253-an-answer-is-handed-to-the-framing-that-carried-its-request.md) (the `.http2` arm answers any request)
**Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md) (the four axes), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md) (where a connection parks is what it costs), [ADR 212](./212-tls-is-an-option-a-build-asks-for.md) (a TLS entry of its own, and the page it measured)

## Context

HTTP/2 arrived in nilo for gRPC and only as far as gRPC needed it: a listener of its own (`.grpc = true`), a connection that refuses anything but `POST` with `application/grpc`, a flag named for the envelope (`-Dgrpc`), and a 505 for an HTTP/1.1 client that found the port. Stages 1 to 4 of the framing direction made a request one thing whichever framing carried it, so the HTTP/2 connection is now a framing with one envelope on it rather than a gRPC server with a framing inside. What is left is to let it carry every request: on the port HTTP/1.1 is on, told apart by the client's first bytes, and by ALPN on TLS, where browsers are.

The real clients set the shape. **A browser speaks HTTP/2 only over TLS, chosen by ALPN**, and falls back to HTTP/1.1 for a WebSocket when the server does not offer extended CONNECT. **curl, Envoy, nginx's `grpc_pass`, Caddy's `h2c` upstream, Go's `h2c` package and every gRPC client** speak HTTP/2 over plain TCP with prior knowledge (RFC 9113 §3.3), which starts with a 24-byte preface no HTTP/1.1 request can begin with. The `Upgrade: h2c` dance of RFC 7540 §3.2 is gone from RFC 9113, and the server may ignore it.

## Decision

**One build flag, `.http2 = true` (`-Dhttp2`), brings HTTP/2, and gRPC rides it.** `.grpc = true` and `-Dgrpc` are refused by the build with one line naming the new flag. A build without the flag is the build it was, to the byte.

**In a build with it, every listener answers both.** A plain TCP or unix listener reads the client's first bytes: the preface is HTTP/2 with prior knowledge, anything else is HTTP/1.1, decided as soon as a byte differs from the preface, so a short HTTP/1.0 request is never waited on. A TLS listener offers `h2` and `http/1.1` by ALPN and serves what was chosen (stage 7). There is no per-listener switch: the listener option `.grpc` goes, and a port for gRPC alone is an `also` listener like any other, its routes bound to it with `onListener` (ADR 252) where that matters. `Upgrade: h2c` is ignored and the request served as HTTP/1.1, which RFC 9110 allows.

**The choice costs an HTTP/1.1 connection nothing it can measure.** The two connection loops have one signature, so the read that chooses ends in a tail call to the one chosen, and an HTTP/1.1 connection parks in the frame it parked in before. Where the ABI will not take the tail call, the choice moves into `serve.handleConnection`'s first wait, which already peeks the first bytes, and hands an HTTP/2 connection on through one `noinline` call; which of the two ships is decided by `bench/mem.py` reading the HTTP/1.1 idle figure of a `-Dhttp2` build unchanged.

**Every request, not only a call.** A request on HTTP/2 is any method but `CONNECT`, held to RFC 9113 §8 before it reaches the App: `:method`, `:scheme` and `:path` present, every field to the rules an HTTP/1.1 head's are held to by the same loop (ADR 253), connection-specific fields and a `te` other than `trailers` malformed (§8.2.2), a `content-length` that the `DATA` does not add up to malformed (§8.1.1), and the `cookie` fields a browser splits for compression joined with `; ` into one (§8.2.3). It runs through the router, middleware and handler an HTTP/1.1 request does, on a fiber of its own as a call does. **gRPC is an envelope over it**: a request whose content type is `application/grpc` or `application/grpc+…` has its message unframed and its answer framed and trailed as ADR 220 says, and only it is answered with a `grpc-status`; every other request is answered as HTTP: `:status`, `content-type`, `content-length` for a whole answer, `date`, the route's headers lowercased with the connection-specific ones dropped, the body in `DATA` frames under both windows, and trailers when the route set any. A `HEAD` gets the head a `GET` would and no `DATA`.

**The connection is `http/h2conn.zig`, and the envelope stays `http/grpc.zig`.** One file was a gRPC server; two are a framing and an envelope, which is what the direction says they are.

**`Ctx.connection()` leaves the public surface.** It returned an HTTP/1.1 `Connection` line, which means nothing on HTTP/2; `keepAlive()` says the same thing in words that do.

**What a request on HTTP/2 cannot do until stage 6** is said by name where it is asked for, never answered wrong: a streamed answer, a file, `bodyStream`, an event stream handed to the connection and a WebSocket. No browser reaches HTTP/2 before stage 7, and stage 7 waits for stage 6; a WebSocket stays HTTP/1.1 after it too, below.

## What it costs

The budget each part is held to, replaced by what was measured when the stage lands ([`bench/result/http.md`](../../bench/result/http.md)):

- **A build without `-Dhttp2`**: byte-identical binaries, idle figures and throughput.
- **An HTTP/1.1 connection in a `-Dhttp2` build**: the idle figure of a build without the choice, read by `bench/mem.py`; a routed `GET` inside the spread of the build before.
- **A request on HTTP/2**: no more allocations than the same request on HTTP/1.1 from the second request on a connection, held by a test beside the HTTP/1.1 budget test; its time in process on record beside HTTP/1.1's, with what a fiber spawn costs of it.
- **An idle HTTP/2 connection**: its figure on record, plain and TLS, at 1,000, 5,000 and 10,000 connections, before stage 7 offers `h2` to a browser. One browser opens one HTTP/2 connection where it opened six HTTP/1.1 ones, which the guide says beside the figure.
- **Binary size**: the `-Dhttp2` build against the `-Dgrpc` build it replaces, in ADR 017's running total.

## What was rejected

**HTTP/2 in the default build.** Ninety kilobytes of a stripped binary, and a TLS listener is the only place a browser would use it, which already needs `-Dtls`.

**A listener option per protocol** (`.http2 = true` on a listener, or `.protocols = .{…}`). The first bytes and ALPN already say what the client speaks, and every knob is one a deployment can set wrong; a build that did not want HTTP/2 does not pass the flag.

**`Upgrade: h2c`.** Removed by RFC 9113, sent by almost nothing that matters, and a second way to start the same connection.

**Keeping `-Dgrpc` as an alias.** Two names for one switch is a question every reader asks; the build refuses the old one in a sentence instead, which a change of one word answers.

**Answering a request the HTTP/2 framing cannot serve yet as `501`.** It would read as the route's answer. A failure that names what was asked for and on which framing is what a developer can act on, and no client outside a test reaches it before stage 6 lands.
