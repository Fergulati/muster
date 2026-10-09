#!/usr/bin/env bash
# Lint the QML as the runner would load it (exo-720.1, docs/design/ui-modernization.md
# §4 U0a). `nix build` never evaluates QML: a key the design system lacks binds to
# undefined, a font or colour silently falls back, and a missing type blanks a whole view
# (docs/labbook/qml-errors-are-invisible-to-nix-build.md). Two checks, both against the
# runner's own Qt and Logos design system:
#
#   1. qmllint, gated on the kinds of warning that mean "this does not exist": a missing
#      property, enum entry, type or import. Unqualified access is QML's idiom here and
#      is not gated.
#   2. Theme.palette keys. `palette` is untyped, so qmllint cannot see a key the theme
#      lacks; this reads the theme's own property list and checks every use.
#
# Findings already known are in ui/tests/qmllint-baseline.json. Only NEW ones fail, so
# the gate holds the line while U1 (exo-720.5) pays the baseline down. When a fix removes
# some, `--update` rewrites the baseline (review the diff: it may only shrink).
#
#   scripts/ui-lint.sh [--update]          # MUSTER_BASE_RUNNER (default .run/runner)
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-dev.sh
BASE="${MUSTER_BASE_RUNNER:-.run/runner}"
[ -x "$BASE/bin/muster-ui" ] || { echo "no runner at $BASE (set MUSTER_BASE_RUNNER, or make build — ask first)"; exit 1; }
ui_qt_env "$BASE" || exit 1
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"$QMLLINT_BIN" -I "$LOGOS_QML_LIB" -I "${QML_IMPORT_PATH%%:*}" --json "$OUT/lint.json" ui/src/qml/*.qml >/dev/null 2>&1

python3 - "$OUT/lint.json" "$LOGOS_QML_LIB/Logos/Theme/DarkTheme.qml" ui/tests/qmllint-baseline.json "${1:-}" <<'EOF'
import collections, glob, json, os, re, sys
lint_path, theme_path, baseline_path, mode = sys.argv[1:5]
GATED = {"missing-property", "missing-enum-entry", "missing-type", "unresolved-type",
         "import", "syntax", "unresolved-alias", "incompatible-type", "read-only-property",
         "uncreatable-type", "non-list-property", "duplicate-property-binding"}
found = collections.Counter()
for f in json.load(open(lint_path))["files"]:
    name = os.path.basename(f["filename"])
    for w in f.get("warnings", []):
        if w.get("id") in GATED:
            found[f"{name} · {w['id']} · {w['message']}"] += 1
theme = set(re.findall(r"readonly property \w+ (\w+)\s*:", open(theme_path).read()))
for path in sorted(glob.glob("ui/src/qml/*.qml")):
    for key in re.findall(r"Theme\.palette\.(\w+)", open(path).read()):
        if key not in theme:
            found[f"{os.path.basename(path)} · palette-key · Theme.palette.{key} is not in the theme"] += 1
base = json.load(open(baseline_path)) if os.path.exists(baseline_path) else {}
if mode == "--update":
    json.dump(dict(sorted(found.items())), open(baseline_path, "w"), indent=1)
    open(baseline_path, "a").write("\n")
    print(f"baseline: {sum(found.values())} known finding(s) in {len(found)} kind(s) → {baseline_path}")
    sys.exit(0)
new = {k: n - base.get(k, 0) for k, n in found.items() if n > base.get(k, 0)}
gone = {k: base[k] - found.get(k, 0) for k in base if base[k] > found.get(k, 0)}
for k, n in sorted(new.items()):
    print(f"  NEW  {n}× {k}")
for k, n in sorted(gone.items()):
    print(f"  fixed {n}× {k}")
print(f"{sum(found.values())} finding(s), {sum(base.values())} in the baseline: "
      f"{sum(new.values())} new, {sum(gone.values())} fixed"
      + (" — run scripts/ui-lint.sh --update to shrink the baseline" if gone and not new else ""))
sys.exit(1 if new else 0)
EOF
