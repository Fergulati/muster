#!/usr/bin/env bash
# A room survives losing the store (exo-dcc.14) — offscreen, no GUI.
# Launch 1 joins a fresh topic and proposes into it (MUSTER_AUTOPROPOSE), so the room has
# events; its own copy of the room is kept beside the keystore (room_journals/). Launch 2,
# on the same user dir, gets a delivery config that names NO store peers, so store
# catch-up is off: whatever the room holds after the relaunch came from the member's own
# copy. Passes when launch 2 reads the room's events back (its pending line shows msgs>0).
# Exits non-zero otherwise, keeping the logs.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
# the same node config with no entry nodes: no store peer to catch up from
NOSTORE=$(python3 -c 'import json,sys; c=json.loads(sys.argv[1]); c.pop("entryNodes",None); print(json.dumps(c))' "$CFG")
TOPIC="/muster/1/room-copy-$(date +%s)/proto"
EFFECT='{"to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1,"nonce":0}'
D=$(mktemp -d)
fail() { echo "FAIL: $1; logs kept in $D"; exit 1; }
echo "topic: $TOPIC"

ui_launch "$D/A" "$D/A1.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
  MUSTER_AUTOPROPOSE="$EFFECT" LOGOS_INSTANCE_ID=roomcopyA
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqE 'MUSTER-LP pending=0 members=1 msgs=[1-9]' "$D/A1.log" 2>/dev/null && { ok=1; break; }
done
[ "$ok" = 1 ] || fail "launch 1 never held a message in the room"
sleep 2
ui_cleanup
j=$(find "$D/A" -path '*room_journals*' -name '*.journal' | head -1)
[ -n "$j" ] && [ -s "$j" ] || fail "no room journal was kept"
echo "1. the room has events; its own copy kept ($(stat -c %s "$j") bytes)"

sleep 2
ui_launch "$D/A" "$D/A2.log" \
  MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$NOSTORE" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=roomcopyA
ok=0
for i in $(seq 1 60); do
  sleep 1
  grep -aqE 'MUSTER-LP pending=0 members=1 msgs=[1-9]' "$D/A2.log" 2>/dev/null && { ok=1; break; }
done
ui_cleanup
grep -aq 'storeQuery' "$D/A2.log" && fail "launch 2 asked a store, so this proves nothing"
[ "$ok" = 1 ] || fail "after the relaunch with no store, the room came back empty ($(grep -ao 'pending=[^"]*' "$D/A2.log" | tail -1))"
echo "2. relaunched with no store to ask: the room came back from its own copy"
echo "SUCCESS: a room outlives the store's copy of it."
rm -rf "$D"
