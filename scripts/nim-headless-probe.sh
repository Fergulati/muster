#!/usr/bin/env bash
# exo-607 T7: the Nim headless host (ui-nim#headless-host) drives muster_module from
# stdin. It starts logos-core in its own process on the modules the C++ runner was
# built with, and drive.py calls health, identity and describe. Passes when health is
# "ok" and identity names an address. Cleanup kills only this probe's module hosts.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNNER=".run/runner/bin/muster-ui"
[ -x "$RUNNER" ] || { echo "build the runner first: make build (its modules dir is what the host loads)"; exit 1; }
LAUNCH=$(grep -oE '/nix/store/[^ "]+/bin/run-logos-standalone-ui' "$RUNNER" | head -1)
MODULES=$(grep -oE -- '--modules-dir "[^"]+"' "$LAUNCH" | cut -d'"' -f2)
HOST=$(cd ui-nim && nix build .#headless-host --no-link --print-out-paths --accept-flake-config 2>/dev/null) \
  || { echo "could not build ui-nim#headless-host"; exit 1; }
D=$(mktemp -d)
INSTANCE="nimheadless$$"
OUT=$(timeout 90 python3 ui-nim/headless/drive.py "$HOST/bin/muster-headless-host" "$MODULES" "" "$D/data" "$INSTANCE")
rc=$?
for p in $(pgrep -f 'logos_host' 2>/dev/null); do
  tr '\0' '\n' </proc/"$p"/environ 2>/dev/null | grep -qx "LOGOS_INSTANCE_ID=$INSTANCE" && kill -9 "$p" 2>/dev/null
done
echo "$OUT"
ok=1
[ "$rc" = 0 ] && echo "$OUT" | grep -q $'^health   -> OK\tok$' && echo "PASS: health() is ok" || { echo "FAIL: health"; ok=0; }
echo "$OUT" | grep -qE $'^identity -> OK\t\\{"address":"0x[0-9a-f]{40}"' && echo "PASS: identity() names an address" || { echo "FAIL: identity"; ok=0; }
rm -rf "$D"
[ "$ok" = 1 ] && echo "SUCCESS: the Nim headless host drives muster_module from stdin" || echo "FAILED"
exit $((1-ok))
