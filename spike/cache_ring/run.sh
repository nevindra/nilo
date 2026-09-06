#!/usr/bin/env bash
# Every table in README.md, in the order they appear there.
#
# `torture` exits non-zero when a reader is handed a value its key did not
# write, so the lock-free rows are expected to fail and the run does not stop
# on them — the failure IS the finding. Read the WRONG column, not the exit
# code.
#
# Two cores on this box, and the first table depends on that: the failure
# needs more threads than cores. Running this where threads <= cores will
# report zero and mean nothing.
set -u
cd "$(dirname "$0")"

zig build -Doptimize=ReleaseFast || exit 1
B=./zig-out/bin/cache-ring-spike

echo "=== is it correct? (writers readers seconds shards locked) ==="
for a in "2 2 5 1 0" "2 2 5 16 0" "1 1 10 1 0" "2 2 5 16 1" "2 2 30 16 1"; do
  echo "--- torture $a"
  $B torture $a 2>&1 | tail -9
done

echo
echo "=== what does the lock cost? (threads seconds shards locked) ==="
for a in "1 3 16 0" "1 3 16 1" "2 3 16 0" "2 3 16 1"; do
  $B bench $a 2>&1 | tail -2
done

echo
echo "=== how does the window degrade? (working-set ring-mb) ==="
for a in "10000 1" "10000 4" "10000 8" "10000 16" "50000 16"; do
  $B hit $a 2>&1 | tail -1
done
