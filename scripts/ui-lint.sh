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

# 1b. The same QML against the design system Basecamp ships (infra/basecamp/release-*.env):
#     Basecamp resolves every plugin's Logos.* imports to its own compiled copy, an older
#     release than the runner's, so a property only the newer one has fails the whole view
#     there and nowhere else (2026-10-12: Launch did nothing). Fetched once into a cache.
. infra/basecamp/release-0.3.2.env
DS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/muster/logos-design-system-$BASECAMP_DESIGN_SYSTEM_REV"
if [ ! -f "$DS_CACHE/src/qml/Logos/Controls/qmldir" ]; then
  rm -rf "$DS_CACHE"; mkdir -p "$(dirname "$DS_CACHE")"
  { git clone -q https://github.com/logos-co/logos-design-system "$DS_CACHE" &&
    git -C "$DS_CACHE" checkout -q "$BASECAMP_DESIGN_SYSTEM_REV"; } >/dev/null 2>&1 || rm -rf "$DS_CACHE"
fi
if [ -f "$DS_CACHE/src/qml/Logos/Controls/qmldir" ]; then
  "$QMLLINT_BIN" -I "$DS_CACHE/src/qml" -I "${QML_IMPORT_PATH%%:*}" --json "$OUT/lint-basecamp.json" ui/src/qml/*.qml >/dev/null 2>&1
else
  echo "NOTE: could not fetch logos-design-system $BASECAMP_DESIGN_SYSTEM_REV; Basecamp's design system not checked"
fi

python3 - "$OUT/lint.json" "$LOGOS_QML_LIB/Logos/Theme/DarkTheme.qml" ui/tests/qmllint-baseline.json "${1:-}" "$OUT/lint-basecamp.json" <<'EOF'
import collections, glob, json, os, re, sys
lint_path, theme_path, baseline_path, mode, basecamp_path = sys.argv[1:6]
GATED = {"missing-property", "missing-enum-entry", "missing-type", "unresolved-type",
         "import", "syntax", "unresolved-alias", "incompatible-type", "read-only-property",
         "uncreatable-type", "non-list-property", "duplicate-property-binding"}
found = collections.Counter()
for f in json.load(open(lint_path))["files"]:
    name = os.path.basename(f["filename"])
    for w in f.get("warnings", []):
        if w.get("id") in GATED:
            found[f"{name} · {w['id']} · {w['message']}"] += 1
if os.path.exists(basecamp_path):
    for f in json.load(open(basecamp_path))["files"]:
        name = os.path.basename(f["filename"])
        for w in f.get("warnings", []):
            if w.get("id") in GATED:
                found[f"{name} · basecamp-0.3.2 · {w['id']} · {w['message']}"] += 1
theme = set(re.findall(r"readonly property \w+ (\w+)\s*:", open(theme_path).read()))
for path in sorted(glob.glob("ui/src/qml/*.qml")):
    for key in re.findall(r"Theme\.palette\.(\w+)", open(path).read()):
        if key not in theme:
            found[f"{os.path.basename(path)} · palette-key · Theme.palette.{key} is not in the theme"] += 1
# A property bound twice in one object: Qt 6.9's qmllint says nothing, and at runtime the
# whole document fails to load ("Property value set multiple times"), blanking every view
# that uses it. Read each object's own bindings (one level in), skipping JS blocks.
OBJ = re.compile(r"^(\s*)([A-Z][\w.]*)\s*\{\s*$")
BIND = re.compile(r"^(\s*)([a-z][\w.]*)\s*:(?!:)")
for path in sorted(glob.glob("ui/src/qml/*.qml")):
    stack = []          # (indent, "object" | "code", names-seen)
    for n, line in enumerate(open(path), 1):
        raw = line.rstrip("\n")
        code = re.sub(r"//.*$", "", re.sub(r'"(?:[^"\\]|\\.)*"', '""', raw))
        if not code.strip():
            continue
        ind = len(code) - len(code.lstrip())
        if code.lstrip().startswith("}"):
            while stack and stack[-1][0] >= ind:
                stack.pop()
        m = OBJ.match(code)
        if m:
            stack.append((ind, "object", {}))
            continue
        b = BIND.match(code)
        if b and stack and stack[-1][1] == "object" and len(b.group(1)) == stack[-1][0] + 4 \
                and b.group(2) not in ("property", "readonly", "required", "signal", "function", "default"):
            seen = stack[-1][2]
            if b.group(2) in seen:
                found[f"{os.path.basename(path)} · duplicate-binding · {b.group(2)} set twice in one object"] += 1
            seen[b.group(2)] = n
        if code.rstrip().endswith("{") and not m:
            stack.append((ind, "code", {}))
# Every objectName the UI harness (ui/tests/muster-ui-test.mjs) looks up must still exist:
# a control renamed or removed in a redesign leaves the harness clicking at nothing. A name
# built at runtime ("roomPolicy" + kind) counts by its literal prefix.
defined, prefixes = set(), set()
for path in glob.glob("ui/src/qml/*.qml"):
    text = open(path).read()
    for expr in re.findall(r"objectName:\s*([^\n]+)", text):
        lits = re.findall(r'"([A-Za-z_]+)"', expr)
        if "+" in expr:
            prefixes.update(l for l in lits)
        else:
            defined.update(lits)
harness = open("ui/tests/muster-ui-test.mjs").read()
wanted = set(re.findall(r'(?:clickButton|navTo|setField|propertyOf)\(app,\s*"([A-Za-z_]+)"', harness))
wanted |= set(re.findall(r'objectName",\s*value:\s*"([A-Za-z_]+)"', harness))
for name in sorted(wanted):
    if name not in defined and not any(name.startswith(p) for p in prefixes):
        found[f"muster-ui-test.mjs · harness-name · {name} is no objectName in ui/src/qml"] += 1
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
