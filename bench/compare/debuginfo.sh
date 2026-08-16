#!/usr/bin/env bash
# Warm release rebuilds with and without debug info, for every compiled
# candidate — because the frameworks here do not agree on the default and a
# single "release" column was comparing two different things.
#
#   Rust    `[profile.release]` leaves `debug` off unless asked
#   Go      always emits DWARF; `-ldflags=-s -w` is the opt-out
#   Zig     always emits DWARF; `-fstrip` is the opt-out
#
# Warm means one source file's contents changed, appended and then restored,
# because Go and Zig hash file contents and `touch` reports a fake 0.0s.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NILO="$(cd "$HERE/../.." && pwd)"
export GOCACHE="$HERE/.gocache"

probe() {  # probe <label> <file> <dir> <command...>
    local label="$1" file="$2" dir="$3"; shift 3
    local backup="/tmp/dbgprobe.$$.bak"
    cp "$file" "$backup"
    printf '\n// warm rebuild probe %s\n' "$RANDOM$RANDOM" >> "$file"
    local start end rc
    start=$(date +%s.%N)
    (cd "$dir" && "$@" >/dev/null 2>&1)
    rc=$?
    end=$(date +%s.%N)
    cp "$backup" "$file"
    rm -f "$backup"
    printf "%-44s %7.2fs%s\n" "$label" "$(echo "$end - $start" | bc)" \
        "$([ $rc -ne 0 ] && printf '   (FAILED rc=%d)' $rc)"
}

echo "======== WARM RELEASE REBUILD, WITH DEBUG INFO ========"
probe "Go net/http"  "$HERE/gonet/main.go"        "$HERE/gonet"    go build -o gonet-bench .
probe "Go Fiber v2"  "$HERE/gofiber/main.go"      "$HERE/gofiber"  go build -o gofiber-bench .
probe "Rust axum"    "$HERE/rustaxum/src/main.rs" "$HERE/rustaxum" env CARGO_PROFILE_RELEASE_DEBUG=true cargo build --release
probe "http.zig"     "$HERE/httpzig/src/main.zig" "$HERE/httpzig"  zig build -Doptimize=ReleaseFast -Dstrip=false
probe "nilo"        "$NILO/src/main.zig"        "$NILO"         zig build -Doptimize=ReleaseFast -Dstrip=false

echo
echo "======== WARM RELEASE REBUILD, WITHOUT DEBUG INFO ========"
probe "Go net/http"  "$HERE/gonet/main.go"        "$HERE/gonet"    go build "-ldflags=-s -w" -o gonet-bench .
probe "Go Fiber v2"  "$HERE/gofiber/main.go"      "$HERE/gofiber"  go build "-ldflags=-s -w" -o gofiber-bench .
probe "Rust axum"    "$HERE/rustaxum/src/main.rs" "$HERE/rustaxum" cargo build --release
probe "http.zig"     "$HERE/httpzig/src/main.zig" "$HERE/httpzig"  zig build -Doptimize=ReleaseFast -Dstrip=true
probe "nilo"        "$NILO/src/main.zig"        "$NILO"         zig build -Doptimize=ReleaseFast

echo
echo "======== WHERE NILO'S RELEASE BUILD GOES ========"
ZIO="zig-pkg/zio-0.17.0-xHbVVI_jJQC3YbgU7JydwAV7MuASkOTd73YqBaKlFFUz/src/zio.zig"
OPTS=$(cd "$NILO" && ls .zig-cache/c/*/options.zig 2>/dev/null | head -1)
if [ -z "$OPTS" ]; then
    echo "  (run 'zig build -Doptimize=ReleaseFast' once first — needs the options file)"
    exit 0
fi
# Note the emit flag goes first: a trailing `-femit-bin` would override
# `-fno-emit-bin` and the frontend-only row would silently measure a full build.
stage() {  # stage <label> <emit-flag> <extra flags...>
    local label="$1" emit="$2"; shift 2
    local cache="/tmp/dbgstage.$$"
    rm -rf "$cache"
    local start end
    start=$(date +%s.%N)
    (cd "$NILO" && zig build-exe "$emit" "$@" \
        --dep nilo -Mroot=src/main.zig \
        --dep zio -Mnilo=src/nilo.zig \
        --dep zio_options -Mzio="$ZIO" -Mzio_options="$OPTS" \
        -lc --cache-dir "$cache" --name nilo-hello >/dev/null 2>&1)
    end=$(date +%s.%N)
    rm -rf "$cache" "/tmp/dbgstage.$$.exe"
    printf "%-44s %7.2fs\n" "$label" "$(echo "$end - $start" | bc)"
}
stage "frontend only: parse and sema" -fno-emit-bin        -OReleaseFast
stage "and LLVM, without debug info"  -femit-bin=/tmp/dbgstage.$$.exe -OReleaseFast -fstrip
stage "and the debug info: the build" -femit-bin=/tmp/dbgstage.$$.exe -OReleaseFast

echo
echo "and to show the linker is not in it:"
LSTART=$(date +%s.%N)
(cd "$NILO" && zig build-obj -OReleaseFast \
    --dep nilo -Mroot=src/main.zig --dep zio -Mnilo=src/nilo.zig \
    --dep zio_options -Mzio="$ZIO" -Mzio_options="$OPTS" \
    -lc --cache-dir /tmp/dbgobj.$$ -femit-bin=/tmp/dbgobj.$$.o >/dev/null 2>&1)
LEND=$(date +%s.%N)
rm -rf /tmp/dbgobj.$$ /tmp/dbgobj.$$.o
printf "%-44s %7.2fs\n" "the same, stopping before the link" "$(echo "$LEND - $LSTART" | bc)"
