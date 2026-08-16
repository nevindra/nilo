#!/usr/bin/env bash
# Warm rebuild: change one source file's CONTENT and rebuild.
#
# Appending a comment rather than touching, because Go and Zig hash file
# contents — `touch` alone is a no-op for them and reports a fake 0.0s.
# Every file is restored afterwards.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NILO="$(cd "$HERE/../.." && pwd)"
export GOCACHE="$HERE/.gocache"

probe() {  # probe <label> <file> <dir> <command...>
    local label="$1" file="$2" dir="$3"; shift 3
    local backup="/tmp/warmprobe.$$.bak"
    cp "$file" "$backup"
    printf '\n// warm rebuild probe %s\n' "$RANDOM$RANDOM" >> "$file"
    local start end
    start=$(date +%s.%N)
    (cd "$dir" && "$@" >/dev/null 2>&1)
    local rc=$?
    end=$(date +%s.%N)
    cp "$backup" "$file"   # restore content and refresh mtime
    rm -f "$backup"
    printf "%-28s %8.1fs" "$label" "$(echo "$end - $start" | bc)"
    [ $rc -ne 0 ] && printf "   (FAILED rc=%d)" $rc
    printf "\n"
}

echo "======== WARM REBUILDS (one source file's content changed) ========"
probe "nilo"        "$NILO/src/main.zig"          "$NILO"          zig build -Doptimize=ReleaseFast
probe "http.zig"     "$HERE/httpzig/src/main.zig"   "$HERE/httpzig"   zig build -Doptimize=ReleaseFast
probe "Go net/http"  "$HERE/gonet/main.go"          "$HERE/gonet"     go build -o gonet-bench .
probe "Go Fiber v2"  "$HERE/gofiber/main.go"        "$HERE/gofiber"   go build -o gofiber-bench .
probe "Rust axum"    "$HERE/rustaxum/src/main.rs"   "$HERE/rustaxum"  cargo build --release

echo
echo "restoring nilo's working tree:"
(cd "$NILO" && git status --short src/main.zig && git checkout -- src/main.zig 2>/dev/null; git status --short src/main.zig)
echo "  (empty above means src/main.zig is back to its committed state)"
