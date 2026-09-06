#!/usr/bin/env bash
# nilo_cache against go-cache, interleaved, then memory. See README.md.
#
# Interleaved rather than one side then the other: this box has two cores, the
# spread between rounds is wide, and a table built from one run of each has the
# scheduler in it.
set -u
cd "$(dirname "$0")"
root=../..

GO="$(command -v go || true)"
[ -n "$GO" ] || GO="$HOME/.local/opt/go/bin/go"
if [ ! -x "$GO" ]; then
  echo "go was not found, and half a comparison is not one."
  echo "Install Go, or put it on the path, and run this again."
  exit 1
fi

rounds="${1:-3}"
seconds="${2:-3}"

( cd go && "$GO" build -o cache-go . ) || exit 1
( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- 1 1 >/dev/null ) || exit 1

echo "=== what one operation costs ($rounds interleaved rounds, ${seconds}s a row)"
for r in $(seq "$rounds"); do
  echo "--- round $r: nilo_cache"
  ( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- 1 "$seconds" ) 2>&1 | grep -E '^  (get|put|mixed)'
  echo "--- round $r: go-cache"
  ./go/cache-go bench 1 "$seconds" | grep -E '^  (get|put|mixed)'
done

echo
echo "=== what 200,000 entries cost to hold"
( cd "$root" && zig build bench-cache -Doptimize=ReleaseFast -- mem 200000 ) 2>&1 | grep nilo_cache
./go/cache-go mem 200000 | grep go-cache
