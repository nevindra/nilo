# A path is an address to listen on

`bulkhead.Options` carried `address` and `port`, and `engine/zio.zig` handed
them to `zio.net.IpAddress.parseIp`. So the only thing nilo could be reached
over was a TCP port, and two things followed from that.

The proxy [ADR 0028](0028-tls-is-terminated-in-front.md) puts in front had to
reach the server over loopback TCP, because there was nothing else to reach it
over. And a port is open to every process on the machine and, if the bind
address is wrong by one character, to the network — where a unix socket is a
file, and the answer to "who may connect" is the answer to "who may write to
this directory".

## What it does now

```zig
try app.listen(.{ .address = "unix:/run/nilo.sock" });
```

`port` is not read at all then. Anything without the prefix is an IP address
exactly as before.

**A prefix rather than a field beside it.** `address` already means "what to
listen on", and a second field — `unix_path` — would leave a third state, both
set, that means nothing and has to be refused with a sentence. The prefix is
also unambiguous by construction: no IPv4 or IPv6 address begins with a letter
followed by a colon, so nothing that used to work is read differently now.

**The socket file is cleared up at both ends.** A unix socket is a file, and
closing the descriptor leaves it there — so a server that was killed leaves a
path behind and the next bind is `AddressInUse`, which during development is
every restart. That is exactly the case `reuse_address` is on by default for,
so it means the matching thing here: remove a socket left behind before
binding. And this server removes its own path when it stops, so the ordinary
restart never gets that far.

**What gets removed is narrow, and that is the decision.** Unlinking whatever
happens to be at a path somebody typed is how a server deletes their database.
Two questions, and both have to answer yes:

1. Is it a socket? A regular file, a directory, a symlink to either — left
   alone.
2. Is it dead? Asked the only way it can be asked: by connecting. A live server
   accepts and keeps its path; a stale one refuses and loses it.

A path that fails either is left exactly as it is, and the bind that follows
fails with a sentence naming it. Two servers pointed at one path is a mistake
worth being told about, not one to resolve by taking the socket off the one
that got there first.

**A connection that arrived this way has no client address**, and `Ctx.peer()`
is empty. That is honest — there is no address; a unix socket has a path where
the peer's address would be — but on its own it would have made the feature
useless for the deployment it exists for, because `clientIp()` reads
`X-Forwarded-For` only when the connection came from an address in
`.trusted_proxies` ([ADR 0129](0129-a-proxy-is-trusted-by-which-one-it-is.md))
and there is no address to test.

So a unix connection passes that check by arriving. Nothing remote can open a
unix socket, which is the thing a `"loopback"` rule is trying to establish
about a proxy over TCP, established here without a rule at all. It is still an
opt-in: with `.trusted_proxies` unset the header is not read, and `clientIp()`
on such a connection is empty.

## What it costs

**Nothing per request**, and nothing per connection. The branch is one
`startsWith` at startup. `Peer` grows one `bool` — it lives in the fiber's
frame for the length of a request and is unwound before the connection waits
([ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md)), so it is not
memory an idle connection holds.

**Binary size**: `listenOnUnix` and the stale-socket check are reachable from
`serve`, so they link into every server whether or not it listens on a path.
It is two `std.log.err` call sites, a `statFile` and a `deleteFile` — the
`std.Io.Threaded` behind those two was already linked, because `static.zig`
stands one up at startup for the directory walk. Not separately measured, and
the running total in [ADR 0018](0018-the-trade-budget-has-three-axes.md) is
what a measurement would go into.

**Throughput is the reason to want it and the number has not been taken here.**
What a unix socket is worth on the way in was this gap's `Waiting on: a number`
in the roadmap, and the box this was built on has two cores and no load
generator that speaks unix sockets. The two numbers that argue for it are both
somebody else's measurement of something adjacent: the same swap on
`nilo_sql`'s *outbound* side was worth 359k req/s to 458k with p99 halved
([`bench/result/sql.md`](../../bench/result/sql.md)), and every HTTP figure this
repository publishes was taken across a Docker published port, where the same
server over a unix socket was 133% faster. **Neither of those is this
measurement**, and anybody quoting them as one is doing the thing
[ADR 0071](0071-where-a-connection-waits-is-what-it-costs.md) was written
about. What earned the feature without the number is the other half: a port is
open to every process on the machine, and a socket file is not.

## What was rejected

**A second field.** `unix_path: ?[]const u8`. Two fields for one question, and
a state where both are set that has to be refused in prose.

**A tagged union.** `listen_on: union(enum) { tcp: …, unix: … }` says it best
of the three and breaks every `listen()` call that exists.

**Unlinking the path unconditionally before binding.** What most examples on
the internet do. It turns a typo in a config file into a deleted file, and the
typo is exactly the case where the path is not what the author thought.

**Creating the directory.** A server that makes `/run/nilo/` decides its owner
and its mode, which is the deployment's business. Missing directory is an
error with a sentence saying so.

**A `unix_mode` option.** The socket takes the process umask, so by default a
local user can connect — which was already true of a loopback port, so nothing
got looser. Setting the mode is worth having when somebody wants the socket
readable by one group only; it is a field with no caller yet.

## What is left

**A listener somebody else opened.** The other half of this gap: a process that
can be handed an open descriptor can take the socket over from the process it
replaces, so a deploy with nothing in front of it stops dropping the
connections in flight. It is not here. An inherited descriptor has to be put
into non-blocking mode before the event loop may have it, and how it is named
is a protocol decision — systemd's `LISTEN_FDS` convention, or a bare number —
that wants a caller with a deploy to point at. The roadmap keeps a sentence.
