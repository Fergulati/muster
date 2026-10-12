## The room map at scale (G7, exo-dde.8): a 1,850-entry room — 1,600 messages and 50
## proposals with their approvals and settlement, each event naming the one before it in
## `after` as a live room's would. causalOrder (which the graph and the activity feed
## replay by) stays within its budget, and the graph costs little beyond the folds it
## joins (logProvenance, reduceIntentViews, reduceFlow). Those folds took ~10 s here
## until canonicalOrder moved to a min-heap (exo-53d); they are held under 4 s.
## Stub driver; pure Nim. Timings are printed so a regression shows in the log.

import std/[times, monotimes, strutils, json]
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/room_graph
import ../src/coordination/flow

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 2, finality = finExternal, verifyResult = true)

var evs: seq[Event]
proc add(e: Event) =
  var x = e
  if evs.len > 0: x.after = @[eventId(evs[^1])]
  evs.add x
var m = 0
for i in 0 ..< 50:
  let effect = """{"to":"0x""" & toHex(i, 4) & """","value":""" & $i & "}"
  let id = intentIdFor(effect)
  for _ in 0 ..< 32: (add newMessageEvent("alice", int64(m), "m" & $m, 1)[1]; inc m)
  add proposeEvent(id, effect)
  add contributeEvent(id, "0xa", "sa")
  add contributeEvent(id, "0xb", "sb")
  add submitEvent(id)
  add finalEvent(id)
doAssert evs.len == 50 * 37, $evs.len

proc ms(d: Duration): float = d.inMicroseconds.float / 1000.0

block:
  let t0 = getMonoTime()
  let o = causalOrder(evs)
  let dt = getMonoTime() - t0
  doAssert o.len == evs.len
  echo "causalOrder over ", evs.len, " entries: ", dt.ms, " ms"
  doAssert dt < initDuration(seconds = 2), "causalOrder too slow: " & $dt.ms & " ms"

block:
  template timed(body: untyped): Duration =
    (let t = getMonoTime(); discard body; getMonoTime() - t)
  let base = timed(logProvenance(evs, stub)) + timed(reduceIntentViews(evs, stub)) +
             timed(reduceFlow(evs, stub, @["alice", "bob"]))
  let t0 = getMonoTime()
  let g = reduceRoomGraph(evs, stub, @["alice", "bob"], "alice")
  let dt = getMonoTime() - t0
  var intents = 0
  for n in g.nodes: (if n.kind == "intent": inc intents)
  doAssert intents == 50
  echo "the folds the graph joins: ", base.ms, " ms; reduceRoomGraph: ", dt.ms, " ms"
  doAssert dt.ms < base.ms * 1.3 + 500, "the graph adds too much beyond its folds: " & $dt.ms & " vs " & $base.ms
  # exo-53d: canonicalOrder's heap took these folds from ~10 s to ~1.4 s here; hold the line
  doAssert base.ms < 4000, "the folds regressed: " & $base.ms & " ms"

echo "room_graph_scale_test: all OK"
