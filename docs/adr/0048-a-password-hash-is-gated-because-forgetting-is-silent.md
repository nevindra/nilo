# A password hash is gated, because forgetting to is silent

[ADR 0042](./0042-the-bottom-layer-holds-more-than-one-module.md) opened the
bottom layer to modules that are not the vocabulary, and
[the roadmap](../roadmap.md) has carried `nilo_pw` as "unblocked, and in the
shape `nilo_id` already has" ever since. This is that module, and two of the
three premises that entry was written on turned out to be wrong when they were
measured.

The one that survived is the shape: argon2id as a pure function, in a tool
module, with what it cannot reach arriving as arguments. The two that did not
were the cost of a hash and where the salt comes from — and the second of
those is the whole reason this decision is longer than a module of 400 lines
would suggest.

## What the measurements said

On a 16-core desktop, Zig 0.16, `ReleaseFast`:

| | | |
|---|---|---|
| argon2id at `owasp_2id` (t=2, m=19 MiB, p=1) | **13.3 ms** | one hash, uncontended |
| what one hash asks the allocator for | **19,922,944 bytes** | one allocation, exactly |
| bcrypt cost=10 | 34.3 ms | 0 bytes of heap |
| bcrypt cost=12 | 136.5 ms | 0 bytes of heap |

The roadmap said 100 ms. It is 13, and **the gap is the decision**: at 100 ms a
handler that forgets `nilo.blocking` trips the blocking detector, which fires
at `block_warning_ms` — 250 by default, but a number people turn down. At 13 ms
it never fires at any sane setting. The mistake is silent.

Argon2 is bound by memory bandwidth rather than by cores, so the number that
actually matters is what N hashes cost each other:

| at once | mean per hash | throughput | transient heap |
|---|---|---|---|
| 1 | 20.1 ms | 49.8 hash/s | 19 MiB |
| 4 | 22.6 ms | 174.4 hash/s | 76 MiB |
| **8** | **30.8 ms** | **254.4 hash/s** | **152 MiB** |
| 16 | 53.6 ms | 279.2 hash/s | 304 MiB |
| 32 | 109.5 ms | 262.9 hash/s | 608 MiB |

Throughput peaks at 16 and **falls** at 32. Eight reaches 91% of the ceiling
for a quarter of the memory and a third of the latency.

Left ungated, 32 is what would run: `nilo.blocking` hands work to zio's thread
pool, whose default `max_threads` is `cpu_count * 2`, and nilo's engine never
overrides it. So the default ceiling would be set by a pool sized for calls
that wait on a disk, applied to a call that eats a core and 19 MiB.

Put that next to the invariant in
[ADR 0018](./0018-the-trade-budget-has-three-axes.md): an idle connection is
8,767 bytes, flat. One hash is 2,272 of those. Thirty-two at once is 608 MiB,
which is **7.3× the memory of the 10,000 idle connections `max_connections`
allows by default**.

## What was decided

**`nilo_pw` is a tool module and holds only the cryptography.** `hash`,
`hashWith`, `verify`, and a `Cost`. It imports nothing at all, so
`zig test pw/pw.zig` runs the whole of it — the entry condition ADR 0042 sets
for the layer, not a nicety.

**The salt and the allocator are arguments**, for the reason `nilo_id` takes
entropy and a millisecond as arguments: neither is reachable from down here,
and 19 MiB is not a number a framework should spend without saying so.

**`Ctx.hashPassword` / `Ctx.verifyPassword` are the half a handler calls**, and
they are not a convenience wrapper. They take the salt from `Ctx.entropy`
([ADR 0046](./0046-entropy-belongs-to-the-loop.md)), take a permit from a
process-wide Gate, and park the fiber on the blocking pool. **Because the
mistake they prevent is invisible, it is not the caller's to remember.**

**`Options.password_hashes_at_once` defaults to 8**, from the table above.

**`bulkhead.Gate` is new** — a counting lock, a Mutex with a number bigger than
one, wrapped for the reason `Mutex` is wrapped: waiting for a turn is not the
handler holding its thread, and the detector has to be told
([ADR 0034](./0034-the-thing-a-handler-holds-is-watched-at-run-time.md)).

**`verify` takes `?[]const u8`, and null means there is no such account.** It
does the work anyway and answers false. A sign-in that returns early when the
address is unknown answers in a millisecond instead of thirty, which turns the
form into a query for which addresses are registered. There is no signature
here that lets the fast wrong version be written — that is the point of the
optional, and it is why there is no separate "dummy verify" function to know
about.

**Argon2id, not bcrypt.** The measurement is the argument rather than fashion:
bcrypt cost=10 is 34 ms against argon2id's 13, so bcrypt is **2.6× slower** for
a configuration nobody would call stronger. What bcrypt buys is the 19 MiB —
zero heap, entirely. For a framework whose pitch is 8,767 bytes a connection
that is a real trade and it is refused deliberately: the 19 MiB is what costs
an attacker with a GPU, it is transient rather than resident, and the Gate
turns it into a number an operator can multiply. A future `Options` could
expose bcrypt for a memory-bound deployment; nobody has asked.

## The `std.Io` that a module with no loop cannot have

`std.crypto.pwhash.argon2` in Zig 0.16 takes a `std.Io`. That is exactly the
thing a tool module does not have, and it is the reason the roadmap's "pure
function of a password, a salt and its parameters" did not describe anything
that exists: `strHash` generates its own salt through `io.random`, and both it
and `kdf` want an `Io` in the signature.

It is used for two things. `io.random` for the salt, which this module never
reaches because the salt is an argument. And lane parallelism, through
`processBlocksAsync`, when `p > 1`.

**`std.Io.Threaded.init_single_threaded` is the answer.** It is a comptime
constant — 864 bytes, copied onto the caller's stack — with
`.allocator = .failing`, `.async_limit = .nothing` and
`.have_signal_handler = false`. It spawns no thread and installs no handler,
and `group.async` on it runs each lane inline.

This was checked rather than assumed. Against a real `std.Io.Threaded` it
agrees byte for byte at p = 1, 2, 4 and 8, and the comparison is a test at the
bottom of `pw/argon2id.zig` rather than a sentence here. What it buys is not
academic: a hash that arrived from a library defaulting to `p = 4` verifies,
sequentially and correctly, in a module that holds no runtime.

## Why not the alternatives

**Leave it to the user with `nilo.blocking` and `nilo.Mutex`, both of which
already exist.** This is the one that looks right and is not, and the 13 ms is
why. Every other blocking call nilo has is *slow* — a database round trip, a
file read — and a handler that forgets to wrap one is caught by the detector
within a request or two. A password hash is *expensive*, not slow: it sits
under every threshold and shows up as p99 on endpoints that have nothing to do
with signing in. A rule that only a correct reading of the documentation
enforces is not a rule this repository keeps
([ADR 0027](./0027-the-rule-about-error-messages-is-held-by-a-build-step.md) is
the same argument about error messages).

**Put the Gate on the App.** There is one memory controller per process, not
one per App. Two Apps in one process at 8 each is 16, which is the number the
table says not to run. It is a file-level `var` in `http/password.zig` and
`listen` sets it; a second `listen` with a different number wins, which is the
honest outcome for a process-wide limit and is said out loud in `Options`.

**Take the 19 MiB from the request arena.** The arena is reset per request
keeping `arena_keep` bytes. Nineteen megabytes through it would spend the one
axis ADR 0018 treats as an invariant rather than a budget, on every sign-in,
and leave the high-water mark behind. The allocator is an argument instead.

**Ship the PHC encoder ourselves, or invent a format.** `phc_format` is public
in std and the format is what every other library writes. A hash nobody else
can read is a hash nobody can migrate off, which is the only reason to have a
format at all.

**Let the Cost be a runtime value.** It is `comptime`, so a Cost below the
floor is a Refusal. Turning the cost down to make a test suite fast is the
mistake worth catching, because it is invisible afterwards — a weak hash looks
exactly like a strong one. The floor is 7 MiB, the weakest configuration OWASP
still publishes.

## What it costs

**Allocations per request: unchanged.** Nothing on the request path calls any
of this. A handler that does hash a password makes one allocation of 19 MiB
from an allocator it named itself, which is a path that asked for it.

**Memory per idle connection: unchanged.** 8,767 bytes. Nothing here is
per-connection: the Gate is one struct per process and the 19 MiB is transient,
held only while a hash is running and bounded to eight of them.

**Throughput and p99: unchanged for anything that does not hash.** For anything
that does, the numbers are the table above and they are the feature rather than
its overhead.

**Binary size: 0 bytes for a project that never signs anybody in.** Measured,
not asserted — a stripped `ReleaseFast` build of the benchmark server before
and after this change is byte-identical in every section:

```
   text     data      bss
 857967    29544   323768   before
 857967    29544   323768   after
```

`listen` calls `password.setLimit` unconditionally, so the Gate is written and
never read — and a write-only global is one LLVM removes outright, along with
everything it reaches. A project that *does* call `Ctx.hashPassword` pays
**+152,612 bytes of text** (+155,944 on disk), which is argon2id, blake2b, the
PHC encoder and the Semaphore. Running total in ADR 0018 unchanged, because the
linker charges nobody who does not ask.

## Consequences

**The blocking detector has a floor, and it is now written down.** Anything
that costs less than `block_warning_ms` but more than nothing is invisible to
ADR 0034. Password hashing is the first call nilo ships in that band. It will
not be the last, and the answer each time is the one taken here: if forgetting
is silent, the framework does the remembering.

**`nilo_pw` stores nothing.** No user table, no sign-in, no session. A hash is
a value and where it lives is the application's; the session that follows a
successful check is `Session(T)` and already built
([ADR 0035](./0035-a-session-is-sealed-into-the-cookie.md)).

**A sign-in is now the most expensive thing an unauthenticated client can ask
for**, by a wide margin, and the Gate bounds the memory rather than the
queueing. Past eight, requests wait; `header_timeout_ms` is what eventually
answers a client that will not. Rate limiting the endpoint is the
application's, and nilo has no opinion to offer about it yet.

**Nothing was added to the four examples.** Signing somebody in needs a user
store, which means a database, which means `nilo_sql` — and an example that
drags the lazy dependency in for one route would cost every reader of
`zig build examples` the thing [ADR 0040](./0040-a-service-that-needs-the-loop-is-finished-when-the-loop-exists.md)
bought. The doc comment on `nilo_pw` carries the eight lines instead.
