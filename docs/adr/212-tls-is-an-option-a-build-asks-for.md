# TLS is an option a build asks for, and the default build never hears of it

**Status:** accepted
**Topic:** [tls](../design/tls.md)

## Context

[ADR 027](./027-tls-is-terminated-in-front.md) decided that nilo does not speak TLS, on two arguments kept apart on purpose: a trust argument (a one-person Zig TLS library is a second zio-shaped risk at a place where the failure mode is silent) and a memory argument (record buffers would take the idle-connection figure from 8,767 bytes to something like five times that). It closed with the terms on which it would be revisited: the standard library growing a TLS server, or a Zig TLS library acquiring the funding and the audits that rustls has. Its recommendation, a proxy in front for a server on the internet, still stands for that server; what follows is for the server that has nothing in front of it and would otherwise have run a second process just for termination.

Neither term was met. What was found instead was smaller and worth a look anyway: what a server that does not switch TLS on would pay, and what one that does would pay, since those are the two numbers the first decision guessed at.

**The library.** [ianic/tls.zig](https://github.com/ianic/tls.zig) is a TLS 1.3 client and server written on `std.crypto` with no C in it: the record layer, the handshake state machine and the certificate handling are a dozen files a reader can hold in their head, the handshake takes no allocator, `curl`, OpenSSL's `s_client`, Python's `ssl` and `std.crypto.tls.Client` all complete a handshake against it, and a server-side handshake costs about 300 µs of CPU. It has no tags and no audit. It is not unknown to this repository: pg.zig already carries it as the client half of a Postgres connection, so every `-Dsql` build reaching a database over TLS has linked it since ADR 066's table.

**The constraint.** Whatever this decides may not move either of ADR 027's two claims, one allocation per request and a flat, stated cost per idle connection, for a server that did not ask for TLS: a dependency that is a request, fetched and linked only behind a flag, the shape ADR 066 already built for the drivers.

A second finding arrived after this shipped, from a failure mode with nothing to say for itself. `listen()` read the certificate and the key, checked that each file parsed, and never compared them: a certificate handed somebody else's key passes both parses, the server binds, logs that it is listening, and then fails every handshake at the signature the client verifies, `curl` exit 35, nothing above debug in nilo's own log. Not an exotic mistake: `/etc/letsencrypt/live/` holds a directory per name a machine has ever had a certificate for, the two paths are usually written into a unit file or a config by different steps, and a renewal landing in `example.com-0001/` while the config still names `example.com/` is the same mistake arriving on its own. Both halves of the comparison were already in the process by the time the option was honoured: `tls.zig` parses the chain into a `Certificate.Bundle` and the key into a `PrivateKey`, deriving the EC key pair it keeps to sign with on every handshake.

## Decision

**TLS 1.3 is a listener option, in a build that asked for it, and the default build contains none of it.**

- A dependent passes `.tls = true` to `b.dependency("nilo", …)`, `-Dtls` in this repository. The library is reached through `b.lazyDependency` *inside* that `if` (ADR 066), so a build without the flag fetches nothing, links nothing, and has no module named `tls` to resolve. `zig build fetch-check -Dnetwork` holds that for the dependent under `bench/dependent/`, which still lands zio and nothing else.
- With it, `listen(.{ .tls = .{ .cert = "…pem", .key = "…pem" } })` serves HTTPS on the listener. The routes, the handlers, the `Ctx`, the middleware and the OpenAPI document see nothing different; a request is a request.
- **Without it, the same option is refused at `listen()` in one line**, the way a port that is taken is: what is missing, and what to pass. It is never served as plain HTTP on a port the caller believed was encrypted. The same line refuses `.tls` on a unix socket, whose file permissions are its access control, and a certificate that cannot be read, before the port is taken.
- **The Engine is the only file that names the library**, under the same rule that makes it the only file that names zio (ADR 001). A TLS connection is a second fiber entry, `Conn.runTls`, beside the plain one and never a branch inside it, for the reason measured below.
- **The handshake is bounded by `header_timeout_ms` and `write_timeout_ms`**, because until it is done a connection is exactly what those two limits exist for: a client that has connected and not yet said anything nilo can act on. A client that connects and goes quiet held its fiber and 33 KB for ever without this.
- **The repository's own http test root always has TLS in it**, `-Dtls` or not, so the feature is held by `zig build test` and not by whoever remembers a flag (ADR 032). The tests drive it with `std.crypto.tls.Client`, checking the certificate as a browser would, since a test of the library talking to itself would only show its halves agree, which is not the question.

### A key is checked against its certificate at `listen()`

**`listen()` compares the leaf certificate's public key against the one the private key carries, and refuses the pair in one line when they differ.** The check is nilo's, before the port is taken, naming both files, with the two `openssl` commands that print the two public keys so the reader can see the difference rather than take the server's word for it. It returns `error.TlsCertificate`, the same error an unreadable certificate already returns.

What is compared is the public key, per scheme: for EC, the uncompressed SEC1 point, byte for byte what the certificate carries; for RSA, the modulus and not the exponent, which is 65,537 on very nearly every key ever issued and would pass two keys sharing nothing; for Ed25519, the 32 bytes. The leaf is the first certificate in the chain, the order a PEM chain is written in and the order every issuer hands one out. **A pair nilo cannot compare is not refused**: a signature scheme with no prong in the comparison is a key the library parsed and nilo has no opinion about, and the pair is accepted, because a server that will not start is a worse failure than the one this fixes, and a fourth scheme arriving upstream should be answered "acceptable" until somebody has a key of that kind. The comparison is a function of its own and is what is tested (`keyIsTheCertificates`, against a second key on the same curve so what is caught is the key rather than the curve or the file format), because a mismatch is a runtime condition and cannot be a compile-error Refusal, and it cannot be a test that drives `listen()` either: Zig's test runner counts every `std.log.err` a test provokes and fails the step on the count before any log-level filter runs, so a test of a refusal that speaks is a red step by construction.

## What it costs, on ADR 017's four axes

Measured on the code as shipped, `ReleaseFast`, stripped, `x86_64-linux-gnu`. The run record with the commands is in [`bench/result/http.md`](../../bench/result/http.md).

**Binary size.** The default build pays 2,760 bytes: an `Options` field, the comptime `if`s around it, and the two refusal messages, one of which exists precisely for that build. The build that asks pays 560 KB before it has loaded a certificate, `std.crypto`'s X.509, the AEADs and the key exchange pulled in by reference.

| build | `nilo-hello` | against `main` |
|---|---|---|
| `main` | 990,696 | |
| this change, no `-Dtls` | 993,456 | +2,760 B |
| this change, `-Dtls`, `.tls` never set | 1,568,208 | +577,512 B |

The key-check above changed nothing here: measured against the commit before it landed, the no-`-Dtls` binary is byte-identical (968,144 both before and after, at a later snapshot), which is what every line of the check sitting inside the same comptime `if (nilo_build.tls)` the Engine already had buys. The `-Dtls` binary got 9,376 bytes *smaller*, and that is the inliner's doing rather than the check's: the largest matched move is in the handshake's own server flight function, which this change does not touch, and it was not chased further because the number worth holding is the one above it.

**Memory per idle connection**, at 10,000 connections, marginal equal to average (`bench/mem.py`, ADR 062's method):

| listener | build | bytes | against plain |
|---|---|---|---|
| plain | no `-Dtls` | 5,191 | |
| plain | `-Dtls` | 9,293 | +4,102 (one page) |
| TLS | `-Dtls` | 9,307 | +4,116 (the same page, and 14 bytes) |

**A TLS connection's record buffers (16.6 KB in, two records out, 49 KB in all) are not in that figure.** ADR 027's "five times" assumed they would be held; they are page-aligned, like the cleartext pair, and handed back at every idle transition through the same `MADV_DONTNEED` (ADR 062), with one extra check that no decrypted bytes are still waiting in them. What is left is a page of fiber stack, because the handshake's frames were touched below the park and a suspended fiber holds its high-water mark (ADR 062); `@call(.never_inline, tls.server, …)` keeps them below rather than in the frame that lives as long as the connection.

**The record buffer out holds two records, and what a drain writes is sealed before it is sent.** The library seals a record and writes it to the socket at once, so a body written through a buffer that held one was a record and a write for each 16 KB, an HTTP/2 frame's nine-byte head was a record and a write of its own, and a file read through the connection's 4 KiB write buffer was a read, a record and a write for each 4 KiB. The Engine's cleartext writer on a TLS connection (`Sealer`, in `http/engine/zio.zig`) holds the library's flush for the length of one drain and makes the write itself when the drain is over, and it keeps the last byte of a drain that carried data in the cleartext buffer, so that a caller that flushes only a writer with something in it still finds something and the write is never left behind. For a file the same writer reads 64 KiB at a time into a buffer that lives for the file alone (a connection holds none of it idle). Idle memory is unchanged to the byte (`bench/result/http.md`, "What a TLS write is sealed in"): the record buffer is page-aligned and handed back with the rest at every idle transition, so the second record's pages are touched only by an answer larger than one record, and stay resident until the connection's next idle release, as the first's do. A spilled 64 MiB file over HTTP/1.1 went from 0.59 to 2.4 GB/s and a held 1 MiB file over HTTP/2 from 1.7 to 3.2, and the bar the ADR was reopened for, that a file over TLS is as quick on one protocol as on the other, is met.

**A plain listener in a `-Dtls` build costs the same page**, which is the cost the constraint said may not be paid, paid only by the build that asked and by nobody else. The first form of the change put a branch in `Conn.run` and cost that page on a plain listener too; two separate entries took it back. What remains is the inliner: a second caller of the handler changes what LLVM folds into the plain path, and **the plain park sits under 300 bytes short of a page boundary**, so anything at all crosses it. It is not paid by a build without the flag, the line that was drawn.

**Allocations per request: unchanged.** The record buffers are two allocations per *connection*, at accept, beside the two the plain path makes; the handshake takes no allocator; nothing on the request path changed. `test "the request path stays inside its allocation budget"` holds it. The key-check likewise adds nothing: it runs once, at `listen()`, on a pair already in memory, and keeps nothing after.

**CPU, and therefore throughput.** Server CPU per operation, loopback, client on other cores, three runs quoted as the band:

| | plain | TLS | ratio |
|---|---|---|---|
| per request, kept alive, `-Dcpu=native` | 3.0–3.5 µs | 3.5–4.0 µs | ~1.15 |
| per new connection, `-Dcpu=native` | 10–15 µs | 280–295 µs | ~20–29 |
| per request, kept alive, baseline x86_64 | 3.0–3.5 µs | 22–23 µs | ~6.5 |
| per new connection, baseline x86_64 | 15 µs | 325 µs | ~22 |

The request is cheap and the handshake is not, which is the shape TLS has everywhere; what a deployment pays depends entirely on how often its clients connect. A service whose clients hold a connection pays about 15%; one whose clients connect per request pays twenty times an accept, and wants session resumption, which the library does not have and a proxy does. **Build for the ISA you run on**: a `-Dtarget=x86_64-linux-gnu` binary with no `-Dcpu` runs six times slower per request than the same machine with AES-NI used, and a server built without `+aes+pclmul` cannot hold 50,000 req/s of a 10 KB echo on eight cores while one built with it does the same at 9% of four. Signing is a separate cost from this table: [ADR 217](./217-a-handshakes-signature-is-computed-off-the-executor.md) moves the handshake's signature off the executor thread, which this ADR's numbers above already assume as fixed rather than as work still ahead.

## What was rejected

**Always on.** The 560 KB and the page would be paid by every build, failing the constraint; a library that has not been audited would be on the path of every request whether or not the deployment wanted it.

**Linking OpenSSL or BoringSSL.** ADR 027's reasons stand: it ends `zig fetch` as the installation story and brings a C toolchain with it.

**A run-time switch with the library always linked.** Half the cost of always-on for none of the benefit: the binary carries the code and the choice moves to a config file, where the flag is at build time because that is where the cost is decided.

**Record buffers per request rather than per connection.** Puts two allocations on the request path, failing the invariant; the record layer has to be whole across requests, since a record does not end where a request does.

**Kernel TLS.** The library's `Ktls` mode moves the record layer to the kernel after the handshake, on Linux, and the 33 KB of buffers would go away. Not taken now, because the buffers already cost nothing at idle, and what kTLS would buy, the page and the per-request microsecond, is worth a measurement before a platform-specific path.

**A copy of the library in the tree.** A fork is a fork to maintain. The pin is a commit on a branch, because the library has no tags.

**A TLS-only Engine, or a branch in the plain one.** The branch was measured and cost the page on the plain listener; a second Engine would duplicate the accept loop for the sake of one spawn line.

**Leaving the key/certificate check to the library.** `tls.zig` could check inside its own certificate-loading path, arguably where it belongs. Against it: a change there is somebody else's release to make and nilo's to wait for, and the check is a few dozen lines here; if the library ever does it, this becomes a check that always passes, costing a startup parse and no reader's attention.

**Refusing a key/certificate pair nilo cannot compare.** The strict reading is that an unknown scheme means the check did not run, so the pair should be refused. Rejected for which way each failure points: the failure this fixes is loud on the client and silent on the server, and is always a mistake; the failure the strict reading introduces is a server that was serving yesterday and will not start today because the library learned a key type nilo's switch has not heard of, loud on the server and never the operator's mistake.

**Signing a probe and verifying it**, the general check that covers every scheme without a comparison per scheme. Needs an RNG at startup and a verifier per scheme, so it is the same switch with more in it, and spends a signature and a verification on every start; the comparison is what the mistake actually is.

**A test that stands the listener up with a mismatched pair.** Written, run, and taken back out, for the same log-count reason the `.tls` refusal beside it is tested with its message left out: a test of a refusal that speaks is a red step by construction.

**Checking the rest of the certificate chain.** Whether the leaf's issuer is the next certificate in the file is a different mistake, with a different message the client already prints; this decision is about the key.

## The page that is not TLS's

The finding that took longest, recorded because it will be met again by anybody who adds a second caller to `handler`. Instrumented at the park, the live stack of a plain connection on the plain build is 2,618 bytes, one page. On the `-Dtls` build the same plain connection parks at 2,890 to 3,018 bytes, two pages; a TLS connection at 3,994, two pages. The 272-byte difference on the plain path is not a TLS frame: it is the plain path's own frames grown by what the inliner decided once the handler had a second caller with a different argument shape. A separate entry, `always_inline` on the handler, and keeping both entries' argument lists identical were each tried; the third is what shipped, and it left the difference at 272. **The plain park sits under 300 bytes short of a page boundary**, which means any change to the plain path is one page per idle connection away from being noticed, and the number to know is that headroom rather than this change.

## What the library does not do yet, and what that costs a deployment

- **A ClientHello split across records is refused** ([tls.zig#36](https://github.com/ianic/tls.zig/issues/36)). Every client tried sends it whole; one that does not gets a failed handshake rather than a slow one.
- **No HelloRetryRequest.** A client offering a key share for a group the server does not take is refused rather than asked again. Every client tried offers X25519 first, which the server takes.
- **No session tickets, so no resumption.** Every connection is a full handshake, and the 300 µs (or, with signing offloaded, the wait for it) is paid every time. This is the row that decides whether a deployment's clients should be behind a proxy.
- **One certificate per listener, no selection by name.** A listener serving two names needs two listeners or one certificate with both names on it.
- **No client certificates wired through**, although the library has them; mTLS is a use case waiting for a caller.
- **A record's length is read before its content type is checked**, so plain HTTP sent to a TLS port is held as a record that never finishes rather than refused on sight. The header deadline is what ends it, which is why the deadline is not optional.
- **A certificate is read at `listen()` and never again.** Rotation is a restart, which for the server this is for is the deployment it already has.

## Consequences

- **The trust argument is unchanged, and it is written where the option is.** The `Options.tls` doc comment, the deploying guide and the README say the same thing: a proxy in front is still the recommendation for a server on the internet ([ADR 027](./027-tls-is-terminated-in-front.md)), and this is for the server that has nothing in front of it and would otherwise have run one. A deployment choosing it is choosing an unaudited TLS stack over an audited one, on purpose, with the number beside it.
- **`Ctx.clientIp()` is the real address on a TLS listener**, since there is no proxy to hide it. The other half of ADR 027's first consequence goes away for this deployment and stays for every other.
- **HTTP/2 follows only in a build that asks for it.** The handshake offers `http/1.1` as its only ALPN protocol, and it still does in a build without `-Dhttp2`. With the flag it offers `h2` first and `http/1.1` after it, and serves what was chosen ([ADR 259](./259-http2-is-a-framing-of-every-request.md), [ADR 027](./027-tls-is-terminated-in-front.md)); that costs an HTTP/1.1 connection over TLS 6 bytes at 10,000 connections and no page, against the page this ADR measured.
- **A `-Dtls` Postgres build carries the library twice**, once as pg.zig's client at its own pin and once as nilo's server at this one. Two copies of the same code at two commits is a cost the binary pays and a fact the next person bumping either pin should know.
- **The Engine's contract grew by one type**: `Wake.RawLayer`, so the Bulkhead can hand a record layer's pages back without knowing what one is. The Bulkhead's `release_stack` gained a branch that a plain connection takes as one null check.
- **This ADR is where ADR 027's reversibility clause was read under load**, and the reading is narrow: the argument about trust did not change, the argument about memory turned out to be a design choice rather than a property of TLS, and the answer is an option rather than a reversal. If the library is ever audited, or the standard library grows a server, the option's default is the thing to revisit, not ADR 027 itself.
- **The deploying guide loses its workaround.** "`curl -k https://…` once after a deploy is the check" was the honest advice while a mismatched key and certificate were not caught; it is now the server's job, and a deployment whose two files genuinely do not match now fails to start where it used to start and serve nothing, the same trade the missing-file refusal already makes.
- **The three schemes in the key-check switch are the three the library signs with.** A fourth arriving upstream is a pair this answers "acceptable" to, the safe direction, and a prong to add when somebody has a key of that kind.
