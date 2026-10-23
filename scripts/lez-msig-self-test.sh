#!/usr/bin/env bash
# lez-msig through the real UI binary (epic exo-0d3): two offscreen runners in one room, the
# program deployed on a local LEZ v0.3 zone. No GUI, no clicks: the backend's autopilot calls
# the slots the accounts panel and the card call.
#   A founds the room, admits B, and once B is in opens a 2-of-2 ceremony (MUSTER_AUTOMSIG_OPEN);
#   both runners' modules join it with their own approval keys on their intents tick;
#   A's module creates it on chain from A's own funded LEZ account and discloses it;
#   this script funds the vault; A proposes a payment from it (MUSTER_AUTOMSIG_PAY) — its
#   approval — and B approves on the card (MUSTER_AUTOMSIG_APPROVE);
#   A settles (MUSTER_AUTOMSIG_SETTLE): one transaction carries the proposal and both
#   approvals, and the program pays.
# Passes when the recipient holds exactly the payment and both runners fold the intent final.
#
#   infra/lez/localnet.sh && make build && scripts/lez-msig-self-test.sh
#   MSIG_BIN (default: programs/lez-msig's built guest), MSIG_PROGRAM (skip the deploy),
#   LEZ_RPC (default http://127.0.0.1:3040), KEEP_LOGS=1, MUSTER_FLEET=local (no fleet)
#
# What it proves, and what it does not: the backend slots, the module, the room over the
# fleet and the program on a real sequencer, in the real runner. Offscreen, the QML is never
# instantiated: scripts/ui-lint.sh checks it, and a look at the window does the rest.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT

RPC="${LEZ_RPC:-http://127.0.0.1:3040}"
FUNDER=infra/lez/funder.sh
rpc() {  # method params-json → result JSON
  curl -s -m 10 -X POST "$RPC" -H 'content-type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":$2}" |
    python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("result")))'
}
b58() { python3 - "$1" <<'PY'
import sys
raw = bytes.fromhex(sys.argv[1]); n = int.from_bytes(raw, "big"); out = ""
a = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
while n: n, r = divmod(n, 58); out = a[r] + out
print("1" * (len(raw) - len(raw.lstrip(b"\0"))) + out)
PY
}
[ "$(rpc getLastBlockId '[]')" != null ] || { echo "no LEZ zone at $RPC: run infra/lez/localnet.sh"; exit 1; }

PROGRAM="${MSIG_PROGRAM:-}"
if [ -z "$PROGRAM" ]; then
  BIN="${MSIG_BIN:-$(ls programs/lez-msig/target/riscv-guest/msig_methods/msig_guest/riscv32im-risc0-zkvm-elf/release/msig.bin 2>/dev/null)}"
  [ -n "$BIN" ] || { echo "no program binary: cargo build -p msig_methods in programs/lez-msig, or set MSIG_PROGRAM"; exit 1; }
  out=$("$FUNDER" --zone "$RPC" deploy "$BIN") || { echo "deploy failed: $out"; exit 1; }
  PROGRAM=$(echo "$out" | grep -o '(hex [0-9a-f]\{64\}' | tail -1 | cut -c6-)
fi
[ ${#PROGRAM} = 64 ] || { echo "no program account id"; exit 1; }

D=$(mktemp -d)
TOPIC="/muster/1/lez-msig-$(date +%s)/proto"
CFG=$(ui_fleet_config)
TO=$(python3 -c 'import os; print(os.urandom(32).hex())')
PAY=1200
lg() { sed 's/\\"/"/g' "$1" 2>/dev/null; }
LEZ=(MUSTER_LEZ_RPC="$RPC" MUSTER_LEZ_CHAIN=lez:local MUSTER_LEZ_MSIG_PROGRAM="$PROGRAM")
echo "program: $PROGRAM · topic: $TOPIC · logs: $D"

ui_launch "$D/A" "$D/A.log" HOME="$D/A-home" QT_FORCE_STDERR_LOGGING=1 "${LEZ[@]}" \
  MUSTER_AUTOADMIT=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=msigA \
  MUSTER_AUTOMSIG_OPEN=2 MUSTER_AUTOMSIG_PAY="$TO:$PAY" MUSTER_AUTOMSIG_SETTLE=1
CFG_B=$(ui_peer_config "$D/A.log") || exit 1
ui_launch "$D/B" "$D/B.log" HOME="$D/B-home" QT_FORCE_STDERR_LOGGING=1 "${LEZ[@]}" \
  MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=msigB MUSTER_AUTOMSIG_APPROVE=1

funded=""; vault=""; ok=0; T0=$SECONDS
echo "running the ceremony, create, fund, propose, approve, settle (up to 360s)..."
while [ $((SECONDS - T0)) -lt 360 ]; do
  sleep 1
  for who in A B; do   # fund each runner's own LEZ account once it names it
    case " $funded " in *" $who "*) continue ;; esac
    acct=$(lg "$D/$who.log" | grep -a 'MSIG payer' | grep -o '"account":"[0-9a-f]\{64\}"' | head -1 | cut -d'"' -f4)
    [ -n "$acct" ] && "$FUNDER" --zone "$RPC" fund "$acct" 1000000000 >/dev/null && funded="$funded $who" &&
      echo "funded $who's account $acct after $((SECONDS - T0))s"
  done
  if [ -z "$vault" ]; then
    vault=$(lg "$D/A.log" | grep -a 'MSIG account' | head -1 | grep -o 'lez:local:[0-9a-f]\{64\}' | head -1 | cut -d: -f3)
    [ -n "$vault" ] && "$FUNDER" --zone "$RPC" fund "$vault" 5000 >/dev/null && echo "the multisig $vault is on chain and disclosed after $((SECONDS - T0))s; vault funded"
  fi
  bal=$(rpc getAccountBalance "[\"$(b58 "$TO")\"]")
  # grep the files themselves: under pipefail, `lg … | grep -q` fails when grep exits first (SIGPIPE)
  if [ "$bal" = "$PAY" ] && grep -aq 'MSIG intent .* final' "$D/A.log" && grep -aq 'MSIG intent .* final' "$D/B.log"; then
    ok=1; break
  fi
done
ui_cleanup
echo "A: $(lg "$D/A.log" | grep -a 'MSIG intent' | tail -1 | cut -c1-120)"
echo "B: $(lg "$D/B.log" | grep -a 'MSIG intent' | tail -1 | cut -c1-120)"
if [ "$ok" = 1 ]; then
  echo "SUCCESS: a 2-of-2 lez-msig made in the room paid exactly $PAY, both runners final after $((SECONDS - T0))s."
  [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$D"
else
  echo "FAIL (recipient holds ${bal:-?}): logs kept in $D"
  lg "$D/A.log" | grep -a 'MSIG ' | tail -3 | cut -c1-600
  exit 1
fi
