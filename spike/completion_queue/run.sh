#!/usr/bin/env bash
# One scenario per process, repeated, in all three modes, across every re-arm
# style and both notifier paces.
#
# Three modes because zio#667 needed all three to be understood: Debug aborted
# on an assertion, ReleaseSafe aborted too, and ReleaseFast — which has no such
# assertion — hung instead. A spike that only ran the mode people develop in
# would have called that bug fixed.
#
# `plain` is the zio#673 repro: handing an already-completed completion
# straight back to `submit`, which is the obvious thing to write. It crashes
# everywhere and does so under both paces, so it is only run once.
#
# `reinit` and `recomplete` both dodge that crash, and neither `--paced` nor
# `--blind` can tell them apart — the re-arm window is nanoseconds wide and
# five notifies fired flat out all land before the fiber is scheduled once.
# `--window` has the fiber hold that window open and posts into it on purpose,
# which is where the pair separates: `reinit` throws `pending` away with the
# rest of the handle, `recomplete` keeps it. See `Rearm` and `Pace` in
# main.zig.
#
# Usage: ./run.sh [runs-per-cell]   (default 20)

set -u
cd "$(dirname "$0")"

runs="${1:-20}"

cell() {  # mode, rearm, pace
  ok=0; wrong=0; hang=0; setup=0; crash=0
  for _ in $(seq "$runs"); do
    ./zig-out/bin/cq-spike "$2" "--$3" >/dev/null 2>&1
    case $? in
      0) ok=$((ok+1)) ;;
      1) wrong=$((wrong+1)) ;;
      2) hang=$((hang+1)) ;;
      3) setup=$((setup+1)) ;;
      *) crash=$((crash+1)) ;;   # a signal; an abort is 134
    esac
  done
  printf '%-12s %-11s %-6s ok=%-3d wrong=%-3d hang=%-3d setup=%-3d crash=%-3d (of %d)\n' \
    "$1" "$2" "$3" "$ok" "$wrong" "$hang" "$setup" "$crash" "$runs"
}

printf '%-12s %-11s %-6s %s\n' MODE REARM PACE RESULT
for mode in Debug ReleaseSafe ReleaseFast; do
  if ! zig build -Doptimize="$mode" >/dev/null 2>&1; then
    printf '%-12s %-11s %-6s FAILED TO BUILD\n' "$mode" - -
    continue
  fi

  cell "$mode" plain paced
  for rearm in reinit recomplete; do
    for pace in paced blind window; do
      cell "$mode" "$rearm" "$pace"
    done
  done
done
