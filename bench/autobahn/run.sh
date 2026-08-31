#!/usr/bin/env bash
#
# Drive the Autobahn suite at nilo's WebSocket and print what is not OK.
#
#   bash bench/autobahn/run.sh          # the default spec
#   CASES='6.*' bash bench/autobahn/run.sh   # one family, when chasing a fix
#
# Needs Docker, which is why this is a script rather than a build step: the
# same reason `smoke-tls` needs `-Dnetwork` and is not on `test`.
#
# Reports land in bench/autobahn/reports/ and are not committed. What gets
# written down is the summary, in bench/result/http.md.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
port="${PORT:-9001}"
image="crossbario/autobahn-testsuite:latest"

cd "$root"

echo "==> building the server"
zig build autobahn-server -Doptimize=ReleaseFast

reports="$here/reports"
rm -rf "$reports"
mkdir -p "$reports"

spec="$here/fuzzingclient.json"
if [ -n "${CASES:-}" ]; then
  # A run chasing one family. Written beside the default rather than over it,
  # so the committed spec always says what a full run is.
  spec="$reports/fuzzingclient.json"
  python3 - "$here/fuzzingclient.json" "$spec" "$CASES" <<'PY'
import json, sys
spec = json.load(open(sys.argv[1]))
spec["cases"] = sys.argv[3].split(",")
spec["exclude-cases"] = []
json.dump(spec, open(sys.argv[2], "w"), indent=3)
PY
fi

echo "==> starting nilo on :$port"
PORT="$port" ./zig-out/bin/nilo-autobahn-server &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT

# Bounded rather than a plain sleep: a server that never binds has to fail
# here, saying so, rather than leaving wstest to report 517 broken cases.
for _ in $(seq 1 100); do
  if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then exec 3>&- 3<&-; break; fi
  sleep 0.1
done
if ! (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
  echo "the server never came up on :$port" >&2
  exit 1
fi
exec 3>&- 3<&- || true

echo "==> wstest"
# --network host so the container reaches a loopback server, and --user so the
# reports come back owned by whoever ran this rather than by root.
docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -v "$(dirname "$spec"):/config:ro" \
  -v "$reports:/reports" \
  "$image" \
  wstest -m fuzzingclient -s "/config/$(basename "$spec")"

echo
echo "==> what is not OK"
python3 "$here/summarize.py" "$reports/index.json"
