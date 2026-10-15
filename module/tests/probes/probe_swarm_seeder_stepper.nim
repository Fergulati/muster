## derived-exo-4d0.4 s2: a member is listed as seeding a file only by their own announce. A
## seed event counts only when signed, for this room, by the member its key names; a seed
## forged in another's name, unsigned, signed for another room, or edited after signing
## lists no one and changes nothing; the client never lists a holder from anything but a
## seed event.
##
## STEPPER: one state per case, chained case -> case+1. A case is a seed event for file A,
## naming Bob or Carol, starting or stopping, with A's share in the log or not, in one of
## seven forms:
##   genuine   — signed by the member it names, for this room
##   forged    — the same event signed by Mallory
##   unsigned  — the signature removed
##   otherroom — signed by the member it names, for another room
##   edited    — genuine, then its addresses changed
##   renamed   — Mallory's own genuine seed, moved under the member's key
##   lifted    — unsigned, carrying the member's genuine signature from their seed of file B
## plus two that name a member without a seed event: Carol re-shares A's blob under her
## own file id, and Carol posts a chat message saying she seeds A. Each case adds the
## event to a base log (Alice shares A and seeds it; Bob shares B) and reads the room the
## way the hosted module does (authenticEvents, then reduceSwarm). Correct iff:
##   * genuine, starting, with the share present: the member is listed, and the index is
##     otherwise the base index;
##   * every other seed case: the index is exactly the base index;
##   * the re-share: A's seeders are unchanged and the re-shared file lists no seeder;
##   * the chat message: the index is exactly the base index.
## Run by hand (no argv), it checks every case with doAssert.

import std/algorithm
import ./swarm_room
import ./oracle_emit
import ../../src/coordination/intent_events

let (fidA, shareA) = share(aliceKs, 1, 100, "a.pdf")
let (fidB, shareB) = share(bobKs, 2, 101, "b.pdf")
let aliceSeed = seed(aliceKs, fidA, true, 102)

const Forms = ["genuine", "forged", "unsigned", "otherroom", "edited", "renamed", "lifted"]
let members = @[bobKs, carolKs]

proc unsignedSeed(m: Keystore, fid: string, on: bool): Event =
  seedEvent(fid, idOf(m), on, "16Uiu" & idOf(m)[0 ..< 8], @["/ip4/10.0.0.1/tcp/8500"], Net, 200)

proc seedIn(form: string, m: Keystore, on: bool): Event =
  let genuine = signAuthored(m, Room, unsignedSeed(m, fidA, on))
  case form
  of "genuine": genuine
  of "forged": signedBy(malloryKs, unsignedSeed(m, fidA, on))
  of "unsigned": stripped(genuine)
  of "otherroom": signedBy(m, unsignedSeed(m, fidA, on), OtherRoom)
  of "edited": edited(genuine, "addrs", %["/ip4/6.6.6.6/tcp/1"])
  of "renamed":
    rekeyed(signAuthored(malloryKs, Room, unsignedSeed(malloryKs, fidA, on)),
            "file/" & fidA & "/seed/" & idOf(m))
  else: withSigOf(unsignedSeed(m, fidA, on), signAuthored(m, Room, unsignedSeed(m, fidB, on)))

let caseCount = Forms.len * 2 * 2 * 2 + 2

proc correct(c: int): bool =
  if c >= Forms.len * 8:
    let base = @[shareA, aliceSeed, shareB]
    let before = index(base)
    if c == Forms.len * 8:
      let (_, f) = fileById(before, fidA)
      let (fid2, again) = reshareEvent(carol, f, 300)
      let after = index(base & @[signAuthored(carolKs, Room, again)])
      let (okA, a) = fileById(after, fidA)
      let (ok2, r) = fileById(after, fid2)
      return okA and ok2 and a.seederIds == @[alice] and r.seeders.len == 0 and r.sharer == carol
    let (_, msg) = newMessageEvent(carol, 300, "I seed " & fidA, 1)
    return index(base & @[signAuthored(carolKs, Room, msg)]) == before
  let form = Forms[c div 8]
  let m = members[(c div 4) mod 2]
  let on = (c div 2) mod 2 == 0
  let withShare = c mod 2 == 0
  let base = (if withShare: @[shareA, aliceSeed, shareB] else: @[aliceSeed, shareB])
  let before = index(base)
  let after = index(base & @[seedIn(form, m, on)])
  if form == "genuine" and on and withShare:
    let (ok, f) = fileById(after, fidA)
    if not ok or idOf(m) notin f.seederIds: return false
    var expected = before
    for x in expected.mitems:
      if x.fid == fidA: x.seeders = f.seeders
    return after == expected and f.seederIds == sorted(@[alice, idOf(m)])
  after == before

proc state(c: int): JsonNode = %*{"case": c, "decision_correct": correct(c)}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount:
    doAssert correct(c), "case " & $c & " (" & (if c < Forms.len * 8: Forms[c div 8] else: "extra") & ")"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
