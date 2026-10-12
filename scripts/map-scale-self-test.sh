#!/usr/bin/env bash
# Offscreen: one runner joins a room on a local network and posts MAP_LINES chat lines
# (MUSTER_AUTOCHAT, exo-dde.8), so the room's log is long enough for the room map's
# windowing (the Log lens past 240 entries, the timeline's buckets past 400). Run under
# scripts/ui-screenshot.sh record to capture the room map's graph for a gallery fixture.
# Passes when every line was posted and the module folded them all.
set -uo pipefail
cd "$(dirname "$0")/.."
. scripts/lib/ui-build.sh
ui_require_runner
trap ui_cleanup EXIT
CFG=$(ui_fleet_config)
LINES="${MAP_LINES:-420}"
TOPIC="/muster/1/mapscale-$(date +%s)/proto"
D=$(mktemp -d)
echo "topic: $TOPIC · lines: $LINES"
ui_launch "$D/A" "$D/A.log" \
  QT_FORCE_STDERR_LOGGING=1 MUSTER_LP_DEBUG=1 MUSTER_DELIVERY_CONFIG="$CFG" MUSTER_AUTOJOIN_TOPIC="$TOPIC" \
  MUSTER_AUTOCHAT="$LINES" LOGOS_INSTANCE_ID=mapscale
ok=0
for i in $(seq 1 36); do
  sleep 5
  if grep -aq "AUTOCHAT posted $LINES" "$D/A.log" 2>/dev/null; then ok=1; break; fi
done
sleep 8   # let the recorder take the map of the whole room
if [ "$ok" = 1 ]; then
  echo "SUCCESS: $LINES lines posted into one room"
else
  echo "FAILED — see $D/A.log"
fi
ui_cleanup
[ "$ok" = 1 ] && rm -rf "$D"
exit $((1-ok))
