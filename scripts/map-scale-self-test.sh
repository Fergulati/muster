#!/usr/bin/env bash
# One runner joins a room and posts MAP_LINES chat lines (MUSTER_AUTOCHAT, exo-dde.8), so
# the room's log is long enough for the room map's windowing (the Log lens past 240
# entries, the timeline's buckets past 400). Run it under `scripts/ui-screenshot.sh record`:
# the recorder asks for the room map every 2 s, and the test passes when the module has
# served a map holding every line AND the recorder has written a whole snapshot of it
# (MUSTER_RECORD_DIR), ready to become a gallery fixture. A large room's snapshot takes a
# while to reach the view and be written; the run waits for it rather than a fixed time.
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
# Posting runs through the module one line at a time, behind the loop that queues it.
# Under `ui-screenshot.sh record` the recorder asks for the room map every 2 s and the
# module logs each answer (MUSTER-LP graph): wait until the map holds every line.
WANT="\"seqMax\":$((LINES - 1)),"
for i in $(seq 1 120); do
  sleep 5
  if grep -aq "MUSTER-LP graph .*$WANT" "$D/A.log" 2>/dev/null; then ok=1; break; fi
done
# The view's copy of the map, as the recorder wrote it: a snapshot that parses and holds
# every line (the graph sits inside the snapshot as a JSON string, so its quotes are escaped).
snap=""
if [ "$ok" = 1 ] && [ -n "${MUSTER_RECORD_DIR:-}" ]; then
  ok=0
  for i in $(seq 1 120); do
    for f in $(grep -lF "\\\"seqMax\\\":$((LINES - 1))," "$MUSTER_RECORD_DIR"/*.json 2>/dev/null); do
      python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null && { snap="$f"; ok=1; break; }
    done
    [ "$ok" = 1 ] && break
    sleep 5
  done
fi
if [ "$ok" = 1 ]; then
  echo "SUCCESS: the room map holds all $LINES lines${snap:+ (snapshot $(basename "$snap"))}"
else
  echo "FAILED — see $D/A.log"
fi
ui_cleanup
[ "$ok" = 1 ] && [ -z "${MAP_KEEP:-}" ] && rm -rf "$D"; [ -n "${MAP_KEEP:-}" ] && echo "logs: $D"
exit $((1-ok))
