# nilo_cache against seven other caches, in three languages

Seven competitors in three directories, in the order they were added. The
numbers and what they moved are in
[`bench/result/cache.md`](../result/cache.md); this file is what is held equal
and what cannot be.

## Go — `go/`

[patrickmn/go-cache](https://github.com/patrickmn/go-cache) is a
`map[string]Item` under an `RWMutex` that hands back a pointer and has no
memory bound at all. It was the first comparison because it is what a Go
program reaches for, but it answers a different question: how fast a map is,
not how much a cache can hold in a fixed budget.

[coocood/freecache](https://github.com/coocood/freecache) is the closest thing
to `nilo_cache` in any language: a fixed byte budget, a segmented ring, and a
copy into the caller's buffer on the way out. It is the comparison that means
the most.

[allegro/bigcache](https://github.com/allegro/bigcache) is the same family: one
`[]byte` array with a `map[uint64]uint32` of offsets into it.

## Rust — `rust/`

[moka](https://github.com/moka-rs/moka) is Caffeine's Rust descendant, and its
replacement policy — admission by TinyLFU, eviction by LRU — is the strongest
in this whole comparison. It is the one to beat on hit rate.

[quick_cache](https://github.com/arthurprs/quick-cache) is the other end: a
CLOCK-pro-ish policy in a table that stores small values inline. It is the
fastest cache in this comparison and the section below says why.

## Zig — `zig/`

[karlseguin/cache.zig](https://github.com/karlseguin/cache.zig) is an LRU-ish
cache of reference-counted entries: `get` hands back a `*Entry` the caller
must `release()`, which is how a value can outlive the eviction that removed
it. It is the only cache here that lets a caller hold a value that long.

[jaxron/zigache](https://github.com/jaxron/zigache) is a policy kit — FIFO,
LRU, SIEVE, S3-FIFO and W-TinyLFU behind one type. **It is the only other
cache in the comparison whose policy is the same family as nilo's**, so it is
the one that says whether nilo's two regions are worth anything against a
careful implementation of the same idea. It is measured at three of its five
policies.

## Run it

```
./run.sh                 # every side, interleaved, then memory, then hit rate
```

Each language is skipped rather than faked when its toolchain is missing, and
`run.sh` says which. Go is looked for on the path and in `~/.local/opt/go/bin`;
Rust needs `cargo`; the Zig side builds with the same `zig` as the repository.

## What is held equal

- The same 50,000 keys, **built before the clock starts on all sides**. A key
  formatted inside a timed loop measures the formatter.
- **A separate copy of the key text for lookups.** Go compares two strings by
  checking their data pointers first, so looking up with the object that was
  stored makes the key comparison free — a shortcut the other side has no way
  to take. This is worth about 20% and it is invisible in the source.
- The same values: a flat 24-byte struct, and a 512-byte page on the Go side.
- The same mix: nine reads to a write.
- Warming per row, and a fresh cache per row. Both of the harness bugs this
  rule exists for produced *higher* numbers.
- freecache and bigcache are called through `GetWithBuf` and a caller's
  buffer, not the allocating `Get`. That is the fair call: it reads into a
  buffer the caller already has, the way `nilo_cache.get` does. The allocating
  call would measure Go's allocator, not the cache.
- **The hit-rate sweep gives every count-bounded cache exactly the number of
  entries nilo held at that budget**, rather than a budget it cannot express.
  That measures the policy and nothing else, and it is the reading that
  flatters the others most — see the note below.
- One cache a process for the memory readings. Measuring two in one run reads
  the second far too low, because the allocator does not hand the first one's
  memory back and the second `before` is already at the first one's peak.
  quick_cache measured 0.0 bytes an entry that way.

## What is not equal, and cannot be

**Only nilo_cache and freecache take a budget in bytes.** The other five bound
a count of entries, or a weight the caller invents. That is the whole reason
the memory table exists: a count is a bound on a number the caller cannot
convert into memory without knowing the implementation, and every one of these
answers "how much RAM will this cost" with "measure it".

**Both Go ring caches bound only the bytes their values occupy.** The index,
the map from key to offset, sits on top of that budget, unbounded, so their RSS
runs at roughly twice the budget the caller set. `nilo_cache.bytesHeld()` is
the whole of its memory, budget and index together, and the test that says so
is in `store.zig`.

**zigache does not copy the key.** Its `put` stores the slice the caller
passed, and its documentation says the key has to stay valid for as long as it
is in the cache. cache.zig, freecache, bigcache and nilo all copy it. So
zigache's bytes-an-entry excludes the key bytes entirely and should be read as
a floor.

**quick_cache stores its values inline in the table.** For a value this small
that is one cache miss where nilo pays two — a slot that points at a ring
cannot start the second load until the first returns. It is the same trade
nilo's roadmap names and refuses: a table holding values cannot bound its own
memory, which is the property the module exists for.

**go-cache hands back a pointer into memory a garbage collector owns.**
`nilo_cache` hands back a copy, because there is no collector to hold the other
end — which is also why it cannot store a pointer in an entry at all (ADR
0138). On a 512-byte value that is sixteen bytes of string header against a
512-byte `memcpy`, and it is the design rather than the tuning.

**freecache floors at 512 KiB and bigcache at 1 MiB.** Neither can be asked the
hit-rate question at the sizes where an eviction policy actually shows. Any row
below those floors is the same cache measured again, not a smaller one.

**zigache is vendored, with one line changed.** It is pinned to Zig 0.14 and
0.16 removed both `std.Thread.RwLock` and `std.Thread.Mutex`, so its five
algorithms do not compile at all. `zig/vendor/zigache/rwlock.zig` supplies the
lock and nothing else is touched; its header says why a spin lock cannot be
flattering nilo, which spins for the same reason. Its `build.zig` is 0.14's as
well, so `b.dependency` cannot run it and the source is copied rather than
fetched.

**Nothing is pinned to a core.** Eight cores with the load generator on the
same box. The ratios should survive; the absolutes will not. Re-take them
before quoting them anywhere else.
