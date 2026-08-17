#!/usr/bin/env bash
# Everything this spike measures, in the order the write-up reads.
#
#   ./run.sh
#
# Nothing here is a timing. Every figure is a counter — resident bytes, or
# syscalls — because the box this was written on is a two-core shared vCPU
# where a throughput number would be about the neighbours. Counters are the
# part of `bench/result/sql.md`'s method that survives a machine like that.
set -euo pipefail
cd "$(dirname "$0")"

rm -f /tmp/nilo-sqlite-facts.db* /tmp/nilo-sqlite-ro.db* /tmp/nilo-sqlite-pool.db*

zig build -Doptimize=ReleaseFast

echo "== the seven checks, and the pool's memory =="
./zig-out/bin/sqlite-facts

echo
echo "== what a smaller page cache costs, in reads =="
echo "-- 5,000 primary-key lookups over 200 hot rows"
for k in 2000 512 128 32 8; do
    printf '   cache -%-5s KiB  ' "$k"
    SCAN_POINTS=1 SCAN_CACHE_KIB=$k strace -c -e trace=pread64 ./zig-out/bin/sqlite-facts 2>&1 |
        awk '/pread64/{printf "pread64=%-7s", $4}'
    echo
done

echo "-- three full scans of a 2.9 MB table"
for k in 2000 512 128 32; do
    printf '   cache -%-5s KiB  ' "$k"
    SCAN_CACHE_KIB=$k strace -c -e trace=pread64 ./zig-out/bin/sqlite-facts 2>&1 |
        awk '/pread64/{printf "pread64=%-7s", $4}'
    echo
done

rm -f /tmp/nilo-sqlite-facts.db* /tmp/nilo-sqlite-ro.db* /tmp/nilo-sqlite-pool.db*
