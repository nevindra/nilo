#!/usr/bin/env bash
# Hold N idle connections two ways and read what the difference costs.
#
# The protocol is ADR 0029's, because the number has to be comparable with the
# 8,673 bytes that ADR rejected: idle connections, one fiber each, RSS read at
# steady state, repeated until it stops moving. Repeats are printed rather than
# averaged — a number that wobbles between runs is not a per-connection cost,
# it is noise, and averaging would hide that.
#
# RSS is read from outside the process. A process measuring itself has to
# allocate to do it, which is exactly the thing being counted.
#
# The slot sweep is not decoration. The first run came out at 1,025 bytes per
# connection against a struct of 576, and the missing 449 belongs to neither
# the machinery nor the ring — sweeping the ring is what makes the third payer
# visible. ReleaseSafe is checked once at the default rather than swept: the
# two optimize modes agreed to within 3 bytes, so a full second sweep would
# buy nothing but time.
#
# Usage: ./run.sh [connections] [repeats] [slot-counts]
#        (default 4000, 2, "0 4 16 64")

set -u
cd "$(dirname "$0")"

conns="${1:-4000}"
repeats="${2:-2}"
slot_counts="${3:-0 4 16 64}"
base_port=18800

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; pkill -f mailbox-spike >/dev/null 2>&1' EXIT

# One cell: start a server, fill it, let it settle, read VmRSS in kB.
# Prints the number, or nothing if the run did not get there.
cell() {  # mode, port
  local mode="$1" port="$2" spid cpid i rss

  ./zig-out/bin/mailbox-spike server "$mode" "$port" "$conns" >"$tmp/server.out" 2>&1 &
  spid=$!

  # The client's connect fails outright if nothing is listening yet.
  for i in $(seq 50); do
    ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN && break
    sleep 0.1
  done

  ./zig-out/bin/mailbox-spike client "$port" "$conns" >"$tmp/client.out" 2>&1 &
  cpid=$!

  # `ready` means every fiber is parked, not merely every socket accepted.
  for i in $(seq 600); do
    grep -q '^ready' "$tmp/server.out" 2>/dev/null && break
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.1
  done

  if ! grep -q '^ready' "$tmp/server.out" 2>/dev/null; then
    kill "$spid" "$cpid" 2>/dev/null
    wait "$spid" "$cpid" 2>/dev/null
    return 1
  fi

  # Let the allocator finish whatever it was doing before reading.
  sleep 3
  rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$spid/status" 2>/dev/null)"

  kill "$spid" "$cpid" 2>/dev/null
  wait "$spid" "$cpid" 2>/dev/null

  [ -n "$rss" ] || return 1
  echo "$rss"
}

# `sizeof` is reported by the server itself, so the struct and the number it
# actually costs sit on the same line.
sizeof_for() {  # slots
  ./zig-out/bin/mailbox-spike server mailbox "$1" 0 >"$tmp/sz.out" 2>&1 &
  local p=$! i
  for i in $(seq 30); do
    grep -q '^ready' "$tmp/sz.out" 2>/dev/null && break
    sleep 0.1
  done
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null
  sed -n 's/.*sizeof=\([0-9]*\).*/\1/p' "$tmp/sz.out" | head -1
}

sweep() {  # optimize, slots
  local opt="$1" slots="$2" sz b m
  if ! zig build -Doptimize="$opt" -Dslots="$slots" >/dev/null 2>&1; then
    printf '  %-11s %-6s FAILED TO BUILD\n' "$opt" "$slots"
    return
  fi

  port=$((port + 1)); sz="$(sizeof_for "$port")"

  local r
  for r in $(seq "$repeats"); do
    port=$((port + 1)); b="$(cell baseline "$port")" || b=-
    port=$((port + 1)); m="$(cell mailbox  "$port")" || m=-
    printf '  %-11s %-6s %-8s %-8s %-8s ' "$opt" "$slots" "$sz" "$b" "$m"
    if [ "$b" != - ] && [ "$m" != - ]; then
      printf '%-8s %s\n' "$((m - b))" "$(( (m - b) * 1024 / conns ))"
    else
      printf '%-8s -\n' -
    fi
  done
}

echo "$conns idle connections; RSS in kB, sizeof and per-connection in bytes"
echo
printf '  %-11s %-6s %-8s %-8s %-8s %-8s %s\n' \
  OPTIMIZE SLOTS SIZEOF BASE MAILBOX DELTA PER-CONN

port=$base_port
for slots in $slot_counts; do
  sweep ReleaseFast "$slots"
done
sweep ReleaseSafe 16
