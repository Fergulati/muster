## An entry's epoch is the key that opened it, in flow and provenance (exo-dde.9).
## Events without parents sort by content id, so an entry sealed in epoch 1 can sort
## before the admission that opened epoch 1. Read off position, flow would say only the
## founders could see it and provenance would call it epoch 0. Given the session's record
## of which key opened each event (`CoordinationSession.sealedIn`), both are right
## wherever the entry sorts; without it they keep today's positional reading.
## Stub driver; pure Nim.

import std/[tables, sequtils]
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/flow

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)

let admit = membershipEvent(1, "carol")
var late: Event
for n in 0 .. 500:
  late = newMessageEvent("alice", int64(n), "after carol joined", 1)[1]
  if eventId(late) < eventId(admit): break
doAssert eventId(late) < eventId(admit), "need an epoch-1 entry that sorts before its admission"
let events = @[admit, late]
var sealedIn = initTable[string, int]()
sealedIn[eventId(admit)] = 1
sealedIn[eventId(late)] = 1
let founders = @["alice", "bob"]

proc roomRowFor(rows: seq[FlowRow], kind: string): FlowRow =
  for r in rows: (if r.kind == kind and r.to == obRoomMember: return r)
  doAssert false, "no room row for " & kind

block:
  let pos = reduceFlow(events, stub, founders)
  doAssert pos.roomRowFor("message").members == @["alice", "bob"], "the positional reading is wrong here"
  let rows = reduceFlow(events, stub, founders, sealedIn)
  let m = rows.roomRowFor("message")
  doAssert m.members == @["alice", "bob", "carol"], $m.members
  doAssert m.epoch == 1
  echo "1. flow: who could read an entry follows the key that opened it OK"

block:
  proc epochOf(items: seq[LogProvItem], kind: string): int =
    for it in items: (if it.kind == kind: return it.epoch)
    -1
  doAssert logProvenance(events, stub).epochOf("message") == 0, "the positional reading is wrong here"
  doAssert logProvenance(events, stub, sealedIn).epochOf("message") == 1
  echo "2. provenance: an entry's epoch is the key that opened it OK"

block:
  # a joiner admitted at epoch 2 is not among those who could read an epoch-1 entry,
  # whatever order the admissions sort in
  let admit2 = membershipEvent(2, "dave")
  var s2 = sealedIn
  s2[eventId(admit2)] = 2
  let rows = reduceFlow(events & @[admit2], stub, founders, s2)
  doAssert "dave" notin rows.roomRowFor("message").members
  echo "3. a later joiner never appears among an earlier entry's readers OK"

echo "epoch_attribution_test: all OK"
