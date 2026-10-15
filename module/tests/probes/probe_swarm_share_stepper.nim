## derived-exo-4d0.4 s3: a file is shared only in its sharer's name. A share counts only
## when signed, for this room, by the sharer it names, and only under the file id derived
## from that sharer and its CID; a share forged in another's name or posted under another
## file's id changes nothing; only the file's sharer can retract it.
##
## STEPPER: one state per case, chained case -> case+1. Twenty-two share cases — a
## share naming Alice or Bob, in one of eleven forms:
##   genuine     — signed by the sharer it names, for this room, under its derived id
##   forged      — the same event signed by Mallory
##   unsigned    — the signature removed
##   otherroom   — signed by its sharer, for another room
##   editname, editkey, editcid — genuine, then that field changed
##   squat       — signed by its sharer, for this room, but posted under Carol's file id
##   squatfirst  — the same, re-timed until its event id sorts BEFORE Carol's share, so a
##                 fold that kept the first share per id would take Carol's file over
##   squatfree   — the same, under the id of a file Carol has not shared (no share holds it)
##   lifted      — unsigned, carrying the sharer's genuine signature from another share
## — and four retract cases on Alice's genuine share: retracted by Alice; by Bob, signing
## as himself; forged in Alice's name by Mallory; Alice's retract with its signature
## removed. Each case adds the event to a base log (Carol shares her own file) and reads
## the room the way the hosted module does (authenticEvents, then reduceSwarm). Correct
## iff:
##   * a genuine share: the index is the base index plus that file, under the id derived
##     from (sharer, CID), credited to the sharer, carrying exactly the signed name, size,
##     CID, key and digest;
##   * every other share form: the index is exactly the base index, Carol's file untouched;
##   * a retract: Alice's file is retracted iff Alice's own genuine retract is present,
##     and nothing else in the index changes.
## Run by hand (no argv), it checks every case with doAssert.

import std/strutils
import ./swarm_room
import ./oracle_emit

const Forms = ["genuine", "forged", "unsigned", "otherroom", "editname", "editkey", "editcid",
               "squat", "squatfirst", "squatfree", "lifted"]
const Retracts = ["bysharer", "byother", "forged", "unsigned"]
let sharers = @[aliceKs, bobKs]
let (fidC, shareC) = share(carolKs, 3, 90, "carol.pdf")
let base = @[shareC]

proc unsignedShare(s: Keystore, n: byte, name: string): (string, Event) =
  shareEvent(idOf(s), name, "application/pdf", cidOf(n), Net, blob(n), 100)

proc squatBefore(s: Keystore): Event =
  ## A squat under Carol's file id whose event id sorts before her genuine share's.
  var at = 100'i64
  while true:
    let (_, raw) = shareEvent(idOf(s), "s.pdf", "application/pdf", cidOf(1), Net, blob(1), at)
    result = signAuthored(s, Room, rekeyed(raw, "file/" & fidC))
    if eventId(result) < eventId(shareC): return
    inc at

proc shareIn(form: string, s: Keystore): Event =
  let (fid, raw) = unsignedShare(s, 1, "s.pdf")
  let genuine = signAuthored(s, Room, raw)
  case form
  of "genuine": genuine
  of "forged": signedBy(malloryKs, raw)
  of "unsigned": stripped(genuine)
  of "otherroom": signedBy(s, raw, OtherRoom)
  of "editname": edited(genuine, "name", %"invoice.exe")
  of "editkey": edited(genuine, "key", %("ff".repeat(32)))
  of "editcid": edited(genuine, "cid", %cidOf(9))
  of "squat": signAuthored(s, Room, rekeyed(raw, "file/" & fidC))
  of "squatfirst": squatBefore(s)
  of "squatfree": signAuthored(s, Room, rekeyed(raw, "file/" & fileIdOf(carol, cidOf(7))))
  else:
    let (_, other) = unsignedShare(s, 2, "other.pdf")
    discard fid
    withSigOf(raw, signAuthored(s, Room, other))

let caseCount = Forms.len * 2 + Retracts.len

proc correct(c: int): bool =
  let before = index(base)
  if c < Forms.len * 2:
    let form = Forms[c div 2]
    let s = sharers[c mod 2]
    let after = index(base & @[shareIn(form, s)])
    if form != "genuine": return after == before
    let fid = fileIdOf(idOf(s), cidOf(1))
    let (ok, f) = fileById(after, fid)
    if not ok or after.len != 2: return false
    let (okC, c2) = fileById(after, fidC)
    let b = blob(1)
    return okC and c2 == before[0] and f.sharer == idOf(s) and f.name == "s.pdf" and
           f.size == b.size and f.cid == cidOf(1) and f.key == hx(b.key) and
           f.digest == hx(b.digest) and not f.retracted
  let (fidA, shareA) = share(aliceKs, 1, 100, "a.pdf")
  let withA = base & @[shareA]
  let r = case Retracts[c - Forms.len * 2]
    of "bysharer": retract(aliceKs, fidA, 200)
    of "byother": retract(bobKs, fidA, 200)
    of "forged": signedBy(malloryKs, retractEvent(fidA, alice, 200))
    else: stripped(retract(aliceKs, fidA, 200))
  let plain = index(withA)
  let after = index(withA & @[r])
  var expected = plain
  if Retracts[c - Forms.len * 2] == "bysharer":
    for x in expected.mitems:
      if x.fid == fidA: x.retracted = true
  after == expected

proc state(c: int): JsonNode = %*{"case": c, "decision_correct": correct(c)}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount: doAssert correct(c), "case " & $c
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
