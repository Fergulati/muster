#!/usr/bin/env bash
# FileShare end to end through the real UI binary (exo-4d0, docs/design/room-swarm.md) — no
# GUI, no clicks. Two offscreen runners in one room on the delivery fleet (MUSTER_FLEET, as
# every self-test), each with its own storage_module node, on a private storage network of
# their own on this host (A's node founds it, B's bootstraps from A's signed peer record):
#   A founds the room, admits B, and once B is in shares a random 3 MB file
#     (MUSTER_AUTOFILESHARE — the FileShare tab's Share);
#   B sees the share in the room, fetches it (MUSTER_AUTOFILEFETCH — Fetch), and seeds it.
# Passes when B's download is byte-identical to A's file, B's folder holds nothing else, and
# A's list shows B as a seeder (B's own signed announce).
#
# FILESHARE_PRIVATE=1 fetches privately instead (Mix). storage_module builds a Mix pool only
# for its presets, so on this private network a private fetch has no path: expect it to fail,
# and see docs/labbook/storage-from-muster.md Q3 for what it takes.
#
# Each runner runs with its own HOME: storage_module writes $HOME/.logos_storage/config.json
# on init, and this test must never touch yours. Cleanup kills only this script's runners.
#
#   make build && scripts/fileshare-self-test.sh        # KEEP_LOGS=1 keeps the logs
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT

D=$(mktemp -d)
TOPIC="/muster/1/fileshare-$(date +%s)/proto"
CFG=$(ui_fleet_config)
port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
storage_cfg() {   # <data dir> <port> [bootstrap spr]
  python3 - "$@" <<'EOF'
import json, sys
c = {"data-dir": sys.argv[1], "listen-port": int(sys.argv[2]), "listen-ip": "127.0.0.1",
     "nat": "extip:127.0.0.1", "mix-enabled": False, "log-level": "info"}
if len(sys.argv) > 3: c["bootstrap-node"] = [sys.argv[3]]
else: c["no-bootstrap-node"] = True
print(json.dumps(c))
EOF
}
mkdir -p "$D/A-home" "$D/B-home" "$D/B-downloads"
head -c 3145728 /dev/urandom > "$D/report-q3.bin"
echo "topic: $TOPIC · file: 3 MB · logs: $D"

ui_launch "$D/A" "$D/A.log" HOME="$D/A-home" QT_FORCE_STDERR_LOGGING=1 \
  MUSTER_AUTOADMIT=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=fileshareA \
  MUSTER_STORAGE_CONFIG="$(storage_cfg "$D/A-storage" "$(port)")" MUSTER_AUTOFILESHARE="$D/report-q3.bin"

echo "waiting for A's storage node (its signed peer record)..."
SPR=""
for i in $(seq 1 90); do
  SPR=$(grep -a 'FILESHARE-NODE' "$D/A.log" 2>/dev/null | grep -ao '"spr":"[^"]*"' | tail -1 | sed 's/"spr":"//;s/"$//')
  [ -n "$SPR" ] && break
  sleep 1
done
[ -n "$SPR" ] || { echo "FAIL: A's storage node never reported an SPR — logs kept in $D"; grep -a 'FILESHARE-NODE' "$D/A.log" | tail -2; exit 1; }
echo "A's storage node is up after ~${i}s"

CFG_B=$(ui_peer_config "$D/A.log") || exit 1
PRIV=()
[ "${FILESHARE_PRIVATE:-0}" = 1 ] && PRIV=(MUSTER_AUTOFILEPRIVATE=1)
ui_launch "$D/B" "$D/B.log" HOME="$D/B-home" QT_FORCE_STDERR_LOGGING=1 \
  MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=fileshareB \
  MUSTER_STORAGE_CONFIG="$(storage_cfg "$D/B-storage" "$(port)" "$SPR")" \
  MUSTER_AUTOFILEFETCH="$D/B-downloads" "${PRIV[@]}"

echo "waiting for B to fetch the file and A to see B seeding (up to 240s)..."
ok=0
for i in $(seq 1 240); do
  sleep 1
  if [ -f "$D/B-downloads/report-q3.bin" ] && cmp -s "$D/report-q3.bin" "$D/B-downloads/report-q3.bin" \
     && grep -a 'FILESHARE {' "$D/A.log" | tail -1 | grep -q '"self":false'; then ok=1; break; fi
done
ui_cleanup
echo "A shared: $(grep -ac '"kind":"share","state":"done"' "$D/A.log" | sed 's/^0$/no/;s/^[1-9].*/yes/') · B's last op: $(grep -a 'FILESHARE {' "$D/B.log" | tail -1 | grep -ao '"kind":"fetch","state":"[a-z]*","error":"[^"]*"' | tail -1)"
others=$(ls "$D/B-downloads" | grep -vx 'report-q3.bin' | wc -l)
if [ "$ok" = 1 ] && [ "$others" = 0 ]; then
  echo "SUCCESS: B fetched A's file byte-identical through Logos Storage after ~${i}s, and seeds it."
  [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$D"
else
  echo "FAIL: logs kept in $D"
  grep -a 'FILESHARE {' "$D/B.log" | tail -1 | cut -c1-600
  exit 1
fi
