#!/usr/bin/env bash
# nilo_cache against seven other caches in three languages, interleaved, then
# memory, then hit rate. See README.md.
#
# Interleaved rather than one side then the other: a table built from one run of
# each has the scheduler in it, and on this box a session under continuous load
# reads about a quarter below a cold one on *both* sides at once.
set -u
cd "$(dirname "$0")"
root=../..

rounds="${1:-3}"
seconds="${2:-3}"

GO="$(command -v go || true)"
[ -n "$GO" ] || GO="$HOME/.local/opt/go/bin/go"
have_go=0
if [ -x "$GO" ] && ( cd go && "$GO" build -o cache-go . ); then
  have_go=1
else
  echo "note: go was not found or would not build. The Go side is skipped."
fi

have_rust=0
if command -v cargo >/dev/null && ( cd rust && cargo build --release --quiet ); then
  have_rust=1
  RUST=./rust/target/release/cache-rust
else
  echo "note: cargo was not found or would not build. The Rust side is skipped."
fi

have_zig=0
if ( cd zig && zig build -Doptimize=ReleaseFast ); then
  have_zig=1
  ZIG=./zig/zig-out/bin/cache-zig
else
  echo "note: the Zig side would not build and is skipped."
fi

( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- 1 1 >/dev/null ) || exit 1

for threads in 1 8; do
  echo
  echo "=== what one operation costs, $threads thread(s) ($rounds interleaved rounds, ${seconds}s a row)"
  for r in $(seq "$rounds"); do
    echo "--- round $r: nilo_cache"
    ( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- "$threads" "$seconds" ) 2>&1 |
      grep -E '^  (get|put|mixed)'
    if [ "$have_go" = 1 ]; then
      echo "--- round $r: go-cache, freecache, bigcache"
      ./go/cache-go bench "$threads" "$seconds" | grep -E '^  (get|put|mixed)'
      ./go/cache-go others "$threads" "$seconds" | grep -E '^  (freecache|bigcache)'
    fi
    [ "$have_rust" = 1 ] && { echo "--- round $r: moka, quick_cache"; $RUST bench "$threads" "$seconds"; }
    [ "$have_zig" = 1 ] && { echo "--- round $r: cache.zig, zigache"; $ZIG bench "$threads" "$seconds"; }
  done
done

echo
echo "=== what 200,000 entries cost to hold"
# One cache a process throughout. Two in one run reads the second far too low:
# the allocator does not hand the first one's memory back, so the second
# `before` is already at the first one's peak. quick_cache read 0.0 that way.
( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- mem 200000 ) 2>&1 | grep nilo_cache
if [ "$have_go" = 1 ]; then
  ./go/cache-go mem 200000 | grep go-cache
  ./go/cache-go othersmem 200000 | grep -E 'freecache|bigcache'
fi
if [ "$have_rust" = 1 ]; then
  for i in 0 1; do $RUST mem 200000 $i; done
fi
if [ "$have_zig" = 1 ]; then
  for i in 0 1 2 3; do $ZIG mem 200000 $i; done
fi

echo
echo "=== hit rate, Zipf 0.99, read-through"
( cd "$root" && zig build bench-cache-hitrate -Doptimize=ReleaseFast ) 2>&1 | grep -E '^ '
[ "$have_go" = 1 ] && ./go/cache-go hitrate
[ "$have_rust" = 1 ] && $RUST hitrate
[ "$have_zig" = 1 ] && $ZIG hitrate
