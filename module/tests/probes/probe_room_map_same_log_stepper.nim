## derived-exo-dde s2: the same log draws the same map. Two members' maps of one set of
## events differ only in who is viewing (viewer) and from which epoch they read
## (readFrom), whatever order the events arrived in and however often they were
## duplicated; and a room fingerprint from an epoch is the same for any two members who
## hold the same entries from that epoch, and changes when an entry differs.
##
## STEPPER: state = one case of log {a settled Safe payment, a split paid in parts, a room
## holding a forged message and a refused approval, a room with two admissions — each from
## REAL sessions, real drivers} x transform {reversed, two seeded shuffles, every event
## duplicated, extra copies of every event differing only in `after` (the set in two
## different orders), the same events viewed by each member}: 24 cases, chained
## case -> case+1. The reference is the map of the log as Alice's session holds it. The
## case is judged correct iff:
##   * the transformed map equals the reference exactly (the viewer transform: equal once
##     viewer and readFrom are removed, for every member as viewer);
##   * removing any of three entries (the first, a middle and the last in canonical order)
##     changes the fingerprint of every epoch at or before that entry's epoch and of no
##     later epoch; adding a fresh message in the last epoch changes every fingerprint.
## Run by hand (no argv), it checks all 24 with doAssert.

import std/[strutils, random, sequtils]
import ./room_map_room
import ./oracle_emit

const N = 24
const Logs = ["safe", "split", "forged-and-refused", "two-admissions"]
const Transforms = ["reversed", "shuffled-a", "shuffled-b", "duplicated", "after-variants", "each-viewer"]

proc build(li: int): MapRoom =
  var r = newMapRoom("/muster/1/map-same-" & $li & "/proto")
  case li
  of 0:
    r.say("alice", "hello"); r.discloseSafe("alice", "treasury")
    let id = r.proposeSafe("pay the auditor")
    r.approve("alice", id); r.approve("bob", id); r.say("bob", "done")
    r.settleSafe(id, "0x" & "5e".repeat(32))
  of 1:
    r.join("carol", false)
    let id = r.proposeSplit("dinner")
    r.approve("bob", id); r.approve("carol", id)
    r.payPart("bob", id, "0x" & "b0".repeat(32)); r.confirmPart("bob", id, "0x" & "b0".repeat(32))
    r.payPart("carol", id, "0x" & "ca".repeat(32)); r.confirmPart("carol", id, "0x" & "ca".repeat(32))
  of 2:
    r.say("alice", "hello")
    let id = r.proposeSafe("pay the auditor")
    r.approve("alice", id)
    # a message naming alice that she never signed: the room drops it
    let (_, forged) = newMessageEvent(alice, int64(Now), "forged in alice's name", 99)
    r.bob.publish(forged)
    # an approval from a key that is no owner: in the log, never counted
    r.bob.publish(contributeEvent(id, "0x" & "de".repeat(20), "00"))
    r.sync()
  else:
    let id = r.proposeSafe("pay the auditor")
    r.join("carol", true)
    r.approve("alice", id); r.approve("bob", id)
    r.say("carol", "carol here")
    r.settleSafe(id, "0x" & "5e".repeat(32))
    r.join("dave", false)
    r.say("dave", "dave here")
  r

proc strip(j: JsonNode): JsonNode =
  result = j.copy()
  result.delete("viewer"); result.delete("readFrom")

proc fpOf(g: RoomGraph): Table[int, string] =
  for f in g.toJson()["fingerprints"].getElems(): result[f["fromEpoch"].getInt()] = f["digest"].getStr()

proc correct(k: int): bool =
  let li = k div Transforms.len
  let ti = k mod Transforms.len
  let r = build(li)
  r.alice.poll()
  let events = r.alice.roomEvents()
  let sealed = r.alice.sealedIn
  let founders = foundersOf(events, r.alice.rosterHex())
  proc mapOver(evs: seq[Event], viewer = alice): RoomGraph =
    reduceRoomGraph(evs, mapFor, founders, viewer, sealed)
  let reference = $mapOver(events).toJson()
  var rnd = initRand(1000 + k)
  case Transforms[ti]
  of "reversed":
    if $mapOver(events.reversed()).toJson() != reference: return false
  of "shuffled-a", "shuffled-b":
    var s = events
    rnd.shuffle(s)
    if $mapOver(s).toJson() != reference: return false
  of "duplicated":
    var s = events & events
    rnd.shuffle(s)
    if $mapOver(s).toJson() != reference: return false
  of "after-variants":
    # copies differing only in `after`: the same SET of copies in any order maps the same
    var copies = events
    for e in events:
      var c = e
      c.after = @[eventId(events[rnd.rand(events.len - 1)]), eventId(events[rnd.rand(events.len - 1)])]
      copies.add c
    var other = copies
    rnd.shuffle(other)
    if $mapOver(copies).toJson() != $mapOver(other).toJson(): return false
  else:
    let base = strip(mapOver(events).toJson())
    for (who, _) in r.members:
      if $strip(mapOver(events, idHex(ksFor(who))).toJson()) != $base: return false
  # fingerprints: an entry removed changes exactly the epochs at or before it
  let fp0 = fpOf(mapOver(events))
  let ordered = canonicalOrder(events)
  for pick in [0, ordered.len div 2, ordered.len - 1]:
    let gone = eventId(ordered[pick])
    let ep = sealed.getOrDefault(gone, 0)
    let fp1 = fpOf(mapOver(events.filterIt(eventId(it) != gone)))
    for e, d in fp0:
      let changed = fp1.getOrDefault(e, "") != d
      if changed != (e <= ep): return false
  # a fresh message in the last epoch changes every fingerprint
  var fresh = newMessageEvent(alice, int64(Now) + 7777, "a line nobody else holds", 7777)[1]
  var sealed2 = sealed
  var lastEp = 0
  for _, ep in sealed: lastEp = max(lastEp, ep)
  sealed2[eventId(fresh)] = lastEp
  let fp2 = fpOf(reduceRoomGraph(events & @[fresh], mapFor, founders, alice, sealed2))
  for e, d in fp0:
    if fp2.getOrDefault(e, "") == d: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert correct(k), "case " & $k & ": log " & Logs[k div Transforms.len] & ", " &
                         Transforms[k mod Transforms.len] & " — the same log drew a different map"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
