# Rate limiting

**An allowance slows down a client that asks too often; it is not protection against a flood, and it costs one compare-and-swap on a table whose size was fixed before the server started.**

**Guide:** [When one client asks too often](../guide/middleware.md#rate-limiting) · **Reference:** [`nilo.allowance`](../reference/middleware.md#niloallowance)

The code is `http/allowance.zig`.

## Overview

```
allowance.with(.{ .per_window, .window_s, .ipv6_prefix })   allowance.keyed(keyFn, .{ .per_window, .on_null })
  key: clientIp(), IPv6 masked to /64                          key: whatever keyFn(ctx) returns, or null
  fingerprint: packed into the counters' own u64                fingerprint: a second, dedicated u64 tag
                    │                                                       │
                    └──────────── one seed, drawn once per process ─────────┘
                                  (an offline-computable mapping is an aimable eviction)
                                              │
                                four ways, one cache line, one CAS
                                fail open while a slot is still ambiguous,
                                fail closed once the fingerprint has matched
                                              │
                     under `per_window`: through        over it: 429 + Retry-After
                                                          key was null + `.reject`: 403, no Retry-After
```

## Rules

1. **An allowance is a table sized while compiling, stored in `.bss`, with no allocation at startup or per request.** A program that never calls `with` or `keyed` links none of it. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
2. **Four slots share a bucket (one 64-byte cache line)**, and when a bucket is full the stalest slot (the oldest window) is evicted, instead of rejecting the client who just arrived. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
3. **Let the request through while a slot is still ambiguous; reject once the fingerprint has matched.** The first protects an unrelated client whose address collides with an arriving one. Once the fingerprint is this client's own, letting contention through would raise the limit to however many requests the server can run at once. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
4. **The window slides, using two counters in one word**: the previous window is weighted by how far into the current one the request lands. The window number is a `u16` that wraps every 65,536 windows (about 45.5 days); around that wrap, a kept slot can carry stale counters for up to two windows. This is documented as an approximation rather than fixed by widening the counter. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
5. **An IPv6 address is masked to `/64` (`.ipv6_prefix`) before hashing**, and both address families are parsed to bytes and tagged by family instead of hashed as text, so `10.0.0.1`, `010.0.0.1` and `::ffff:10.0.0.1` count as one key, not three. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
6. **The hash seed comes from `getrandom`, once per process**, so the mapping from address to bucket cannot be computed offline, and an attacker cannot aim an eviction at a chosen victim's slot. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
7. **Behind a proxy with neither `trusted_proxies` nor `trusted_hops` set, every client lands on one slot.** Only the rejection path checks for an `X-Forwarded-For` counted against the socket's own address, and it names the options to set, so requests that are let through pay nothing. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)
8. **`allowance.keyed(keyFn, options)` counts against something the application knows** (an account id, an API key, a tenant), in its own table. A key an attacker can grind offline (a username, a tenant slug) needs a wide fingerprint on its own, so it gets a dedicated 64-bit tag instead of the address table's packed one, whose bits are traded against the bucket index and do not add up. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
9. **`on_null` has no default.** When the key function returns null, the choice is `.skip` or `.reject`, and leaving the field out is a compile error. `.reject` answers 403, not 429, because nothing was rate limited and a `Retry-After` would be a lie. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
10. **`with` and `keyed` are combined by calling `use` twice.** A sign-in route limits by the claimed username with `.on_null = .reject`, on top of a `with` limited by address, instead of one middleware growing a fallback mode. [ADR 104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md)
11. **Two `with` (or two `keyed`) calls with identical options share one table**, because Zig instantiates a generic once per set of arguments. The `.name` field exists only to keep two otherwise identical allowances separate. [ADR 092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md)

## Decisions

| ADR | What it decides |
|---|---|
| [264](../adr/264-a-deployment-fact-is-a-late-value.md) | the counts as `nilo.Late(u32)` (a literal or the address of a variable), and `RateLimit` headers on every answer |
| [092](../adr/092-an-allowance-is-a-table-sized-while-compiling.md) | `allowance.with`: the compile-time table, the sliding window, eviction, the address key |
| [104](../adr/104-a-key-the-application-knows-is-a-word-of-its-own.md) | `allowance.keyed`: counting against a key the application knows instead of an address |

Related topics: the allocation budget an allowance is designed around is [ADR 017](../adr/017-the-trade-budget-has-four-axes.md) (principles); the cheap clock read a window check costs is [ADR 041](../adr/041-core-knows-what-time-it-is.md) (id-clock-entropy); the proxy nilo expects in front, which is why an allowance only slows clients down and is not the only limit, is [ADR 027](../adr/027-tls-is-terminated-in-front.md) (tls).

## Open questions

Nothing is open.
