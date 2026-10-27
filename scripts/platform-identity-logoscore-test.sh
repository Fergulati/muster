#!/usr/bin/env bash
# Headless end to end, under logoscore 0.3.1 (exo-833): muster_module's room identity held by
# the person's keystore_module, reached through signer_manager_module. Never the standalone
# runner: its host cannot attribute muster's calls (K1 labbook), and the manager derives
# muster's key from the caller's attested name.
#
#   one logoscore daemon: muster_module (this tree) and its dependencies; keystore_module and
#     signer_manager_module from their forks (identity keys, request_identity); manager_probe,
#     the manager's doctest module, standing in for the keys app (custodian and approver)
#   the custodian imports a phrase; muster asks for an identity of its own
#     (identity_platform_request); the "keys app" shows it and approves with the password,
#     unlocked for muster_module with confirm false
#   identity_platform_status: ready, applied, the key derived for muster_module/default
#   muster founds a room and posts a message: the founding key and the message's authorship
#     go through the manager inside the unlock, with no prompt; the room knows this member by
#     the platform key, and the message reads as authentic
#   the keys app locks the identity: the next post is refused with its remedy, never waited on
#   identity-backend can no longer change: a room is joined
#
#   scripts/platform-identity-logoscore-test.sh       # needs a runner (make build) for the deps
#   DEPS_RUNNER=<worktree>/.run/runner KEEP_LOGS=1 scripts/platform-identity-logoscore-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh          # ui_local_config: a delivery node that needs no fleet
CACHE=(--accept-flake-config --extra-substituters https://cache.nix.logos.co/public
       --extra-trusted-public-keys public:l4HrXgL4nw246+LBh2SOJyhz64BoGegOYLheT/iIAPU=)
REV="${LOGOSCORE_REV:-0.3.1}"
DEPS_RUNNER="${DEPS_RUNNER:-.run/runner}"
KEYSTORE="${KEYSTORE:-github:corpetty/logos-evm-keystore-module/20cfd6f87e38dbc7bdc3ed4e6e72700076eafb40}"
MANAGER="${MANAGER:-github:corpetty/logos-signer-manager-module/bafc457}"
PHRASE="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
PW="muster-833-test-only"

[ -e "$DEPS_RUNNER" ] || { echo "no runner at $DEPS_RUNNER: make build (it supplies muster's dependency modules), or DEPS_RUNNER=…"; exit 1; }
DEPS=$(nix-store -qR "$(readlink -f "$DEPS_RUNNER")" | grep -- '-plugin-dir-modules$' | head -1)
build() { nix build "$@" --no-link --print-out-paths --no-write-lock-file "${CACHE[@]}" 2>/dev/null | tail -1; }
echo "building: logoscore $REV, muster_module (this tree), keystore_module, signer_manager_module, manager_probe…"
L="$(build "github:logos-co/logos-logoscore-cli/$REV")/bin/logoscore"
MUSTER=$(build "./module#install")
KS=$(build "$KEYSTORE#install")
MGR=$(build "$MANAGER#install")
PROBE=$(build "$MANAGER?dir=doctests/manager-probe#install" \
  --override-input signer_manager_module "$MANAGER" --override-input keystore_module "$KEYSTORE")
for x in "$L" "$MUSTER" "$KS" "$MGR" "$PROBE"; do [ -e "$x" ] || { echo "build failed: $x"; exit 1; }; done

D=$(mktemp -d); mkdir -p "$D/mods" "$D/cfg" "$D/data"
for m in "$DEPS"/*/; do
  n=$(basename "$m"); case "$n" in capability_module|muster_module|keystore_module) continue ;; esac
  cp -rL --no-preserve=mode "$m" "$D/mods/"
done
for src in "$MUSTER" "$KS" "$MGR" "$PROBE"; do cp -rL --no-preserve=mode "$src"/modules/* "$D/mods/"; done

lc() { timeout 60 "$L" --config-dir "$D/cfg" "$@" 2>&1 | tail -1; }
res() { python3 -c 'import sys,json
try:
  v=json.load(sys.stdin)["result"]; print(v if isinstance(v,str) else json.dumps(v))
except Exception: print("")'; }
call() { lc call "$@" | res; }
field() { python3 -c "import sys,json
try: v=json.loads(sys.stdin.read()); print(v$1)
except Exception: print('')"; }

MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$(ui_local_config)" MUSTER_DATA_DIR="$D/data" \
  setsid "$L" --config-dir "$D/cfg" daemon -m "$D/mods" --persistence-path "$D/cfg/data" >"$D/daemon.log" 2>&1 &
DPID=$!
cleanup() { lc stop >/dev/null; kill -9 -"$DPID" 2>/dev/null; kill -9 "$DPID" 2>/dev/null; }
trap cleanup EXIT
for _ in $(seq 1 20); do lc status >/dev/null && break; sleep 1; done

ok=1
step() { echo "── $*"; }
fail() { echo "FAIL: $*"; ok=0; }
step "load"; for m in muster_module manager_probe; do lc load-module "$m" | cut -c1-140; done
step "roles (operator)"
call keystore_module configure '{"approvers":"evm_signer_ui","custodians":"manager_probe","managers":"signer_manager_module"}' >/dev/null
call signer_manager_module configure '{"approvers":"manager_probe","custodians":"manager_probe","signers":"keystore_module"}' >/dev/null
step "the custodian imports a phrase"
call manager_probe import_identity "{\"phrase\":\"$PHRASE\",\"password\":\"$PW\"}" | cut -c1-160

LOCAL=$(call muster_module identity); echo "local identity: $(echo "$LOCAL" | cut -c1-160)"

step "muster asks for an identity of its own"
r=$(call muster_module identity_platform_request); echo "$r"
H=$(echo "$r" | field '["handle"]')
[ -n "$H" ] || fail "no request handle"
step "the keys app shows it and approves"
shown=$(call manager_probe show "$H"); echo "$shown" | cut -c1-600
echo "$shown" | grep -qF "muster_module/default" || fail "the keys app was not shown muster's namespaced context"
call manager_probe decide "{\"handle\":\"$H\",\"bundle_id\":\"$(echo "$shown" | field '["bundle_id"]')\",\"password\":\"$PW\"}" | cut -c1-200

st=""
for _ in $(seq 1 10); do st=$(call muster_module identity_platform_status); echo "$st" | grep -q '"ready"' && break; sleep 1; done
echo "status: $st"
PK=$(echo "$st" | field '["publicKey"]'); ACCT=$(echo "$st" | field '["account"]')
[ "$(echo "$st" | field '["applied"]')" = "True" ] || fail "identity-backend was not set to the platform key"
echo "$st" | grep -q 'muster_module/default' || fail "the key is not derived for muster_module/default"
call muster_module settings | grep -q "platform:$PK" || fail "settings do not name platform:$PK"

step "found a room and post, inside the unlock"
TOPIC="/muster/1/id833-$(date +%s)/proto"
call muster_module coordinate_join "$TOPIC" | cut -c1-200
call muster_module coordinate_post_message "hello from a platform identity" | cut -c1-200
MEM=$(call muster_module coordinate_members); echo "members: $(echo "$MEM" | cut -c1-300)"
echo "$MEM" | grep -q "$PK" || fail "the room does not know this member by the platform key"
MSG=$(call muster_module coordinate_messages); echo "messages: $(echo "$MSG" | cut -c1-400)"
echo "$MSG" | grep -q "hello from a platform identity" || fail "the message is not in the room's authentic view"

step "the keys app locks the identity: the next post is refused, not waited on"
call manager_probe lock "{\"account\":\"$ACCT\"}" | cut -c1-160
t0=$(date +%s)
r=$(call muster_module coordinate_post_message "after the lock"); echo "$r" | cut -c1-300
[ $(( $(date +%s) - t0 )) -lt 15 ] || fail "the post waited on the person"
call muster_module coordinate_messages | grep -q "after the lock" && fail "a message was authored after the lock"
p=$(call manager_probe pending); echo "pending in the keys app: $(echo "$p" | cut -c1-200)"

step "identity-backend no longer changes"
call muster_module set_setting identity-backend local | grep -q "before any room is joined" || fail "switched backends with a room joined"

if [ "$ok" = 1 ]; then
  echo "PASS: muster's room identity is a key the person's keystore holds for muster_module/default; a room founded and a message authored through the manager within the unlock; refused when locked"
  [ -n "${KEEP_LOGS:-}" ] && echo "logs: $D" || rm -rf "$D"
  exit 0
fi
echo "logs: $D"; tail -40 "$D/daemon.log"
exit 1
