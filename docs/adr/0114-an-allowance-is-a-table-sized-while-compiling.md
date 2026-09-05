# An allowance is a table sized while compiling

Gin, Fiber, Echo and every other framework of that shape ship a rate limiter,
and all of them are the same program: a hash map keyed by the client's address,
a mutex or a sharded lock around it, and a sweeper goroutine that walks the map
throwing away entries nobody has used. That is a hash, a lookup, a lock and —
for an address nobody has seen before — an **allocation**, on the path of every
request the limiter guards.

nilo has one allocation per request and a test that fails if it becomes two
([ADR 0018](./0018-the-trade-budget-has-three-axes.md)). So the map is not
available, and what replaces it decides the whole design.

**`allowance.with()` is a table sized while compiling, living in `.bss`, indexed
by a hash of the client's address.**

```zig
try app.useOn("/api", nilo.allowance.with(.{ .per_window = 100, .window_s = 60 }));
```

No allocation per request, and none at startup either: the memory is in the
binary's image before `main` runs. Nothing is added to `App`, to `Ctx` or to the
Bulkhead, and a program that never calls `with` links none of it.

## The shape follows from the budget

A middleware has no startup hook — `use()` takes a function pointer and there is
nowhere for one to size a table at `listen()`. That looked like the constraint to
work around, and it turned out to be the one that made the feature small:

- **One `u64` is one address's whole state.** Two counters, the window number
  and a fingerprint, in a `packed struct(u64)`. Taking a slot over and counting
  a request against it are then the same compare-and-swap, so there is no lock
  anywhere in the feature.
- **Four slots share a bucket**, so a lookup touches one 64-byte cache line and
  never two.
- **`.slots` is what an operator multiplies**, not a limit that surprises: 16,384
  slots is 131,072 bytes, once, for the process. A deployment that wants to
  remember a million addresses says `.slots = 1 << 20` and pays 8 MB of `.bss`
  for it.

## Which direction to be wrong in

A fixed table cannot hold everybody, and a hash table without chaining has to
answer what happens when a bucket is full. There are two ways to be wrong and
they are not the same size:

- **Two addresses share one slot.** Somebody who has made no requests is refused
  because a stranger with a colliding hash spent the allowance. To that person
  the service is simply down, and nothing they do fixes it.
- **Somebody is let through.** The limit is looser than it says for one window.

So a full bucket **evicts its stalest way** — the one whose window is oldest —
and the arriving address gets a whole allowance of its own. Contention loses the
same way: four failed compare-and-swaps in a row let the request through, rather
than turning a busy moment into an outage for whoever happened to arrive during
it. **It fails open, on purpose, and that is the sentence to disagree with if
you want to argue with this design.**

The eviction is also why a slot carries a fingerprint at all. Without one, an
address that hashes into a taken bucket would read somebody else's counters as
its own, which is exactly the failure above; with one, it reads "this is not
mine" and takes a slot instead.

## The window slides

Two counters rather than one. A fixed window lets twice the ceiling through
across a boundary — a hundred at 11:59:59 and a hundred at 12:00:00 — and a
burst is precisely what this is for. The sliding version weighs the previous
window by how far into the current one the request arrived, which costs no
memory at all (both counters were already in the same word) and about fifteen
lines of arithmetic.

The window number is a `u16`, so it wraps every 65,536 windows — 45 days at
sixty seconds. Age is read as a wrapping subtraction, so what a wrap costs is
one returning client, inside a two-window band, after a month and a half.

## An IPv6 client is a prefix

Keyed on the whole 128 bits, an IPv6 limit is not a limit: the customer has
2^64 addresses and can spend the allowance once from each. So an IPv6 address is
masked to `/64` before it is hashed, which is one customer's allocation, and
`.ipv6_prefix` moves it.

An IPv4 address is hashed as the text it arrived as. The kernel and every proxy
write it canonically, so there is nothing to parse and nothing to normalise —
and anything that does not parse as an address at all is hashed as text too,
which is the safe way to be wrong: two clients that would have shared a slot get
separate ones.

## The mistake it is most likely to be deployed with

Behind a proxy with `trusted_hops` left at zero, `clientIp()` is the proxy's
address, the whole table collapses onto one slot, and the first busy second
locks out the world.

Nothing at `listen()` can tell whether a proxy is there. But a request that
carried an `X-Forwarded-For` **and** was counted against the socket's own
address is the fact rather than a guess at it — so the refusal path checks for
exactly that and says so once, naming the option to set. It costs the accepted
path nothing, because it is only ever reached on a 429.

## What this is not

It is not a defence against a flood, and the module header says so. A refused
request is still a read, a parse, a route match and a write; a stranger with ten
thousand sockets still closes the door through `max_connections`, which counts
per process rather than per address. What an allowance is for is the client that
asks too often — a scraper, a script in a loop, a retry storm, a password form
being walked through a word list.

It is also not the only place this can be done. nilo asks for a proxy in front
([ADR 0028](./0028-tls-is-terminated-in-front.md)), and nginx and Caddy both rate
limit. The reason to have it here anyway is that the proxy limits by address and
the application knows things the proxy cannot: which account signed in, which
API key was presented, whether this route is the expensive one. `with()` is the
address-shaped half; a `keyed()` that takes the key from the request is the
obvious next thing and is not built.

## What it costs

- **Allocations per request: zero.** The `Retry-After` is a compile-time
  constant, so even the refusal path sets a header without copying anything.
- **Per idle connection: zero.** Nothing is held between requests.
- **Memory: `.slots × 8` bytes of `.bss` per distinct `Options` in the
  program**, 131,072 at the default, and none at all in a program that does not
  use it.
- **Per guarded request:** a hash of the address, one cache line, one
  compare-and-swap, and one coarse clock reading (2ns —
  [ADR 0045](./0045-core-knows-what-time-it-is.md)).
- **Binary size:** the number is in ADR 0018's running total.

Two `with()` calls carrying identical options are **one table**, because Zig
settles a generic once. That is usually what is wanted and is wrong when a
sign-in route and a search route are meant to be counted apart, which is what
`.name` is for — a field that exists only to make two types different.
