# A proxy is trusted by which one it is

`.trusted_hops` counts entries from the right of `X-Forwarded-For`. Each proxy
appends the address it heard from, so the rightmost entry was written by the
proxy nearest this server and the leftmost is whatever the client claimed;
counting from the right means a forged entry sits to the left and is never
read.

That arithmetic is sound, and it is why the option shipped in that shape. What
it cannot say is anything about **which** machine is in front:

- there is no way to say the header counts only when the connection came from
  `10.0.0.0/8`;
- there is no way to describe a deployment where the number of hops differs by
  path — a load balancer adding one for public traffic while a health check
  reaches the pod directly.

Gin takes a list of CIDRs and Fiber takes ranges plus the loopback and private
classes. Both answer that question. A hop count cannot.

## What earned the change is that a wrong count says nothing

`clientIp()` returns something that looks like an address whatever happens. Add
a CDN in front of the load balancer and the count is one short from that
afternoon on — and the server goes on answering, with the load balancer's
address, or with whatever the client wrote in the header. Nothing logs, nothing
fails, no test turns red.

The things that read `clientIp()` are the rate limit, the audit log and the
blocklist. Those are exactly the things worth lying to, and exactly the things
nobody re-reads six months later.

## What it does now

```zig
try app.listen(.{ .trusted_proxies = &.{"private"} });
```

Each entry is a CIDR (`10.0.0.0/8`, `fd00::/8`), a bare address meaning that
host alone, or one of two names — `"private"` for the RFC 1918 ranges plus
carrier-grade NAT, link-local, unique-local v6 and the loopback, and
`"loopback"` for the loopback alone. Two names rather than a vocabulary,
because those are the two every deployment writes: a pod or an office LAN, and
a sidecar on the same host.

The walk is the one nginx's `realip` and Gin both arrive at:

1. If the connection did not come from a named address, the header is not read
   at all. A machine on the open internet does not get to say who it is
   forwarding for.
2. Walk `X-Forwarded-For` from the right. An entry naming a named address is a
   proxy of ours; skip it.
3. The first entry that is not one of ours is the client. Everything to its
   left is whatever the client claimed and is never looked at.
4. If every entry is one of ours — a health check from the load balancer —
   there is no client behind them, and the socket's address is the honest
   answer.

**Nothing in that depends on how many proxies there are.** That is the point:
the number stops being a thing to keep right.

**A v4 rule matches a client that arrived v4-mapped.** A server bound to `::`
hands an IPv4 client to a handler as `::ffff:203.0.113.9`, so every rule is
stored in its 128-bit form and `10.0.0.0/8` is kept as `/104`. The rule is
written once.

**An entry that is not an address is not trusted.** RFC 7239 lets a proxy write
`unknown` when it cannot say; the walk stops there rather than reading past it
into whatever the client claimed.

**A rule that is not an address stops the server**, at `listen()`, with a
sentence naming it — before the port is taken. Ignoring it would mean answering
with the wrong client address for the life of the deployment.

**`.trusted_hops` still works and still means what it meant.** When both are
set, the description wins: an operator who described their network meant that,
and the count left over from before is the thing the description exists to stop
mattering.

## What it costs

**Startup**: one parse per rule, into an allocation the App owns. `"private"`
is nine networks.

**Per request: nothing, unless a handler asks.** `Ctx` reads this only inside
`clientIp()`, and only when the request carries the header. Then it is a
16-byte prefix compare per entry per rule — a handful of integer compares for a
list that is one to three long
([ADR 0018](0018-the-trade-budget-has-three-axes.md)). Nothing is allocated;
the answer is a slice of the header, which is where the old code's answer came
from too.

**Nothing per connection.** The parsed list is one slice on `Limits`, which is
copied onto the App once.

## What was rejected

**A vocabulary of names.** `"cloudflare"`, `"aws-alb"`, and so on. Those are
published address lists that change, and shipping a copy means shipping a copy
that goes stale. A CIDR list is what the operator already has.

**Trusting by hostname.** A reverse lookup per request, on the request path,
against a DNS server. No.

**Dropping `.trusted_hops`.** It shipped, it is correct for the deployment it
describes, and the migration would be a breaking change for an option that is
not wrong — only narrow.

**Per-path trust.** The second half of what a hop count cannot express: a
health check reaching the pod directly while public traffic comes through a
load balancer. Naming the networks answers it without a per-path anything —
the health check's connection comes from an address that is or is not in the
list, and the walk works either way.
