#!/usr/bin/env bash
# Build every object-store candidate, including nilo's.
#
# Separate from bench/compare/build.sh on purpose: these candidates need an
# object store to be up before they will even start, so building them is not
# part of "build the HTTP comparison". Anything whose toolchain is missing is
# skipped with a note rather than failing the run — drive.py will report it as
# "DID NOT START" if you ask for it anyway.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NILO="$(cd "$HERE/../.." && pwd)"
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

step "nilo"      zig   "$NILO"        zig build -Doptimize=ReleaseFast bench-s3-server
step "Go SDK"    go    "$HERE/go"     go build -o go-bench .
step "Rust SDK"  cargo "$HERE/rust"   cargo build --release

if have bun; then printf "%-16s ok (no build step)\n" "Bun"; ok=$((ok + 1))
else printf "%-16s skipped — not on PATH\n" "Bun"; skipped=$((skipped + 1)); fi

echo
echo "$ok ready, $skipped skipped"
have wrk || echo "WARNING: wrk is not on PATH — drive.py needs it"
have docker || echo "WARNING: no docker — drive.py cannot pin the store to its own cores"

# The store, and the objects. Without these every candidate refuses to start,
# which is deliberate: a benchmark against an empty bucket would run.
if ! curl -fsS -o /dev/null "${S3_ENDPOINT:-http://127.0.0.1:9100}/minio/health/live" 2>/dev/null; then
    cat <<'EOF'

No object store answering. Start one and seed it:

  docker run -d --name nilo-s3-minio -p 9100:9000 \
    -e MINIO_ROOT_USER=niloadmin -e MINIO_ROOT_PASSWORD=nilosecret123 \
    quay.io/minio/minio server /data
  python3 ../s3_setup.py
EOF
fi
