#!/usr/bin/env bash
# Record an X display losslessly-ish for later editing (scripts/demo/README.md).
#   rec.sh start <display> <out.mkv> [WxH]   # starts ffmpeg x11grab in the background
#   rec.sh stop <out.mkv>                    # stops it cleanly (SIGINT, by its pid file)
set -euo pipefail
FFMPEG=${FFMPEG:-$(nix build nixpkgs#ffmpeg-full.bin --no-link --print-out-paths 2>/dev/null | tail -1)/bin/ffmpeg}
case "${1:-}" in
  start)
    d=${2:?display}; out=${3:?out.mkv}; size=${4:-1600x1000}
    mkdir -p "$(dirname "$out")"
    nohup "$FFMPEG" -hide_banner -loglevel error -y -f x11grab -framerate 30 -video_size "$size" \
      -draw_mouse 1 -i "$d" -c:v libx264 -preset ultrafast -crf 8 -pix_fmt yuv444p "$out" \
      >"$out.log" 2>&1 &
    echo $! > "$out.pid"; sleep 1 ;;
  stop)
    out=${2:?out.mkv}; pid=$(cat "$out.pid")
    kill -INT "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    rm -f "$out.pid" ;;
  *) echo "usage: $0 start <display> <out.mkv> [WxH] | stop <out.mkv>" >&2; exit 2 ;;
esac
