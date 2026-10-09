# A call names the socket it goes over

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** [ADR 061](./061-a-fitting-borrows-the-loop.md), the Client, its Call and the Target. **Applies:** [ADR 103](./103-a-path-is-an-address-to-listen-on.md), the other end of the socket.

## Context

A nilo server can listen on `unix:/run/orders.sock` (ADR 103), and `nilo_fetch` could not call it: a second service on the same host, the Docker Engine API on `/var/run/docker.sock`, and a local agent were all out of reach without writing a client by hand. The cases that decide the shape:

- **Docker, one socket and many paths.** `GET /containers/json`, `POST /containers/{id}/stop`. The URL's host is a placeholder; the `Host` header still has to be something, and the server may route on it.
- **One program, one socket and the network.** A service that calls Docker and Stripe has both in one process, one `Client`, one `max_in_flight`.
- **A proxy is configured for the network** (ADR 267), and a socket is a file on this host.
- **Pooling.** Two sockets must never share a connection, and a socket must not collide with a TCP host.
- **Deadlines, the stale-connection replay and a `Target`'s retry (ADR 271)** apply to a socket call exactly as to any other.
- **Redirects.** A `Location` is the server's word and names a URL.

std's `Client.connectUnix` is the obvious tool and is not usable at 0.17.0: it names `std.posix.SocketError`, which no longer exists, so a program that references it fails to compile. The type that builds a pooled connection, `Connection.Plain`, is private.

## Decision

**The socket is a field of the call, `Call.unix_socket: ?[]const u8`, and of a `Target`'s `Open`, `unix_socket`.** The URL stays the request: its host is the `Host` header and its path and query are the request line, so `http://docker/containers/json` over `/var/run/docker.sock` is one socket and any number of paths. A `Target` takes the path once, at `open`, with `base = "http://docker/v1.43"`; a call's own `unix_socket` goes instead of the target's. It is the deployment's half, a runtime string from configuration, so it sits in `Open` and not in the type's comptime options.

**Refusals, all before anything is dialled.** An `https://` URL is `error.TlsOverSocket`: std starts TLS only on a TCP connection, and a socket's protection is the permission on its path. A path that is empty, relative, holds a NUL or is longer than a socket address holds (107 bytes) is `error.InvalidSocket`; a scheme other than `http` is `error.UnsupportedUriScheme`. `Target.open` returns the same three, so a bad deployment stops the program at start. None of these is a comptime refusal, because the path is not known at compile time; the value is checked at the first place it is seen.

**`Settings.proxy` does not apply to a socket call, and is not refused beside one.** The proxy is a way out onto the network and a socket never leaves the host, so the call goes to the socket in origin form and nothing is sent to the proxy. Refusing the combination (Bun) or turning proxies off client-wide (reqwest) would force a second `Client` for the program that proxies Stripe and talks to Docker, with its own `max_in_flight` and pool; and unlike ADR 267's `https://` case, nothing here defeats the policy a proxy is there for.

**Connections are pooled by the path.** The key is the path as `host`, port 0 and plain, which std's `connectUnix` uses and no TCP connection can have, since a host name never begins with `/`. Two sockets never share a connection, and the stale-connection replay of ADR 058 and the retry of ADR 271 see a socket connection as any other.

**A followed redirect that leaves the origin is `error.RedirectLeavesSocket`.** Inside the origin it stays on the socket. Another origin would otherwise be dialled over TCP on the strength of a `Location` header, which turns a local-socket call into a request to wherever the server points: refused, and the caller who means it says the TCP URL.

**The dial is nilo's, because std's does not compile.** `Exchange.dialUnix` connects with `std.Io.net.UnixAddress` and lays the `Connection` out exactly as `Connection.Plain.create` does (the node, the host bytes, the read buffer and the write buffer in one allocation), because `Connection.destroy` frees by that length. That is a copy of a private layout, so it is pinned: a `@compileError` unless the Zig is 0.17, and a test that dials, pools and closes one under the testing allocator, which reports a size that does not match. When std's `connectUnix` compiles, `dialUnix` goes and `pickConnection` calls it.

## What it costs

- **Allocations per request:** none added to a call that sets no socket. A socket call's first dial allocates the connection node, as a TCP dial does.
- **Memory per idle connection:** `Exchange` is 992 bytes before and after. `Call` grows from 48 to 64 bytes and `Begin` from 208 to 224, both on the stack of a call for its duration and neither held while a connection waits. A pooled socket connection holds what a TCP one does less the host name, and a plain one.
- **Throughput and p99:** a socket call skips the proxy and the host resolution; no number was taken, and none moves for a call that sets no socket (one more `null` test in `pickConnection`).
- **Binary size:** **+736 bytes** on a stripped `ReleaseFast` program that dials out with default settings (953,008 to 953,744), measured by building the same program against the module at the parent commit and at this one. The dial cannot be dropped by the linker because the branch is a runtime one.

## What was rejected

- **A `Settings` field, `unix_socket`, one socket a client** (reqwest's `unix_socket()`, undici's `socketPath` on a `Client`). It is the smaller change and it fits a program whose only peer is Docker. It is wrong for the program that also calls the network: that program needs a second `Client`, and with it a second pool, a second `fresh` std client, and a `max_in_flight` that no longer bounds the program's outbound calls as a whole. It also makes the proxy a client-wide conflict that has to be refused at `nilo_start`. A `Target` already is "one destination, held once", so the single-socket program loses nothing: it opens a Target and never writes the path again.
- **A scheme that carries the path** (`http+unix://%2Fvar%2Frun%2Fdocker.sock/containers/json`, Python's `requests-unixsocket`). The path in the host position is percent-encoded text a URL parser has to be taught, `std.Uri` is not, and the host the server sees is a string nobody chose. The URL stays an ordinary `http://` one.
- **Go's `Transport.DialContext` override.** It pools by the URL's host, so two sockets behind one placeholder host share connections; keying by the path is what std does and what this does.
- **Refusing a socket beside `Settings.proxy`** (Bun), and turning the proxy off for the client that has a socket (reqwest). Above.
- **Dialling over TCP on a redirect that leaves the origin.** Above.
- **Waiting for std's `connectUnix` to compile.** It does not at 0.17.0 and the fix is outside this repository. The layout copy is small, pinned and tested, and an upstream fix to `connectUnix` is what removes it.
