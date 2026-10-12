## derived-exo-dde s1: a later joiner's room map holds nothing from before its admission.
## Every entry, proposal and approval key on it comes from an event its own session
## decrypted, and none from an epoch whose key it was never granted (invariant 7, F-16) —
## content included, since the map carries each entry's content.
##
## STEPPER: state = one case of admission point {after the founding message and account,
## after the proposal, after the first approval, after settlement, Carol after the proposal
## and Dave after settlement} x {re-announced to the joiner, not} x family {a Safe payment
## (external finality, settled on chain), a split paid in parts}: 20 cases, chained
## case -> case+1. Each runs REAL sessions (local transport, epoch crypto, the join
## handshake) and the hosted propose / contribute / reannounce path with the real Safe and
## split drivers; every event that can carry text carries a unique marker. For each joiner,
## its map is built as coordinate_graph builds it (its session's authentic events, the epoch
## each was opened under). The case is judged correct iff, for every joiner:
##   * every entry on the map is an event the joiner's session holds, in an epoch at or
##     after the joiner's admission;
##   * no event the joiner's session does not hold reaches the map — not its id, not its
##     marker — while every held event's id and marker do (so an empty map cannot pass);
##   * a proposal is on the map only if the joiner holds its propose; an approval key only
##     if the joiner holds an approval signed with it; every edge names nodes on the map.
## Run by hand (no argv), it checks all 20 with doAssert.

import std/strutils
import ./room_map_room
import ./oracle_emit

const N = 20
const Points = ["after-founding", "after-propose", "after-approval", "after-settlement", "two-joiners"]

proc decode(k: int): tuple[point, reannounce: int, fam: Family] =
  (k div 4, (k div 2) mod 2, (if k mod 2 == 0: famSafe else: famSplit))

proc tag(k: int, what: string): string = "@@k" & $k & "-" & what & "@@"

proc story(k: int): MapRoom =
  let (point, re, fam) = decode(k)
  var r = newMapRoom("/muster/1/map-joiner-" & $k & "/proto")
  let reann = re == 1
  proc joinAt(r: var MapRoom, here: int) =
    if point == here and point != 4: r.join("carol", reann)
    if point == 4 and here == 1: r.join("carol", reann)
    if point == 4 and here == 3: r.join("dave", reann)
  r.say("alice", tag(k, "found"))
  r.discloseSafe("alice", tag(k, "acct"))
  r.joinAt(0)
  let id = (if fam == famSafe: r.proposeSafe(tag(k, "prop")) else: r.proposeSplit(tag(k, "prop")))
  r.joinAt(1)
  r.approve("bob", id)
  r.say("bob", tag(k, "mid"))
  r.joinAt(2)
  if fam == famSafe:
    r.approve("alice", id)
    r.settleSafe(id, tag(k, "settle"))
  else:
    if "carol" in r.joiners:
      try: r.approve("carol", id) except CatchableError: discard   # she agrees if she can read it
    r.payPart("bob", id, tag(k, "pay-bob"))
    r.confirmPart("bob", id, tag(k, "conf-bob"))
  r.joinAt(3)
  r.say("alice", tag(k, "after"))
  for j in ["carol", "dave"]:
    if j in r.joiners: r.say(j, tag(k, "said-" & j))
  r

proc judge(r: MapRoom, joiner: string): bool =
  let s = r.sess(joiner)
  var held = initHashSet[string]()
  for e in s.log.allEvents(): held.incl eventId(e)
  let m = r.mapOf(joiner)
  let js = $m.toJson()
  if m.readFrom < 1: return false
  var nodeIds = initHashSet[string]()
  for n in m.nodes: nodeIds.incl n.id
  for n in m.nodes:
    if n.kind == "entry":
      if n.id[2 .. ^1] notin held or n.epoch < m.readFrom: return false
    if n.kind == "intent":
      var holdsPropose = false
      for e in s.log.allEvents(): (if e.key == "intent/" & n.id[2 .. ^1] & "/propose": holdsPropose = true)
      if not holdsPropose: return false
    if n.kind == "signer":
      var signed = false
      for e in s.log.allEvents():
        let p = strutils.split(e.key, '/')
        if p.len >= 4 and p[2] == "sig" and p[3].toLowerAscii() == n.id[2 .. ^1]: signed = true
      if not signed: return false
  for e in m.edges:
    if e.src notin nodeIds or e.dst notin nodeIds: return false
  # every event anyone published: is it on the map exactly when this joiner holds it?
  var everything = initHashSet[string]()
  for (_, other) in r.members:
    for e in other.log.allEvents(): everything.incl eventId(e)
  for id in everything:
    let onMap = id in js
    let marker = r.markers.getOrDefault(id, "")
    if id in held:
      if not onMap: return false
      if marker.len > 0 and marker notin js: return false
    else:
      if onMap: return false
      # its marker may reach the map only through a copy the joiner does hold (a re-announce)
      if marker.len > 0 and marker in js:
        var viaHeldCopy = false
        for hid in held: (if r.markers.getOrDefault(hid, "") == marker: viaHeldCopy = true)
        if not viaHeldCopy: return false
  true

proc correct(k: int): bool =
  let r = story(k)
  for j in ["carol", "dave"]:
    if j in r.joiners and not r.judge(j): return false
  "carol" in r.joiners

proc state(k: int): JsonNode = %*{"case": k, "decision_correct": correct(k)}

let arg = oracleStateArg()
if arg == nil:
  for k in 0 ..< N:
    let (point, re, fam) = decode(k)
    doAssert correct(k), "case " & $k & ": " & Points[point] & ", " & (if re == 1: "re-announced" else: "not re-announced") &
                         ", " & $fam & " — a joiner's map holds something it never decrypted"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
