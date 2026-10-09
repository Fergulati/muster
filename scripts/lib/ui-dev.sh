# shellcheck shell=bash
# A dev runner: an existing runner's compiled code with THIS tree's QML (exo-720.2).
# Sourced by scripts/ui-screenshot.sh; never executed.
#
# The runner loads its view from a plugin directory on disk (qml/Main.qml beside
# muster_ui_plugin.so). So a QML-only change needs no `make build`: copy the runner's
# plugin dir as symlinks, put this tree's ui/src/qml in its qml/, and launch
# logos-standalone-app with the runner's own modules dir. Valid only while the runner's
# compiled half (the .rep, the C++ backend, muster_module) matches this tree; the caller
# checks that (ui_dev_check). CLAUDE.md: reuse a runner when the change touches nothing
# compiled into it.
#
#   ui_dev_runner <base runner dir> <out dir> [view.qml]
#     → <out dir>/bin/muster-ui, a drop-in $RUNNER. With a view (a file under
#       ui/tests/gallery/), that file is the plugin's view instead of Main.qml:
#       Recorder.qml wraps Main.qml and writes snapshots to <out dir>/plugin/qml/snapshots/;
#       Census.qml shows each design-system control (exo-720.1).

# ui_dev_resolve <base runner dir> — echo "<standalone app> <modules dir> <plugin dir>",
# read from the runner's own wrapper chain (bin/muster-ui → run-logos-standalone-ui).
ui_dev_resolve() {
  local base="$1" w inner
  w="$base/bin/muster-ui"
  [ -f "$w" ] || { echo "ui_dev_resolve: no $w" >&2; return 1; }
  inner=$(grep -o '/nix/store/[^ "]*/bin/run-logos-standalone-ui' "$w" | head -1)
  [ -n "$inner" ] || inner="$w"
  python3 - "$inner" <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r'exec\s+(\S+/logos-standalone-app)\s+--modules-dir\s+"([^"]+)"\s+"([^"]+)"', t)
if not m:
    sys.exit("ui_dev_resolve: cannot read the standalone app line from " + sys.argv[1])
print(m.group(1), m.group(2), m.group(3))
EOF
}

ui_dev_runner() {
  local base out view="${3:-}" app mods plugin root f
  base="$(realpath "$1")"; out="$(realpath -m "$2")"
  root="$(git rev-parse --show-toplevel)"
  read -r app mods plugin < <(ui_dev_resolve "$base") || return 1
  rm -rf "$out/plugin" "$out/bin"
  mkdir -p "$out/plugin/qml/snapshots" "$out/plugin/qml/census" "$out/bin"
  for f in "$plugin"/*; do
    case "$(basename "$f")" in
      qml|metadata.json) ;;
      *) ln -s "$f" "$out/plugin/$(basename "$f")" ;;
    esac
  done
  # the builder's generated qmldir (one per-module URI, mkLogosQmlModule), then this tree's QML
  cp "$plugin/qml/qmldir" "$out/plugin/qml/qmldir"
  for f in "$root"/ui/src/qml/*.qml; do ln -s "$f" "$out/plugin/qml/$(basename "$f")"; done
  if [ -n "$view" ]; then
    ln -s "$(realpath "$view")" "$out/plugin/qml/$(basename "$view")"
    ln -s "$root/ui/tests/gallery/FakeBackend.qml" "$out/plugin/qml/FakeBackend.qml"
    python3 - "$plugin/metadata.json" "$out/plugin/metadata.json" "qml/$(basename "$view")" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1])); m["view"] = sys.argv[3]
json.dump(m, open(sys.argv[2], "w"), indent=2)
EOF
  else
    cp "$plugin/metadata.json" "$out/plugin/metadata.json"
  fi
  cat >"$out/bin/muster-ui" <<EOF
#!/usr/bin/env bash
# dev runner (scripts/lib/ui-dev.sh): $base's compiled code, the QML of $root
export QML_XHR_ALLOW_FILE_WRITE=1
exec "$app" --modules-dir "$mods" "$out/plugin" "\$@"
EOF
  chmod +x "$out/bin/muster-ui"
}

# ui_dev_check <base runner dir> — fail when the runner's compiled half is not this
# tree's: its .rep differs (the view contract) or its shipped QML predates HEAD's in a
# way the backend would not match. The QML itself may differ — that is the point.
ui_dev_check() {
  local base="$1" app mods plugin root
  root="$(git rev-parse --show-toplevel)"
  read -r app mods plugin < <(ui_dev_resolve "$base") || return 1
  local rep
  rep=$(find "$mods" "$plugin" -name 'muster_ui.rep' 2>/dev/null | head -1)
  if [ -n "$rep" ] && ! cmp -s "$rep" "$root/ui/src/muster_ui.rep"; then
    echo "ui_dev_check: $base was built from another view contract (muster_ui.rep differs); make build" >&2
    return 1
  fi
  return 0
}

# ui_qt_env <base runner dir> — export what a bare `qml` / `qmllint` needs to see the QML
# as the runner does: the runner's own Qt 6 (qtdeclarative, qtbase plugins, qtsvg) and its
# Logos design system, all read from the runner's closure. Sets QML_BIN, QMLLINT_BIN,
# LOGOS_QML_LIB (the directory holding Logos/Theme, Logos/Controls) and LOGOS_MESA_EGL
# (the closure's Mesa EGL vendor file, for GL on Xvfb; empty if the closure has none).
ui_qt_env() {
  local base_store app lib qd="" qb="" qs="" p
  LOGOS_MESA_EGL=""
  base_store=$(realpath "$1")
  read -r app _ _ < <(ui_dev_resolve "$1") || return 1
  lib="$(dirname "$(dirname "$app")")/lib"
  for p in $(nix-store -qR "$base_store"); do
    case "$p" in
      *-qtdeclarative-6.*) qd="$p" ;;
      *-qtbase-6.*-only-plugins*) ;;
      *-qtbase-6.*) qb="$p" ;;
      *-qtsvg-6.*) qs="$p" ;;
      *-mesa-2[0-9].*) [ -f "$p/share/glvnd/egl_vendor.d/50_mesa.json" ] && LOGOS_MESA_EGL="$p/share/glvnd/egl_vendor.d/50_mesa.json" ;;
    esac
  done
  if [ -z "$qd" ] || [ -z "$qb" ] || [ ! -d "$lib/Logos" ]; then
    echo "ui_qt_env: cannot find Qt / Logos.Theme in $1's closure" >&2; return 1
  fi
  QML_BIN="$qd/bin/qml"; QMLLINT_BIN="$qd/bin/qmllint"; LOGOS_QML_LIB="$lib"
  export QML_IMPORT_PATH="$qd/lib/qt-6/qml:$lib"
  export QT_PLUGIN_PATH="$qb/lib/qt-6/plugins${qs:+:$qs/lib/qt-6/plugins}"
  export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1
  export QML_XHR_ALLOW_FILE_READ=1
}
