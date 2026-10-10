#!/usr/bin/env bash
# Look at the UI without a screen (exo-720.2, docs/design/ui-modernization.md §4 U0b).
# `nix build` never evaluates QML, and an offscreen runner never draws it
# (docs/labbook/qml-errors-are-invisible-to-nix-build.md), so this is how a change to the
# QML is SEEN: screenshots at three sizes, and a pixel diff between two sets.
#
#   scripts/ui-screenshot.sh gallery [--out DIR] [--sizes WxH,…] [fixture …]
#       The real Main.qml against ui/tests/gallery/FakeBackend.qml, one PNG per fixture
#       per size (ui/tests/gallery/fixtures/*.json; all of them by default). The runner's
#       own Qt 6.9.2 and Logos design system, on a private Xvfb display with Mesa GL; no
#       module, no network. Fast, deterministic: the baseline every UI slice is judged
#       against.
#
#   scripts/ui-screenshot.sh record <self-test> [VAR=value …]
#       Runs an existing self-test (e.g. scripts/split-self-test.sh) through a dev runner
#       whose view records every backend PROP the module returns (Recorder.qml), on an
#       Xvfb display, where the QML is instantiated. Snapshots land in
#       .run/screens/record/<test>-<time>/; a fixture's "snapshot" names one of them,
#       copied into ui/tests/gallery/fixtures/data/. Real module output, never hand-typed.
#
#   scripts/ui-screenshot.sh runner [--size WxH] [--wait S] [VAR=value …]
#       This tree's QML in the real runner, a fresh profile, on Xvfb (GL via the host's
#       Mesa); a capture of the display after it settles. The real backend, no fixtures.
#
#   scripts/ui-screenshot.sh compare DIR_A DIR_B
#       Pixel-diffs every PNG the two sets share; exit 1 if any differs (U0c: a refactor
#       that moves code only must leave every picture identical).
#
# The base runner (MUSTER_BASE_RUNNER, default .run/runner) supplies the compiled half:
# Qt, the design system, the C++ backend, muster_module. Reuse one whose .rep matches
# this tree (CLAUDE.md: a runner build costs > 7 GB; ask before `make build`).
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
. scripts/lib/ui-dev.sh

BASE="${MUSTER_BASE_RUNNER:-.run/runner}"
SIZES_DEFAULT="1024x700,1440x900,1920x1080"

need_base() {
  [ -x "$BASE/bin/muster-ui" ] || { echo "no runner at $BASE (set MUSTER_BASE_RUNNER, or make build — ask first)"; exit 1; }
}

qt_env() { ui_qt_env "$BASE" || exit 1; }

cmd_gallery() {
  local out=".run/screens/gallery" sizes="$SIZES_DEFAULT" fixtures=() f s w h name log rc=0 warns
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) out="$2"; shift 2 ;;
      --sizes) sizes="$2"; shift 2 ;;
      *) fixtures+=("$1"); shift ;;
    esac
  done
  [ ${#fixtures[@]} -gt 0 ] || fixtures=(ui/tests/gallery/fixtures/*.json)
  need_base; qt_env
  python3 ui/tools/gen-fake-backend.py --check || exit 1
  mkdir -p "$out"
  # Xvfb + GL (Mesa), not offscreen + software: Logos icons tint through MultiEffect, a
  # shader effect the software renderer draws as nothing
  # (docs/labbook/screenshots-of-the-qml-that-hold-still.md)
  local XV disp
  XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
  [ -x "$XV" ] || { echo "needs Xvfb (nix build nixpkgs#xvfb-run)"; exit 1; }
  for disp in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$disp" ] || break; done
  setsid bash -c 'echo $$ >"$1"; exec "$2" ":$3" -screen 0 1920x1080x24 -nolisten tcp' _ "$out/xvfb.pid" "$XV" "$disp" >/dev/null 2>&1 &
  XVFB_PIDFILE="$out/xvfb.pid"
  trap 'pkill -9 -s "$(cat "$XVFB_PIDFILE" 2>/dev/null)" 2>/dev/null' EXIT
  sleep 1
  export DISPLAY=":$disp" QT_QPA_PLATFORM=xcb
  unset WAYLAND_DISPLAY QT_QUICK_BACKEND
  # Nix's libglvnd finds no GL vendor on a non-NixOS host: name the runner's own Mesa
  [ -n "$LOGOS_MESA_EGL" ] && export __EGL_VENDOR_LIBRARY_FILENAMES="$LOGOS_MESA_EGL"
  # one llvmpipe thread: multithreaded rasterising antialiases a few pixels differently run
  # to run, and compare must see a pure code move as identical (U0c)
  export LP_NUM_THREADS=1
  # a fixed hash seed: the glyph cache fills in hash order, which otherwise varies per process
  export QT_HASH_SEED=0
  [ -n "${GALLERY_BACKEND:-}" ] && export QT_QUICK_BACKEND="$GALLERY_BACKEND"
  : >"$out/warnings.txt"
  # a private config dir: a fixture that toggles a stored preference (the sidebar's rail)
  # must not leak it into the next run
  export XDG_CONFIG_HOME="$out/.config"
  local fsizes
  for f in "${fixtures[@]}"; do
    name=$(basename "$f" .json)
    rm -rf "$XDG_CONFIG_HOME"
    # a fixture may name its own sizes (a narrow window, for the drawer)
    fsizes=$(python3 -c "import json,sys; print(','.join(json.load(open(sys.argv[1])).get('sizes', [])))" "$f")
    for s in $(echo "${fsizes:-$sizes}" | tr , ' '); do
      w=${s%x*}; h=${s#*x}
      log="$out/$name-$s.log"
      timeout 60 "$QML_BIN" ui/tests/gallery/Gallery.qml -- "$(realpath "$f")" "$(realpath -m "$out")/$name-$s" "$w" "$h" >"$log" 2>&1
      if grep -q "GALLERY-DONE" "$log"; then
        warns=$(grep -c '\.qml:[0-9]' "$log")
        echo "  ok   $name $s ($(grep -c GALLERY-SHOT "$log") shot(s), $warns QML warning(s))"
        grep '\.qml:[0-9]' "$log" | sed "s|file://$ROOT/||; s|^|$name $s: |" >>"$out/warnings.txt"
      else
        echo "  FAIL $name $s — $(grep -v libEGL "$log" | grep -m1 -E 'GALLERY-ERROR|Error|error|No such' || echo 'no GALLERY-DONE')"
        rc=1
      fi
    done
  done
  echo "screenshots: $out  (QML warnings: $out/warnings.txt)"
  return $rc
}

cmd_compare() {
  local a="$1" b="$2" f n=0 bad=0 IM
  IM=$(ls -d /nix/store/*-imagemagick-7*/bin 2>/dev/null | head -1)
  [ -n "$IM" ] || { echo "needs ImageMagick (nix build nixpkgs#imagemagick)"; exit 1; }
  for f in "$a"/*.png; do
    [ -f "$b/$(basename "$f")" ] || continue
    n=$((n+1))
    if [ "$("$IM/magick" compare -metric AE "$f" "$b/$(basename "$f")" null: 2>&1 | cut -d' ' -f1)" != "0" ]; then
      echo "  differs: $(basename "$f")"; bad=$((bad+1))
    fi
  done
  echo "$n compared, $bad differ"
  [ "$n" -gt 0 ] && [ "$bad" -eq 0 ]
}

cmd_record() {
  local test="$1"; shift
  local XV disp out stamp dev
  need_base
  XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
  [ -x "$XV" ] || { echo "needs Xvfb (nix build nixpkgs#xvfb-run)"; exit 1; }
  ui_dev_check "$BASE" || exit 1
  dev="$ROOT/.run/dev-record"
  ui_dev_runner "$BASE" "$dev" ui/tests/gallery/Recorder.qml || exit 1
  for disp in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$disp" ] || break; done
  stamp=$(date +%Y%m%d-%H%M%S)
  out="$ROOT/.run/screens/record/$(basename "$test" .sh)-$stamp"
  mkdir -p "$out"
  # Xvfb in its own session, its pid (= its session id) written before exec
  setsid bash -c 'echo $$ >"$1"; exec "$2" ":$3" -screen 0 1920x1080x24 -nolisten tcp' _ "$out/xvfb.pid" "$XV" "$disp" >/dev/null 2>&1 &
  sleep 1
  XVFB_PIDFILE="$out/xvfb.pid"
  trap 'pkill -9 -s "$(cat "$XVFB_PIDFILE" 2>/dev/null)" 2>/dev/null' EXIT
  echo "recording $test on :$disp → $out"
  env -u WAYLAND_DISPLAY DISPLAY=":$disp" MUSTER_QPA=xcb QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 \
      MUSTER_RUNNER="$dev/bin/muster-ui" "$@" "$test"
  local rc=$?
  cp "$dev"/plugin/qml/snapshots/*.json "$out"/ 2>/dev/null
  echo "$test exited $rc; $(ls "$out"/*.json 2>/dev/null | wc -l) snapshot(s) in $out"
  return $rc
}

# census: Census.qml as a dev runner's view on Xvfb; one PNG of the X display per phase
cmd_census() {
  local XV IM disp out dev n ud
  need_base
  XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
  IM=$(ls -d /nix/store/*-imagemagick-7*/bin 2>/dev/null | head -1)
  [ -x "$XV" ] && [ -n "$IM" ] || { echo "needs Xvfb and ImageMagick"; exit 1; }
  dev="$ROOT/.run/dev-census"; out="$ROOT/.run/screens/census"
  ui_dev_runner "$BASE" "$dev" ui/tests/gallery/Census.qml || exit 1
  rm -rf "$out"; mkdir -p "$out"
  for disp in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$disp" ] || break; done
  setsid bash -c 'echo $$ >"$1"; exec "$2" ":$3" -screen 0 1280x800x24 -nolisten tcp' _ "$out/xvfb.pid" "$XV" "$disp" >/dev/null 2>&1 &
  sleep 1
  ud=$(mktemp -d -p "$ROOT/.run")
  setsid bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$out/runner.pid" \
      env -u WAYLAND_DISPLAY DISPLAY=":$disp" QT_QPA_PLATFORM=xcb QT_QUICK_BACKEND="${CENSUS_BACKEND-software}" \
      QT_FORCE_STDERR_LOGGING=1 "$dev/bin/muster-ui" --user-dir "$ud" >"$out/runner.log" 2>&1 &
  CENSUS_PIDFILES="$out/runner.pid $out/xvfb.pid"
  trap 'for f in $CENSUS_PIDFILES; do pkill -9 -s "$(cat "$f" 2>/dev/null)" 2>/dev/null; done' EXIT
  for n in 0 1 2 3; do
    for _ in $(seq 1 120); do [ -f "$dev/plugin/qml/census/phase-$n.json" ] && break; sleep 0.25; done
    [ -f "$dev/plugin/qml/census/phase-$n.json" ] || { echo "  phase $n never came (see $out/runner.log)"; return 1; }
    "$IM/import" -display ":$disp" -window root "$out/phase-$n.png"
    cp "$dev/plugin/qml/census/phase-$n.json" "$out/"
  done
  python3 -c "import json,sys; c=json.load(open('$out/phase-3.json'))['created']; print('  created:', ' '.join(sorted(k for k,v in c.items() if v))); m=[k for k,v in c.items() if not v]; print('  NOT created:', m) if m else None"
  echo "  QML warnings: $(grep -c '\.qml:[0-9]' "$out/runner.log")  ·  screenshots: $out"
}

# runner: this tree's QML in the real runner (a dev runner), a fresh profile, on Xvfb; the X
# display captured after it settles. What the gallery cannot show: the real backend.
cmd_runner() {
  local size="1440x900" wait=15 XV IM XDO disp out dev ud w h
  while [ $# -gt 0 ]; do
    case "$1" in
      --size) size="$2"; shift 2 ;;
      --wait) wait="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  need_base
  XV=$(ls -d /nix/store/*-xvfb-21*/bin 2>/dev/null | head -1)/Xvfb
  IM=$(ls -d /nix/store/*-imagemagick-7*/bin 2>/dev/null | head -1)
  XDO=$(ls -d /nix/store/*-xdotool-*/bin 2>/dev/null | head -1)/xdotool
  [ -x "$XV" ] && [ -n "$IM" ] && [ -x "$XDO" ] || { echo "needs Xvfb, ImageMagick and xdotool"; exit 1; }
  w=${size%x*}; h=${size#*x}
  dev="$ROOT/.run/dev-runner"; out="$ROOT/.run/screens/runner"
  ui_dev_runner "$BASE" "$dev" || exit 1
  mkdir -p "$out"
  for disp in $(seq 140 199); do [ -e "/tmp/.X11-unix/X$disp" ] || break; done
  setsid bash -c 'echo $$ >"$1"; exec "$2" ":$3" -screen 0 "$4x$5x24" -nolisten tcp' _ "$out/xvfb.pid" "$XV" "$disp" "$w" "$h" >/dev/null 2>&1 &
  sleep 1
  ud=$(mktemp -d -p "$ROOT/.run")
  setsid bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$out/runner.pid" \
      env -u WAYLAND_DISPLAY DISPLAY=":$disp" QT_QPA_PLATFORM=xcb QT_FORCE_STDERR_LOGGING=1 \
      XDG_CONFIG_HOME="$ud/.config" "$@" "$dev/bin/muster-ui" --user-dir "$ud" >"$out/runner.log" 2>&1 &
  RUNNER_PIDFILES="$out/runner.pid $out/xvfb.pid"
  trap 'for f in $RUNNER_PIDFILES; do pkill -9 -s "$(cat "$f" 2>/dev/null)" 2>/dev/null; done' EXIT
  sleep 4
  DISPLAY=":$disp" "$XDO" search --onlyvisible --name . windowsize %@ "$w" "$h" >/dev/null 2>&1
  sleep "$wait"
  "$IM/import" -display ":$disp" -window root "$out/runner-$size.png"
  echo "  $out/runner-$size.png  ·  QML lines in its log: $(grep -cE '\.qml:[0-9]+' "$out/runner.log")"
}

case "${1:-}" in
  census)  shift; cmd_census "$@" ;;
  runner)  shift; cmd_runner "$@" ;;
  gallery) shift; cmd_gallery "$@" ;;
  record)  shift; [ $# -ge 1 ] || { echo "usage: $0 record <self-test> [VAR=value …]"; exit 2; }; cmd_record "$@" ;;
  compare) shift; [ $# -eq 2 ] || { echo "usage: $0 compare DIR_A DIR_B"; exit 2; }; cmd_compare "$@" ;;
  *) sed -n '2,30p' "$0"; exit 2 ;;
esac
