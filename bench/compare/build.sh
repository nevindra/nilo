#!/usr/bin/env bash
# Build every candidate, including zfast itself.
#
# Node and Bun have no build step. Anything whose toolchain is missing is
# skipped with a note rather than failing the run — drive.py will report it as
# "DID NOT START" if you ask for it anyway.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZFAST="$(cd "$HERE/../.." && pwd)"
export GOCACHE="$HERE/.gocache"

ok=0; skipped=0

have() { command -v "$1" >/dev/null 2>&1; }

step() {  # step <label> <tool> <dir> <command...>
    local label="$1" tool="$2" dir="$3"; shift 3
    if ! have "$tool"; then
        printf "%-16s skipped — no %s on PATH\n" "$label" "$tool"
        skipped=$((skipped + 1))
        return
    fi
    if (cd "$dir" && "$@" >/dev/null 2>&1); then
        printf "%-16s ok\n" "$label"
        ok=$((ok + 1))
    else
        printf "%-16s FAILED — rerun by hand in %s\n" "$label" "$dir"
    fi
}

step "zfast"     zig   "$ZFAST"          zig build -Doptimize=ReleaseFast
step "http.zig"  zig   "$HERE/httpzig"   zig build -Doptimize=ReleaseFast
step "Go net/http" go  "$HERE/gonet"     go build -o gonet-bench .
step "Go Fiber"  go    "$HERE/gofiber"   go build -o gofiber-bench .
step "Rust axum" cargo "$HERE/rustaxum"  cargo build --release

for rt in node bun; do
    if have $rt; then printf "%-16s ok (no build step)\n" "$rt"; ok=$((ok + 1))
    else printf "%-16s skipped — not on PATH\n" "$rt"; skipped=$((skipped + 1)); fi
done

echo
echo "$ok ready, $skipped skipped"
have wrk || echo "WARNING: wrk is not on PATH — drive.py needs it"
