#!/usr/bin/env bash
# nilo's benchmark script — in the repo since stage 1 (see docs/plan.md)
# so that when a measuring machine turns up it is one command away instead
# of a new project.
#
# Metrics (docs/plan.md):
#   Primary   : requests/second AND p99, on a routed GET with a path param
#               returning ~1KB of JSON, keep-alive, no pipelining.
#   Secondary : memory per idle connection (not measured by this script).
#
# The target is the example route in src/main.zig: GET /users/:id returning
# ~1KB of JSON. Start the server first with
# `zig build -Doptimize=ReleaseFast` then `./zig-out/bin/nilo-hello`.
#
# The load test for fail-function message leakage lives separately in
# bench/mixed.lua (see ADR 0007) — that one tests correctness, not speed.

set -euo pipefail

URL="${1:-http://127.0.0.1:8787/users/42}"
DURATION="${DURATION:-30s}"
CONNECTIONS="${CONNECTIONS:-64}"
THREADS="${THREADS:-4}"

if command -v wrk >/dev/null; then
    # wrk uses keep-alive by default and does not pipeline.
    exec wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency "$URL"
elif command -v oha >/dev/null; then
    exec oha -z "$DURATION" -c "$CONNECTIONS" --no-tui "$URL"
else
    echo "needs wrk or oha. to install, e.g.: sudo apt install wrk" >&2
    exit 1
fi
