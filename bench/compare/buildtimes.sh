#!/usr/bin/env bash
# Cold and warm build times, plus binary size, for every compiled candidate.
#
# "Cold" means the build cache is empty but dependency sources are already
# downloaded — a fresh clone after `go mod download` / `cargo fetch` /
# `zig fetch`. Fetching is not build time.
#
# "Warm" means one source file changed and nothing else.
#
# Go uses a scratch GOCACHE so the user's global cache is left alone.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ZFAST="$(cd "$HERE/../.." && pwd)"
# A scratch cache, so the machine's own Go build cache is left alone.
export GOCACHE="$HERE/.gocache"

t() {  # t <label> <command...>
    local label="$1"; shift
    local start end
    start=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    local rc=$?
    end=$(date +%s.%N)
    printf "%-28s %8.1fs" "$label" "$(echo "$end - $start" | bc)"
    [ $rc -ne 0 ] && printf "   (FAILED rc=%d)" $rc
    printf "\n"
}

size() {  # size <label> <path>
    local label="$1" path="$2"
    if [ ! -f "$path" ]; then printf "%-28s %s\n" "$label" "missing"; return; fi
    local raw stripped
    raw=$(stat -c %s "$path")
    cp "$path" /tmp/sizecheck.$$ && strip /tmp/sizecheck.$$ 2>/dev/null
    stripped=$(stat -c %s /tmp/sizecheck.$$ 2>/dev/null || echo "$raw")
    rm -f /tmp/sizecheck.$$
    printf "%-28s %8.1f MB   stripped %6.1f MB\n" "$label" \
        "$(echo "$raw/1048576" | bc -l)" "$(echo "$stripped/1048576" | bc -l)"
}

echo "======== COLD BUILDS (deps already fetched, build cache empty) ========"

rm -rf "$ZFAST/.zig-cache" "$ZFAST/zig-out"
t "zfast" env -C "$ZFAST" zig build -Doptimize=ReleaseFast

rm -rf "$HERE/httpzig/.zig-cache" "$HERE/httpzig/zig-out"
t "http.zig" env -C "$HERE/httpzig" zig build -Doptimize=ReleaseFast

rm -rf "$GOCACHE"
t "Go net/http" env -C "$HERE/gonet" go build -o gonet-bench .

rm -rf "$GOCACHE"
t "Go Fiber v2" env -C "$HERE/gofiber" go build -o gofiber-bench .

(cd "$HERE/rustaxum" && cargo clean >/dev/null 2>&1)
t "Rust axum (lto, cgu=1)" env -C "$HERE/rustaxum" cargo build --release

echo
echo "======== WARM REBUILDS (one source file touched) ========"

touch "$ZFAST/src/main.zig"
t "zfast" env -C "$ZFAST" zig build -Doptimize=ReleaseFast

touch "$HERE/httpzig/src/main.zig"
t "http.zig" env -C "$HERE/httpzig" zig build -Doptimize=ReleaseFast

touch "$HERE/gonet/main.go"
t "Go net/http" env -C "$HERE/gonet" go build -o gonet-bench .

touch "$HERE/gofiber/main.go"
t "Go Fiber v2" env -C "$HERE/gofiber" go build -o gofiber-bench .

touch "$HERE/rustaxum/src/main.rs"
t "Rust axum (lto, cgu=1)" env -C "$HERE/rustaxum" cargo build --release

echo
echo "======== BINARY SIZE ========"
size "zfast"        "$ZFAST/zig-out/bin/zfast-hello"
size "http.zig"     "$HERE/httpzig/zig-out/bin/httpzig-bench"
size "Go net/http"  "$HERE/gonet/gonet-bench"
size "Go Fiber v2"  "$HERE/gofiber/gofiber-bench"
size "Rust axum"    "$HERE/rustaxum/target/release/rustaxum"
echo "Node / Bun                   no build step; source is shipped as-is"
