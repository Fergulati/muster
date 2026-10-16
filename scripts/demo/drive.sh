#!/usr/bin/env bash
# Drive one X display like a person would, for screen recordings (scripts/demo/README.md).
#   drive.sh <display> glide X Y        move the pointer there smoothly (~0.5 s)
#   drive.sh <display> click X Y [wait] glide there, click, then wait (default 1.2 s)
#   drive.sh <display> type TEXT        type at a human pace
#   drive.sh <display> key KEYS         e.g. ctrl+v
#   drive.sh <display> paste TEXT       put TEXT on that display's clipboard, then ctrl+v
#   drive.sh <display> shot FILE.png    a screenshot (does not show in a recording)
#   drive.sh <display> scroll N [X Y]   N wheel notches down (negative: up)
set -euo pipefail
XDOTOOL=${XDOTOOL:-$(nix build nixpkgs#xdotool --no-link --print-out-paths 2>/dev/null | tail -1)/bin/xdotool}
XCLIP=${XCLIP:-$(nix build nixpkgs#xclip --no-link --print-out-paths 2>/dev/null | tail -1)/bin/xclip}
D=${1:?display}; shift
x() { DISPLAY=$D "$XDOTOOL" "$@"; }
glide() {
  local tx=$1 ty=$2 cx cy
  eval "$(x getmouselocation --shell | grep -E '^(X|Y)=')"; cx=$X; cy=$Y
  for i in $(seq 1 18); do
    # ease in-out: t' = t*t*(3-2t)
    local p; p=$(python3 -c "t=$i/18; print(t*t*(3-2*t))")
    x mousemove "$(python3 -c "print(round($cx+($tx-$cx)*$p))")" "$(python3 -c "print(round($cy+($ty-$cy)*$p))")"
    sleep 0.025
  done
}
case "${1:-}" in
  glide) glide "$2" "$3" ;;
  click) glide "$2" "$3"; sleep 0.15; x click 1; sleep "${4:-1.2}" ;;
  type) x type --delay 55 -- "$2"; sleep 0.4 ;;
  key) x key "$2"; sleep 0.4 ;;
  paste) printf '%s' "$2" | DISPLAY=$D "$XCLIP" -selection clipboard -i; sleep 0.2; x key ctrl+v; sleep 0.6 ;;
  shot) DISPLAY=$D import -window root "$2" ;;
  scroll) n=$2; [ $# -ge 4 ] && glide "$3" "$4"
          if [ "$n" -ge 0 ]; then b=5; else b=4; n=$(( -n )); fi
          for _ in $(seq 1 "$n"); do x click "$b"; sleep 0.06; done; sleep 0.4 ;;
  *) echo "usage: see the header" >&2; exit 2 ;;
esac
