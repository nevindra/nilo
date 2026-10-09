# A call can go through a proxy and trust a private authority

**Status:** accepted
**Topic:** [fetch](../design/fetch.md)
**Extends:** [ADR 061](./061-a-fitting-borrows-the-loop.md), the Client and its Settings.

## Context

A service in a network whose only way out is a forward proxy, or one calling an internal service whose certificate a company authority signed, could not be written with `nilo_fetch` without reaching into `client.inner` and `client.fresh` by hand. `std.http.Client` has the fields (`http_proxy`, `https_proxy`, `ca_bundle`), `Client.Settings` named none of them, and std has two gaps of its own that a caller reaching in would meet one at a time: it reads no `NO_PROXY`, and its proxy path for `https://` does not work (below).

The two std clients `nilo_fetch` holds (`inner`, with the pool, and `fresh`, for a `.stream` body) both have to be set, or a streamed upload leaves the proxy and trusts the system's authorities only.

## Decision

**`Settings.proxy: ?Proxy` and `Settings.roots: ?*const std.crypto.Certificate.Bundle`, both null by default, both applied to both std clients at `nilo_start`.**

**The proxy is `.{ .url = "http://user:password@host:3128", .bypass = &.{ "corp.example", "127.0.0.1" } }`.** The URL is given by the caller, never read from the environment: a process that finds `HTTP_PROXY` set by something it did not write and sends its calls through it has a surprise to explain, and the deployment's own configuration (`nilo_config`) is where a proxy is named. A bad URL (a scheme other than `http` and `https`, no host, a credential past std's 255 bytes) is `error.InvalidProxy` from `nilo_start`, so the program stops before it serves, as every other bad setting does ([ADR 039](./039-a-setting-is-a-field-and-every-bad-one-is-named-at-once.md)). The user and password become `Proxy-Authorization: Basic` and go to the proxy and nowhere else.

**The bypass list is a list of names, because std reads no `NO_PROXY`.** An entry matches the host it names and every host under it, ignoring case; a leading `.` or `*.` is the same as none; `*` is every host. There is no CIDR range and no port in a match. **Nothing is skipped that is not listed, `localhost` and loopback included**, where Go skips them without being asked: an explicit setting that quietly does something else for some addresses is the surprise this decision exists to avoid, and a service that calls a sidecar on loopback lists it once.

**Only `http://` calls go through the proxy; an `https://` call it would carry is `error.TlsThroughProxy`, before anything is dialled.** This is the half that does not work, found by reading `std.http.Client.connect` and `connectProxied` at 0.17.0: the tunnel std builds for an `https://` target (`CONNECT`, then the request) creates the connection with the proxy's protocol, not the target's, so TLS never starts inside the tunnel and the request goes out in the clear to a server expecting a handshake. That is a reading of the code and not a run: there is no TLS server in this repository's fetch tests to run it against, and what is tested is that the call is refused. The one piece that would fix it, `Connection.Tls.create`, is private. Without a fix inside std the choices were to let a request meant to be encrypted travel as text (refused outright), to route it around the proxy silently (which defeats the policy the proxy is there to enforce), or to say so. `nilo_fetch` says so, and a caller who wants the host reached directly names it in `bypass`. `supports_connect` is set false, so an `http://` call is sent in std's forward-proxy form (the full URL on the request line, `Proxy-Authorization` after the headers) and never as a `CONNECT` to a port a proxy such as Squid refuses by default.

**A call to a bypassed `http://` host is dialled by `nilo_fetch` and handed to std as a connection.** std applies `http_proxy` to every `http://` request of a client that has one, so there is no per-host switch to flip; `Exchange.pickConnection` takes the pooled connection or dials with `connectTcp` itself. A client with no proxy is not touched by this: `request` dials as it always did.

**Roots are a bundle the caller loaded, shared by both std clients and never freed by the client.** The private authority is "the system's plus one file", written with std's own calls (`rescan`, `addCertsFromFilePathAbsolute`), or an authority alone for a program that trusts nothing else. Setting `ca_bundle` and `now` is what stops std scanning the system on the first `https://` call, so the system is not scanned when roots are given and is, lazily, when they are not (the cost of a default program is unchanged). The client copies the bundle's struct into both std clients and `deinit` puts an empty one back before std frees anything, because std would free the one copy twice. The caller's bundle must outlive the client and must not change while it lives.

**A followed redirect keeps its credentials at home with a proxy as well** ([ADR 183](./183-a-redirect-is-a-decision-with-a-name.md)). The proxy's credential is not a header the caller wrote: std adds it to a request that goes to the proxy and to no other, so a redirect to a bypassed host goes direct without it and one to another proxied host sends it to the proxy again, and a `Proxy-Authorization` line the caller wrote is still dropped past a change of origin. The test follows a redirect from the proxy to a bypassed host and asserts neither `Proxy-Authorization` nor `Authorization` arrives.

**The pool is asked for the proxy's connection** (`Exchange.pickConnection`), keyed by the proxy as std keys it, so the stale-connection retry ([ADR 058](./058-most-of-an-s3-client-is-not-s3.md)) covers a proxied call as it covers a direct one.

## What it costs

- **Allocations per request:** none. The proxy and its two strings are allocated once, at start.
- **Memory per idle connection:** `Exchange`, the struct on a calling handler's stack, is 992 bytes before and after (the two new flags sit in padding). `Client` is 688 bytes against 640, once per process. The stack depth of a call is not re-measured here: the new frame (`pickConnection`, with a 255-byte name buffer) is the one `std.http.Client.request` already took, and it is gone before the call parks. `bench/mem.py` against an `outbound` server is the run that would say, and was not made.
- **Throughput and p99:** one more lock of the pool on a miss; a hit takes the lock it took before.
- **Binary size:** **+2,144 bytes** on a stripped `ReleaseFast` program that dials out through `nilo_fetch` with default settings (954,384 to 956,528), measured by building the same program against the module at the parent commit and at this one ([`bench/result/fetch.md`](../../bench/result/fetch.md)). It is unconditional, because the branch on `Settings.proxy` is a runtime one; that number includes the retry change below, which shares `pickConnection`. A program that does not import `nilo_fetch` pays nothing.

## What was rejected

- **Reading `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` by default**, as Go's default transport and reqwest do. std has `initDefaultProxies` for it. A server is not a curl in a shell: its environment is set by a platform, a container runtime or a CI system, and a proxy taken from it is a route the program's author never chose. Reading the environment is a caller's one line away (`nilo_config` into `Settings.proxy`), and the other direction is not.
- **A proxy per `Target`.** Proxying is a property of the network a process runs in, not of a destination, and a target would have to carry it through the shared pool. The bypass list is the per-destination switch.
- **Roots as a path or as PEM text in `Settings`.** Loading would need the `Io` at `init`, where there is none, or a file read inside `nilo_start`, and it would fix one way of composing (system plus file) where std's `Bundle` already offers all of them. A `*const Bundle` costs the caller four lines and the module none.
- **CIDR ranges and ports in the bypass list.** Not needed by the first caller and a parser to get wrong; an IP is listed as itself.
- **Implementing TLS inside the tunnel here.** It means building the TLS connection by hand next to std's and giving std a `Connection` it can read, which is a fork of the client; the better place is std. An upstream report, or a client of nilo's own ([`docs/todo.md`](../todo.md)), is where `https://` through a proxy waits.
- **Silently going direct for an `https://` call when a proxy is set.** Defeats the egress policy and hides a misconfiguration until the firewall drops the packets.

The retry change in this commit is [ADR 058](./058-most-of-an-s3-client-is-not-s3.md)'s, edited in place: a write that fails on a connection taken from the pool, with the peer gone and no head back, is the third spelling of a reaped connection.
