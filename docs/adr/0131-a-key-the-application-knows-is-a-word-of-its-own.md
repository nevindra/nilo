# A key the application knows is a word of its own

`allowance.with` counts against `clientIp()`, which is the right key for a
scraper and the wrong one for everything the application knows: which account
signed in, which API key was presented, which tenant the request belongs to.
Ten accounts behind one office NAT share an allowance they should not, and one
account on ten machines gets ten.

The table, the sliding window and the eviction were all built and none of them
cared what the key was
([ADR 0114](0114-an-allowance-is-a-table-sized-while-compiling.md)). What was
missing is the key.

```zig
fn account(c: *nilo.Ctx) ?nilo.Str {
    const who = c.session(Account) orelse return null;
    return who.id;
}

try app.useOn("/api", nilo.allowance.keyed(account, .{
    .per_window = 1000,
    .on_null = .reject,
}));
```

## The key's bytes are not kept, and that is what decides the layout

A `Str` out of the request arena is gone by the next request, so an account id
cannot simply be stored in the slot. There were two ways round that and they
are not the same size.

**An inline copy of the key**, 32 bytes a slot, capped: a key-length policy to
invent, an account id sitting in `.bss`, and 4,096 slots costing 128 KB.

**A 64-bit tag from a keyed hash**, which is what this does. The bytes only
have to live long enough to hash them. There is no length to cap, nothing
identifying in `.bss`, and the extra cost is 32 KB at 4,096 slots.

**The packed fingerprint an address uses is not enough here**, and the reason
is not scale. A targeted collision has to match the bucket index *and* the
fingerprint, so it is `2^(b+f)` — `2^46` at the address table's default, and
still `2^46` at the widest ceiling, because the bits the fingerprint loses the
index gains. `2^46` is out of reach for a server-generated opaque id. It is
**not** out of reach for a username or a tenant slug, which an attacker grinds
offline and then registers the winner of: hours at a billion tries a second.
With a tag of its own it is `2^(b+64)` — `2^74` at the default — and the
grinding stops being a plan.

Both hashes come off the per-process seed ADR 0114 already sets, so the mapping
is not the same in two processes and none of this is computable offline.

## What the second word costs, and where

Two words cannot be moved together without a 128-bit compare-and-swap, which
not every target has. So the tag is claimed first — it is what other fibers
look for — and the state is stored immediately after.

A fiber arriving between those two instructions sees this key's tag against the
previous owner's counters, reads the window as old, and starts a fresh count.
**A takeover can lose the handful of requests in flight at that instant.** A
takeover is an eviction, which is rare by construction; the alternative is an
instruction half the targets do not have.

The other direction is closed, and it is the one that would be a hole: a count
that lands after somebody else took the way over is thrown away and tried
again, rather than charged to them. `chargeKeyed` re-reads the tag after a
successful count and loops if it moved.

Everything else is shared with the address table — one copy of the sliding
window, one copy of the four-way eviction, one copy of ADR 0114's
fail-open-while-inserting and fail-closed-once-it-is-yours.

## `null` cannot quietly mean "not counted"

`keyed(signedInAccount, …)` on a sign-in route with a silent skip leaves every
*failed* sign-in uncounted, which is the attack the route exists to stop. So
`on_null` has no default: writing `.skip` or `.reject` is the moment somebody
thinks about it, and a missing field is a compile error.

`.reject` answers **403, not 429**. Nothing was rated and nothing was exceeded;
the request carried nothing to count, and the client's remedy is to carry
something rather than to wait. A `Retry-After` on it would be a lie.

The right shape for a sign-in route is neither on its own: the key is the
*claimed* username with `.on_null = .reject`, composed with an address-keyed
`allowance.with` underneath it. Composition is `use` twice, which the
middleware chain already does.

## What it costs

**Nothing for a route it does not guard**, and nothing for a program that never
calls it: everything is settled while compiling and the linker drops the rest.

**Per guarded request**: two `Wyhash` passes over a short key rather than one,
one modulo, and up to four ways of a bucket read. No allocation, at startup or
ever. The second hash is the whole of the added work against `with`, and both
tables are read the same way.

**`.bss`**: 16 bytes a slot rather than 8. The default of 4,096 slots is 65,536
bytes, once, for the whole process — smaller than the address table's 16,384
because there are fewer accounts in flight than there are addresses on the
internet. Both arrays are 64-byte aligned, so a bucket is one cache line and a
lookup never touches two.

**Nothing per connection.**

**`per_window` goes to 65,535 here**, where the address table stops at 1023.
The bits an address spends on its fingerprint are a word of their own now, so
16 bits of window and two 16-bit counters fit with room left. A per-account API
quota of 10,000 an hour is an ordinary number and a compile error on the other
one.

## What was rejected

**An inline key copy.** Above: a length policy, ids in `.bss`, four times the
memory.

**Widening the packed fingerprint by narrowing the counters.** It buys bits
from the thing that decides `per_window`, and it does not reach far enough: the
index loses what the fingerprint gains, so the product does not move.

**A default for `on_null`.** Either default is wrong for half the callers and
silent for all of them.

**`.on_null = .by_address`, falling back to `clientIp()`.** The most useful
third answer, and it needs either a second table or a tagged key space, and it
hides a composition that is already two lines. Two middlewares say what is
happening; one middleware with a fallback mode does not.

**Taking the key as `[]const u8` only.** Most of `Ctx` hands back a `Str`, so
every call site would have carried a `.view()` and every forgotten one a
compile error about a type nobody asked about. `keyed` takes either.
