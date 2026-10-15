## derived-exo-4d0.4 s1: every member's client folds the room's file events to the same
## index — the same files, each with the same sharer, name, size, digest, CID, key,
## retraction and seeders — whatever the order or duplication of the events; a seeder's
## state is their newest announce by (at, event id), resolved the same way everywhere.
##
## STEPPER: over eight genuine events — Alice shares A, Bob shares B, Alice seeds A, Bob
## seeds A then stops, Carol seeds B and stops at the SAME `at` (a tie only the event id
## breaks), Alice retracts A. State = which event is delivered first (eight states, chained
## head -> head+1); each state folds every order of the remaining seven through the REAL
## fold (reduceSwarm), as-is AND with every event delivered twice — all 8! = 40320 orders
## across the eight states — and requires each to equal the identity order's index. Every
## state also folds every SUBSET of the eight (256) through the hosted read path
## (authenticEvents, then reduceSwarm) and requires it to match the rule stated alone:
##   * a file is present iff its share is;
##   * for each (file, member), the seed event with the largest (at, event id) decides,
##     and the member is listed iff that event is a start;
##   * a file is retracted iff its sharer's retract is present.
## Run by hand (no argv), it checks all 40320 orders and 256 subsets with doAssert.

import std/[algorithm, tables]
import ./swarm_room
import ./oracle_emit

let (fidA, shareA) = share(aliceKs, 1, 100, "a.pdf")
let (fidB, shareB) = share(bobKs, 2, 101, "b.pdf")
let events = @[
  shareA,                                  # 0
  shareB,                                  # 1
  seed(aliceKs, fidA, true, 102),          # 2
  seed(bobKs, fidA, true, 110),            # 3
  seed(bobKs, fidA, false, 120),           # 4 Bob stops: newer than his start
  seed(carolKs, fidB, true, 130),          # 5 Carol starts…
  seed(carolKs, fidB, false, 130),         # 6 …and stops at the same time: the id decides
  retract(aliceKs, fidA, 140)]             # 7

type Rule = tuple[fid, sharer, cid, key, digest: string, retracted: bool, seeders: seq[string]]

proc ruleOf(subset: set[0 .. 7]): seq[Rule] =
  ## The rule, computed without reduceSwarm.
  proc seedOn(i: int): bool = i in {2, 3, 5}
  proc seedFile(i: int): string = (if i in {2, 3, 4}: fidA else: fidB)
  proc seedWho(i: int): string =
    if i == 2: alice elif i in {3, 4}: bob else: carol
  proc seedAt(i: int): int64 =
    if i == 2: 102 elif i == 3: 110 elif i == 4: 120 else: 130
  for (si, fid, sharer, n) in [(0, fidA, alice, 1'u8), (1, fidB, bob, 2'u8)]:
    if si notin subset: continue
    var newest = initTable[string, int]()
    for i in 2 .. 6:
      if i notin subset or seedFile(i) != fid: continue
      let w = seedWho(i)
      if w notin newest: (newest[w] = i; continue)
      let mine = (seedAt(i), eventId(events[i]))
      let held = (seedAt(newest[w]), eventId(events[newest[w]]))
      if mine > held: newest[w] = i
    var listed: seq[string]
    for w, i in newest:
      if seedOn(i): listed.add w
    listed.sort()
    let b = blob(n)
    result.add (fid, sharer, cidOf(n), hx(b.key), hx(b.digest), fid == fidA and 7 in subset, listed)
  result.sort(proc(x, y: Rule): int = cmp(x.fid, y.fid))

proc asRule(idx: seq[SwarmFile]): seq[Rule] =
  for f in idx: result.add (f.fid, f.sharer, f.cid, f.key, f.digest, f.retracted, f.seederIds)
  result.sort(proc(x, y: Rule): int = cmp(x.fid, y.fid))

let reference = reduceSwarm(events)
doAssert asRule(reference) == ruleOf({0 .. 7}), "the reference index is the rule's"

proc subsetsCorrect(): bool =
  for mask in 0 ..< 256:
    var evs: seq[Event]
    var has: set[0 .. 7]
    for i in 0 ..< 8:
      if (mask and (1 shl i)) != 0: (evs.add events[i]; has.incl i)
    if asRule(index(evs)) != ruleOf(has): return false
  true

proc correct(perm: seq[int]): bool =
  var order: seq[Event]
  for e in perm: order.add events[e]
  reduceSwarm(order) == reference and reduceSwarm(order & order) == reference

proc headCorrect(h: int): bool =
  if not subsetsCorrect(): return false
  var rest: seq[int]
  for i in 0 ..< events.len:
    if i != h: rest.add i
  while true:
    if not correct(@[h] & rest): return false
    if not rest.nextPermutation(): break
  true

proc state(h: int): JsonNode = %*{"case": h, "decision_correct": headCorrect(h)}

let arg = oracleStateArg()
if arg == nil:
  doAssert subsetsCorrect(), "a subset folds to an index other than the rule's"
  var p = @[0, 1, 2, 3, 4, 5, 6, 7]
  var n = 0
  while true:
    doAssert correct(p), "order " & permString(p) & " folds to a different index"
    inc n
    if not p.nextPermutation(): break
  doAssert n == 40320
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod events.len)])
