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
# The runners never run with your HOME: storage_module writes $HOME/.logos_storage/config.json
# on init, and this test must never touch yours. By default each has its own scratch HOME and
# the test names each node's data dir and port. FILESHARE_ONE_HOME=1 is the shape `make run`
# peers beside Basecamp have instead: ONE (scratch) HOME for both, already holding a storage
# config another app wrote, and the test names neither, so Muster must
# keep each instance's node apart itself. Cleanup kills only this script's runners.
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
ONE_HOME="${FILESHARE_ONE_HOME:-0}"
storage_cfg() {   # <data dir> <port> [bootstrap spr]
  python3 - "$ONE_HOME" "$@" <<'EOF'
import json, sys
one = sys.argv.pop(1) == "1"
c = {"listen-ip": "127.0.0.1", "nat": "extip:127.0.0.1", "mix-enabled": False, "log-level": "info"}
if not one: c.update({"data-dir": sys.argv[1], "listen-port": int(sys.argv[2])})
if len(sys.argv) > 3: c["bootstrap-node"] = [sys.argv[3]]
else: c["no-bootstrap-node"] = True
print(json.dumps(c))
EOF
}
# the backend's lines reach the log Qt-quoted (\"key\":\"value\"): read them unquoted
lg() { sed 's/\\"/"/g' "$1" 2>/dev/null; }
mkdir -p "$D/A-home" "$D/B-home" "$D/B-downloads"
head -c 3145728 /dev/urandom > "$D/report-q3.bin"
echo "topic: $TOPIC · file: 3 MB · logs: $D"

HOME_A="$D/A-home"; HOME_B="$D/B-home"
if [ "$ONE_HOME" = 1 ]; then
  HOME_A="$D/home"; HOME_B="$D/home"
  mkdir -p "$D/home/.logos_storage"
  # what Basecamp's package downloader leaves there (S0 Q8), but on no network: Mix off
  printf '{"config-version":3,"data-dir":"%s","mix-enabled":false,"nat-schedule-interval":"60s"}\n' \
    "$D/home/.logos_storage/data" > "$D/home/.logos_storage/config.json"
  cp "$D/home/.logos_storage/config.json" "$D/shared-config.before"
fi
ui_launch "$D/A" "$D/A.log" HOME="$HOME_A" QT_FORCE_STDERR_LOGGING=1 \
  MUSTER_AUTOADMIT=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=fileshareA \
  MUSTER_STORAGE_CONFIG="$(storage_cfg "$D/A-storage" "$(port)")" MUSTER_AUTOFILESHARE="$D/report-q3.bin"

echo "waiting for A's storage node (its signed peer record)..."
SPR=""
for i in $(seq 1 90); do
  SPR=$(lg "$D/A.log" | grep -a 'FILESHARE-NODE' | grep -ao '"spr":"spr:[A-Za-z0-9_-]*' | tail -1 | sed 's/"spr":"//')
  [ -n "$SPR" ] && break
  sleep 1
done
[ -n "$SPR" ] || { echo "FAIL: A's storage node never reported an SPR — logs kept in $D"; lg "$D/A.log" | grep -a 'FILESHARE-NODE' | tail -1 | cut -c1-400; exit 1; }
echo "A's storage node is up after ~${i}s"

CFG_B=$(ui_peer_config "$D/A.log") || exit 1
PRIV=()
[ "${FILESHARE_PRIVATE:-0}" = 1 ] && PRIV=(MUSTER_AUTOFILEPRIVATE=1)
ui_launch "$D/B" "$D/B.log" HOME="$HOME_B" QT_FORCE_STDERR_LOGGING=1 \
  MUSTER_DELIVERY_CONFIG="$CFG_B" MUSTER_AUTOJOIN_TOPIC="$TOPIC" LOGOS_INSTANCE_ID=fileshareB \
  MUSTER_STORAGE_CONFIG="$(storage_cfg "$D/B-storage" "$(port)" "$SPR")" \
  MUSTER_AUTOFILEFETCH="$D/B-downloads" "${PRIV[@]}"

echo "waiting for B to fetch the file and A to see B seeding (up to 240s)..."
ok=0
for i in $(seq 1 240); do
  sleep 1
  if [ -f "$D/B-downloads/report-q3.bin" ] && cmp -s "$D/report-q3.bin" "$D/B-downloads/report-q3.bin" \
     && lg "$D/A.log" | grep -a 'FILESHARE {' | tail -1 | grep -q '"self":false'; then ok=1; break; fi
done
ui_cleanup
echo "A shared: $(lg "$D/A.log" | grep -ac '"kind":"share","state":"done"' | sed 's/^0$/no/;s/^[1-9].*/yes/') · B's last op: $(lg "$D/B.log" | grep -a 'FILESHARE {' | tail -1 | grep -ao '"kind":"fetch","state":"[a-z]*","error":"[^"]*"' | tail -1)"
others=$(ls "$D/B-downloads" | grep -vx 'report-q3.bin' | wc -l)
if [ "$ONE_HOME" = 1 ] && ! cmp -s "$D/shared-config.before" "$D/home/.logos_storage/config.json"; then
  echo "the shared storage config was changed:"; cat "$D/home/.logos_storage/config.json"; ok=0
fi
if [ "$ok" = 1 ] && [ "$others" = 0 ]; then
  echo "SUCCESS: B fetched A's file byte-identical through Logos Storage after ~${i}s, and seeds it."
  [ "${KEEP_LOGS:-0}" = 1 ] || rm -rf "$D"
else
  echo "FAIL: logs kept in $D"
  lg "$D/B.log" | grep -a 'FILESHARE {' | tail -1 | cut -c1-800
  exit 1
fi
