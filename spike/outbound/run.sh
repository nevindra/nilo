#!/usr/bin/env bash
# Answers the two questions in main.zig's header, and prints nothing it did not
# just measure.
#
#   1. how many lines of policy is an outbound HTTP client
#   2. do its tests run with no engine and no module graph
set -euo pipefail
cd "$(dirname "$0")"

policy=$(awk '/BEGIN POLICY/{f=1;next} /END POLICY/{f=0} f' main.zig)
total=$(printf '%s\n' "$policy" | wc -l)
blank=$(printf '%s\n' "$policy" | grep -c '^[[:space:]]*$' || true)
comment=$(printf '%s\n' "$policy" | grep -c '^[[:space:]]*//' || true)
code=$((total - blank - comment))

echo "== question 1: how much of an outbound client is nilo's =="
echo "  policy, total lines : $total"
echo "  policy, code only   : $code"
echo "  policy, comment     : $comment"
echo "  policy, blank       : $blank"
echo
echo "  std.http.Client, for scale:"
std=$(zig env | sed -n 's/.*\.std_dir = "\(.*\)".*/\1/p')
echo "    $(wc -l < "$std/http/Client.zig") lines in std/http/Client.zig"
echo "    $(wc -l < "$std/crypto/tls/Client.zig") lines in std/crypto/tls/Client.zig"
echo
echo "== question 2: engine-free tests =="
echo "  dependencies declared:"
grep -A1 '\.dependencies' build.zig.zon | tail -n +1 | sed 's/^/    /'
echo "  running the suite under std.Io.Threaded:"
if zig build test 2>&1; then
  echo "    PASS — no zio, no module graph, loopback server and all"
else
  echo "    FAIL"
  exit 1
fi
