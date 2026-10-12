## derived-exo-dde s3: `after`, the causal-order annotation, never reaches state.
## Stripping or rewriting it on any event leaves unchanged the state digest, every fold
## the room's decisions read, and every byte a member signs (invariants 4, 5, 10).
##
## STEPPER: state = one case of log {a settled Safe payment with in-app approvals and their
## attestations, a split paid in parts, a room where a member joined mid-proposal and the
## proposal was re-announced to her} — each from REAL sessions and real drivers, whose
## events already carry the `after` their publishers stamped — x rewrite of EVERY event's
## `after` {stripped, the honest heads of another arrival order, random ids from the log,
## a reference to itself, references to events later in the log (cycles), ids from no room
## at all, 64-id lists}: 21 cases, chained case -> case+1. The case is judged correct iff,
## between the log as published and the rewritten log, these are byte-identical:
##   * the state digest, the intent views, the information flow and the log's provenance;
##   * for every proposal: P (the attestation payload every approval signs), its inputs,
##     the parents an approval would carry, its lineage and its approval grades, and the
##     audit file a member exports for it;
##   * the log proof's digest, and which author-signed events verify.
## Run by hand (no argv), it checks all 21 with doAssert.

import std/[strutils, random, sequtils]
import ./room_map_room
import ./oracle_emit
import ../../src/log/proof
import ../../src/coordination/audit

const N = 21
const Logs = ["safe-settled", "split-paid", "joined-mid-proposal"]
const Rewrites = ["stripped", "another-arrival", "random-ids", "self", "forward-cycles", "foreign-ids", "sixty-four"]

proc build(li: int): MapRoom =
  var r = newMapRoom("/muster/1/after-state-" & $li & "/proto")
  case li
  of 0:
    r.say("alice", "hello")
    let id = r.proposeSafe("pay the auditor")
    r.approve("alice", id); r.approve("bob", id)
    r.settleSafe(id, "0x" & "5e".repeat(32))
  of 1:
    r.join("carol", false)
    let id = r.proposeSplit("dinner")
    r.approve("bob", id); r.approve("carol", id)
    r.payPart("bob", id, "0x" & "b0".repeat(32)); r.confirmPart("bob", id, "0x" & "b0".repeat(32))
  else:
    let id = r.proposeSafe("pay the auditor")
    r.approve("alice", id)
    r.join("carol", true)
    r.approve("bob", id)
    r.say("carol", "carol here")
  r

proc intentIds(evs: seq[Event]): seq[string] =
  for e in evs:
    let p = strutils.split(e.key, '/')
    if p.len >= 3 and p[0] == "intent" and p[2] == "propose" and p[1] notin result: result.add p[1]
  result.sort()

proc hexs(b: seq[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc derived(raw: seq[Event], topic: string, founders: seq[string], sealed: Table[string, int]): seq[string] =
  let evs = authenticEvents(raw, topic)
  result.add reduce(evs).stateDigest
  result.add $reduceIntentViews(evs, mapFor)
  result.add $reduceFlow(evs, mapFor, founders, sealed).toJson()
  result.add $logProvenance(evs, mapFor, sealed)
  for id in intentIds(evs):
    result.add hexs(attestationPayload(evs, mapFor, id))
    result.add $intentInputs(evs, mapFor, id)
    result.add $approvalParents(evs, mapFor, id)
    result.add $toSeq(lineageIds(evs, mapFor, id)).sorted()
    # the grade, who and round, and WHICH event counted (by id); the grade echoes the event
    # object itself, whose `after` is the input being rewritten, so it is compared by id
    result.add $approvalGrades(evs, mapFor, id).mapIt((it.who, it.round, $it.grade, eventId(it.sig)))
    let a = exportAudit(raw, mapFor, id, aliceKs)
    result.add $a.ok & "|" & a.reason & "|" & hexs(a.bytes)
  result.add proofDigest(buildProof(evs))
  result.add $evs.mapIt(eventId(it)).sorted()

proc rewrite(raw: seq[Event], how: string, rnd: var Rand): seq[Event] =
  let ids = raw.mapIt(eventId(it))
  let order = canonicalOrder(raw).mapIt(eventId(it))
  var arrival = raw
  rnd.shuffle(arrival)
  var prevIn = initTable[string, string]()
  for i in 1 ..< arrival.len: prevIn[eventId(arrival[i])] = eventId(arrival[i - 1])
  for e in raw:
    var x = e
    let id = eventId(e)
    x.after = case how
      of "stripped": @[]
      of "another-arrival": (if id in prevIn: @[prevIn[id]] else: @[])
      of "random-ids": (var a: seq[string]; (for _ in 0 .. rnd.rand(2): a.add ids[rnd.rand(ids.len - 1)]); a)
      of "self": @[id]
      of "forward-cycles":
        let at = order.find(id)
        (var a: seq[string]; (for j in at + 1 .. min(at + 3, order.len - 1): a.add order[j]); a)
      of "foreign-ids": @[toSeq(0 ..< 32).mapIt("ab").join(""), toSeq(0 ..< 32).mapIt("cd").join("")]
      else: (var a: seq[string]; (for _ in 0 ..< 64: a.add ids[rnd.rand(ids.len - 1)]); a)
    result.add x

proc correct(k: int): bool =
  let li = k div Rewrites.len
  let ri = k mod Rewrites.len
  let r = build(li)
  r.alice.poll()
  let raw = r.alice.log.allEvents()
  let sealed = r.alice.sealedIn
  let founders = foundersOf(r.alice.roomEvents(), r.alice.rosterHex())
  doAssert raw.anyIt(it.after.len > 0), "the published log must carry the after its publishers stamped"
  var rnd = initRand(500 + k)
  let want = derived(raw, r.topic, founders, sealed)
  let got = derived(rewrite(raw, Rewrites[ri], rnd), r.topic, founders, sealed)
  if want.len != got.len: return false
  for i in 0 ..< want.len:
    if want[i] != got[i]: return false
  true

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    doAssert correct(k), "case " & $k & ": log " & Logs[k div Rewrites.len] & ", after " &
                         Rewrites[k mod Rewrites.len] & " — something a decision reads or a member signs changed"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
