# nilo_cache against go-cache

[patrickmn/go-cache](https://github.com/patrickmn/go-cache) is what a Go
program reaches for when it wants an expiring cache in its own process — a
`map[string]Item` under an `RWMutex`. It is the thing `nilo_cache` is measured
against, and `bench/result/cache.md` is where the readings and what they moved
are written down.

## Run it

```
./run.sh                 # both sides, three interleaved rounds, then memory
```

Go is not in `zig build`'s world, so `run.sh` says so and stops rather than
reporting one side. It looks for `go` on the path and in `~/.local/opt/go/bin`.

## What is held equal

- The same 50,000 keys, **built before the clock starts on both sides**. A key
  formatted inside a timed loop measures the formatter.
- **A separate copy of the key text for lookups.** Go compares two strings by
  checking their data pointers first, so looking up with the object that was
  stored makes the key comparison free — a shortcut the other side has no way
  to take. This is worth about 20% and it is invisible in the source.
- The same values: a flat 24-byte struct, and a 512-byte page.
- The same mix: nine reads to a write.
- Warming per row, and only the Space that row reads. Both of the harness bugs
  this rule exists for produced *higher* numbers.

## What is not equal, and cannot be

go-cache hands back a pointer into memory a garbage collector owns.
`nilo_cache` hands back a copy, because there is no collector to hold the other
end — which is also why it cannot store a pointer in an entry at all
(ADR 0138). On a 512-byte value that is sixteen bytes of string header against
a 512-byte `memcpy`, and it is the design rather than the tuning.

Neither side is pinned, because this box has two cores and nowhere to pin to.
Take the ratios again on a machine with cores to spare before quoting them.
