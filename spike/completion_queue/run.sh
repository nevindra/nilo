#!/usr/bin/env bash
# One scenario per process, repeated, in all three modes, both re-arm styles.
#
# Three modes because zio#667 needed all three to be understood: Debug aborted
# on an assertion, ReleaseSafe aborted too, and ReleaseFast — which has no such
# assertion — hung instead. A spike that only ran the mode people develop in
# would have called that bug fixed.
#
# `reinit` is the one that should pass. `plain` is the repro: handing an
# already-completed completion straight back to `submit`, which is the obvious
# thing to write. See the `Rearm` doc comment in main.zig.
#
# Usage: ./run.sh [runs-per-mode]   (default 20)

set -u
cd "$(dirname "$0")"

runs="${1:-20}"

printf '%-12s %-8s %s\n' MODE REARM RESULT
for mode in Debug ReleaseSafe ReleaseFast; do
  if ! zig build -Doptimize="$mode" >/dev/null 2>&1; then
    printf '%-12s %-8s FAILED TO BUILD\n' "$mode" -
    continue
  fi

  for rearm in reinit plain; do
    arg=""; [ "$rearm" = plain ] && arg=plain

    ok=0; wrong=0; hang=0; setup=0; crash=0
    for _ in $(seq "$runs"); do
      ./zig-out/bin/cq-spike $arg >/dev/null 2>&1
      case $? in
        0) ok=$((ok+1)) ;;
        1) wrong=$((wrong+1)) ;;
        2) hang=$((hang+1)) ;;
        3) setup=$((setup+1)) ;;
        *) crash=$((crash+1)) ;;   # a signal; an abort is 134
      esac
    done

    printf '%-12s %-8s ok=%-3d wrong=%-3d hang=%-3d setup=%-3d crash=%-3d (of %d)\n' \
      "$mode" "$rearm" "$ok" "$wrong" "$hang" "$setup" "$crash" "$runs"
  done
done
