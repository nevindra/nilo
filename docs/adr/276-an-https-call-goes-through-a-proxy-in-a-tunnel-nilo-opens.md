# An https call goes through a proxy in a tunnel nilo opens

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** [ADR 267](./267-a-call-can-go-through-a-proxy-and-trust-a-private-authority.md), the proxy, and [ADR 272](./272-a-call-names-the-socket-it-goes-over.md), the precedent for a `Connection` nilo builds itself. **Applies:** [ADR 017](./017-the-trade-budget-has-four-axes.md), [ADR 062](./062-where-a-connection-waits-is-what-it-costs.md).

## Context

ADR 267 shipped `Settings.proxy` for `http://` calls and refused an `https://` one with `error.TlsThroughProxy`, on a reading of `std.http.Client.connect` and `connectProxied` at 0.17.0 and with no TLS server in the suite to run it against. A network whose only way out is a proxy is mostly a network of HTTPS, so the refusal left the setting useful for the least of its traffic.

**The reading was right, and now it has been run.** `fetch/tunnel.zig` starts nilo's own TLS listener, a `CONNECT` proxy, and std's client with `https_proxy` set and `supports_connect` true. The proxy answers the `CONNECT` with a 200, and the first byte the client then sends into the tunnel is `G`, the start of `GET`, where a ClientHello (0x16) belongs. The tunnel's `Connection` is created with the proxy's protocol (`.plain`) and not the target's, and `Connection.Tls.create`, the one piece that would wrap it, is private. The test stays as a canary: the day it fails, std has fixed it and the code below can go.

## Decision

**`nilo_fetch` opens the tunnel itself and runs `std.crypto.tls.Client` inside it, in the default build.** `Exchange.dialTunnel` connects to the proxy, sends `CONNECT host:port` (with `Proxy-Authorization` when the proxy URL carried a credential), reads the proxy's head, and on a 2xx starts the TLS handshake over the same two streams. The result is added to std's pool as a TLS connection to the target, keyed host, port and `.tls` as a direct one is, so a second call to the host rides it, the stale-connection retry ([ADR 058](./058-most-of-an-s3-client-is-not-s3.md)) covers it, and a `.stream` body gets its fresh connection as before.

**The certificate is checked against the target's name, never the proxy's.** The name in the URL is the one the caller asked for and the one the tunnel leads to; the proxy sees it in the `CONNECT` line and nothing of what follows. A test asks a server whose certificate carries the proxy's address and not the call's name, and the call is refused (`error.TlsInitializationFailed`); making the code verify the proxy's name instead turns that test red, which was run. The roots are `Settings.roots` or the system's, as for a direct call.

**The proxy's credential goes in the `CONNECT` and nowhere else.** The request inside the tunnel is origin-form with no `Proxy-Authorization`; a followed redirect to another host opens another tunnel with the credential in its `CONNECT`, and to a bypassed host goes direct with none.

**Two new answers, both before a byte of the call is sent.** A proxy that answers the `CONNECT` with anything but a 2xx (a 403 from a policy, a 407 for a missing or wrong credential, a 502), or with something that is not an HTTP head, is `error.TunnelRefused`. `error.TlsThroughProxy` stays for one case, a proxy that is itself an `https://` URL: a handshake inside a handshake is not built, and a caller reaches the proxy over `http://` or names the host in `bypass`.

**The node is std's `Connection.Tls` laid out by hand**, as `dialUnix` lays out `Plain` ([ADR 272](./272-a-call-names-the-socket-it-goes-over.md)): the same two fields (`client`, then `connection`) and the same single allocation, because std's `reader`, `writer`, `end`, `getReadError` and `destroy` reach the TLS client by `@fieldParentPtr` on it and `destroy` frees by `Tls.allocLen`. It is a copy of a private layout, so it is pinned the same way: a `@compileError` unless the Zig is 0.17, and every tunnel test runs under the testing allocator, which reports a free whose size is not the allocation's. When std grows a public way to build one, `dialTunnel` goes and `pickConnection` calls it.

## What it costs

- **Allocations per request:** none added to a call that opens no tunnel. A tunnel's first dial allocates its node, as a direct TLS dial does.
- **Memory per idle connection:** a pooled tunnel is the node a direct TLS connection is, the same size. `pickConnection` is no longer inlined into `Exchange.attempt`, whose frame is on the stack for as long as a call waits: measured on a stripped `ReleaseFast` program that dials out, `attempt` takes 0x568 bytes of stack against 0x718 before, **432 bytes less**, and the dial (`dialTunnel`, 0x468 bytes, and the `CONNECT` reader) is in frames that are gone before the call parks. `bench/mem.py` against an `outbound` server was not run; the park depth was read from the frame sizes of the compiled program and not from a parked connection.
- **Throughput and p99:** nothing for a call that opens no tunnel. A tunnel costs a `CONNECT` round trip and a handshake once per connection.
- **Binary size:** **+4,704 bytes** on a stripped `ReleaseFast` program that dials out through `nilo_fetch` with default settings (941,488 to 946,192, measured by building the same program against `fetch/` and `core/` from `git archive 0f6a939` and from the working tree, [`bench/result/fetch.md`](../../bench/result/fetch.md)). It is unconditional, because the branch is a runtime one. A program that does not import `nilo_fetch` pays nothing.

## What was rejected

- **Waiting for std.** The fix is small in std (build the tunnel's connection with the target's protocol), and an upstream report is still worth making, but a proxy setting that refuses most of the traffic it was written for was the cost of waiting, and the test above is what tells nilo the day it can stop.
- **Silently going direct, or sending the request in the clear.** Both were rejected in ADR 267 and still are: the first defeats the policy a proxy is there to enforce, the second sends what the caller meant to be encrypted as text.
- **TLS to the proxy as well as to the target.** An `https://` proxy would need a handshake over a handshake, which `std.crypto.tls.Client` can run (its reader and writer are `Io` interfaces) but whose buffers and `Connection` layout are a second private copy of std's. No caller asked for it and a proxy on an internal network is almost always reached in the clear; it stays `error.TlsThroughProxy`.
- **A tunnel per `Target`, or a `Settings` switch for the old refusal.** The proxy is a property of the network (ADR 267), and a switch that restores a refusal is a setting nobody has a reason to set.

## Client certificates were looked at and are not part of this

The todo entry that asked for mutual TLS (`nilo_fetch` presenting a client certificate) was read against this change, because both want to own the TLS connection std holds. **They are not one decision.** The finding, read from the code:

- **`std.crypto.tls.Client` at 0.17.0 cannot answer a `CertificateRequest`.** Its handshake loop has an arm for `server_hello`, `encrypted_extensions`, `certificate`, `server_key_exchange`, `server_hello_done`, `certificate_verify` and `finished`, and `else => return error.TlsUnexpectedMessage`; the string `certificate_request` does not occur in `std/crypto/tls/Client.zig`, and the client's own flight is a `Finished` with no `Certificate` before it. A server that requires a certificate sends one between `EncryptedExtensions` and `Certificate` in TLS 1.3, and the handshake ends there.
- **tls.zig, behind `-Dtls`, can** (`config.Client.auth`), **but std's `Connection` cannot hold it.** A `.tls` connection is read and written through `&tls.client.reader` and `&tls.client.writer`, found by `@fieldParentPtr` on a `std.crypto.tls.Client`, and a `.plain` one through its socket's stream reader and writer; neither has a place for a second TLS implementation's state. Giving it one means either a node std frees by a length it computes (the state would have to live inside std's buffers, which is a layout this module would then own twice), or a pump between a socket and a TLS connection (a task and a socketpair for every connection, against the hard axes), or an HTTP/1.1 client of nilo's own on tls.zig, which is the fork the todo names and a module of its own.

None of those fits ADR 017 today, and the first is a worse shape than the problem. The entry stays on `docs/todo.md`, rewritten with this evidence: the cheapest honest fix is client authentication in `std.crypto.tls.Client`, which would serve the default build with no flag, and the alternative is a client of nilo's own behind `-Dtls`.
