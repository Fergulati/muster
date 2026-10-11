#!/usr/bin/env bash
# Does a built runner carry this tree's view (exo-720, docs/runbooks/ui-redesign-review.md
# A1)? `nix build` never evaluates QML, and the builder copies ui/src/qml as it finds it, so
# this reads what the runner actually ships: the qmldir that declares MusterStyle, the
# bundled DM Mono, every icon, and every .qml file byte for byte.
#
#   scripts/check-runner-qml.sh [RUNNER_DIR]       # default .run/runner
#
# PASS: the runner's view is this checkout's. FAIL names each difference; a runner built
# before a QML change fails here until `make build` runs again.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-dev.sh
BASE=${1:-.run/runner}
[ -x "$BASE/bin/muster-ui" ] || { echo "FAIL: no runner at $BASE (make build)"; exit 1; }
read -r _ _ PLUGIN < <(ui_dev_resolve "$BASE") || { echo "FAIL: cannot read $BASE"; exit 1; }
Q=$PLUGIN/qml
bad=0
fail() { echo "FAIL: $*"; bad=1; }
grep -q '^singleton MusterStyle ' "$Q/qmldir" 2>/dev/null || fail "qmldir does not declare the MusterStyle singleton ($Q/qmldir)"
for f in ui/src/qml/fonts/*; do cmp -s "$f" "$Q/fonts/$(basename "$f")" || fail "font missing or different: $(basename "$f")"; done
want=$(ls ui/src/qml/icons | wc -l); have=$(ls "$Q/icons" 2>/dev/null | wc -l)
[ "$want" = "$have" ] || fail "icons: the tree has $want, the runner $have"
n=0
for f in ui/src/qml/*.qml; do
  n=$((n + 1))
  cmp -s "$f" "$Q/$(basename "$f")" || fail "$(basename "$f") is missing or differs from this checkout"
done
[ $bad = 0 ] && echo "PASS: $BASE ships this checkout's view: $n QML files, MusterStyle, DM Mono, $have icons"
exit $bad
