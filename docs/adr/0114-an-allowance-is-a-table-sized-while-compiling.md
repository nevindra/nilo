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
and the arriving address gets a whole allowance of its own.

**Contention is where this shipped wrong**, and the correction is worth stating
rather than quietly making. Four failed compare-and-swaps in a row let the
request through, on the same reasoning: better loose than an outage for whoever
happened to arrive during a busy moment. That reasoning is right for
*insertion*, where the competition is between an arriving address and a stranger
already in the bucket. It is wrong once the fingerprint has matched, because
then the contention is **this client's own traffic against itself** — there is no
stranger to protect, and letting it through is not caution.

The cost of getting that wrong was not "slightly loose": with a matched slot
failing open, the ceiling became *how many requests the server can run at once*
rather than `per_window`. A synchronised wave from one address walks past the
limit, and can do it again — no botnet, no address range, no hash work. A
password guesser holding requests in flight produces exactly that pattern and so
does an ordinary retry storm.

So the rule is now split where the argument actually splits: **fail open while
the slot is ambiguous, fail closed once it is unambiguously yours.**

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

The window number is a `u16`, so it wraps every 65,536 windows — 45.5 days at
sixty seconds. Age is read as a wrapping subtraction, and the honest account of
what that costs is wider than the one this ADR first gave ("one returning
client, inside a two-window band"):

- At exactly 65,536 windows the modular difference is **zero**, so a 45-day-old
  slot is read as belonging to the current window and its counters survive
  intact. The window after that, the difference is one, so the stale count
  becomes `prev` and is carried again. **Stale state can therefore affect a
  client for up to two full windows** — about two minutes, once every 45.5 days.
- It is not one client. **Every** retained slot whose modular age happens to
  alias is affected, and a quiet table can hold many.
- `window -% was.window` stops being an age ordering at all once entries can
  survive a whole wrap: true ages of 65,535, 65,536 and 65,537 windows read as
  65,535, 0 and 1. Eviction then picks the largest residue rather than the
  oldest slot.

Left as it is, deliberately. Widening the field to 24 or 32 bits would remove it
and would cost bits the counters and the fingerprint are using; two minutes
every month and a half, in a structure that is already documented as
approximate, is not worth that trade. It is written down here so the next person
finds a decision rather than a surprise.

## An IPv6 client is a prefix

Keyed on the whole 128 bits, an IPv6 limit is not a limit: the customer has
2^64 addresses and can spend the allowance once from each. So an IPv6 address is
masked to `/64` before it is hashed, which is one customer's allocation, and
`.ipv6_prefix` moves it.

**An IPv4 address is parsed too, and the version that shipped did not.** The
argument for hashing it as text was that the kernel and every proxy write it
canonically. That is true of the kernel and false of `X-Forwarded-For`, where
the text is written by whatever is upstream — and behind a misconfigured
`trusted_hops`, by the client. `10.0.0.1`, `010.0.0.1` and `::ffff:10.0.0.1` are
one address and were three keys, so a client had as many allowances as it had
spellings. Both families are now parsed to their bytes and tagged by family
before hashing, and a leading zero is read as decimal rather than octal — not
because decimal is more correct, but because a spelling nobody agrees about is
one an attacker gets to pick.

Anything that does not parse as an address at all is still hashed as text, which
is the safe way to be wrong: two clients that would have shared a slot get
separate ones.

## The index is secret

The seed the address is hashed with is drawn once per process, from
`getrandom` where there is one.

A fixed seed makes the whole mapping computable offline, and two attacks fall
out of that without touching the fingerprint at all. Finding a key that lands in
a chosen victim's bucket costs about 4,096 tries — twelve bits — so an attacker
grinds one, sends a single request, evicts the victim's slot, and the victim's
count restarts at one. Repeat whenever the victim approaches the ceiling and the
victim has no limit. The mirror image is to sit in the victim's bucket and keep
it warm so the victim is the one evicted.

Both need the *index*, and the index is cheap; neither needs the fingerprint,
which is not. A secret the attacker cannot read turns every one of those tries
into an online probe against a mapping that the next restart reshuffles.

This is what makes the eviction policy defensible rather than merely documented.
Eviction is still how a full bucket makes room — that has not changed — but it
can no longer be aimed.

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

## What a review changed, and what it did not

The design above was put to an outside reviewer after it shipped, with the four
judgements it rests on named as things to attack. Three of them did not survive
and are corrected in place above: the blanket fail-open, the IPv4 text key, and
the too-narrow account of the `u16` wrap. The seed came from the same reading.

Two survived, and they are worth recording because they were the ones most
likely to be wrong:

- **The ordering of the two failure modes holds.** A fingerprint collision at
  the default 34 bits is about one event per tens of thousands of
  hundred-thousand-address windows, so it is not the main source of
  innocent-neighbour interference.
- **The two-counter window is not the weak choice it looked like.** A decaying
  counter in the same 64 bits is *not* strictly better: interpolation can
  undercharge a burst placed late in the previous window by nearly the whole
  limit, and decay undercharges a burst immediately and then keeps charging it
  after an exact window would have forgotten it. Neither dominates. That closes
  a question the roadmap had open.

One thing the review changed that is *not* in the code: **eviction is the
dominant loss, not collision.** At 100,000 distinct addresses through a
16,384-slot table the mean bucket has seen 24 arrivals, every bucket is
effectively full, and roughly 84,000 of those insertions displace somebody. A
client can lose its slot to unrelated newcomers and restart at one without
anybody targeting it. That is the honest shape of this structure under load, and
it is why the module header calls it a shaper rather than an enforcement
mechanism.

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
