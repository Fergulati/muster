## derived-exo-4d0.4 s4: a member admitted at a later epoch holds no share — no CID, no
## key — of a file shared before their epoch, and lists no seeder announced before it; once
## a member shares the same file again in the later epoch, the newcomer holds it, credited
## to the re-sharer, with the same CID, key and digest.
##
## STEPPER: one state per case, chained case -> case+1. Each case builds a REAL room:
## sessions over LocalTransport, keys from EpochCrypto. Alice founds it with Bob (epoch 0);
## for J = 2 Dave is admitted first (epoch 1); then Carol, the newcomer, is admitted at
## epoch J. "Before" is the epoch just before Carol's, J-1; "after" is J. Cases are
##   J in {1, 2} x Alice's share of A {before, after} x Alice's seed of A {before, after}
##   x Bob re-shares A after Carol joins, and seeds his re-share {no, yes}
## (sixteen). Carol's session catches up from the store at the end. Correct iff:
##   * Carol's raw log holds no event that was published before her epoch;
##   * her index (authenticEvents, then reduceSwarm) holds A iff Alice shared it after she
##     joined — credited to Alice, A's seeders being Alice iff Alice's seed came after too;
##   * it holds Bob's re-share iff he made one — credited to Bob, with A's CID, key and
##     digest, seeded by Bob;
##   * it holds nothing else.
## Run by hand (no argv), it checks every case with doAssert.

import std/[sets, sequtils]
import ./swarm_room
import ./oracle_emit
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/coordination/session

let daveKs = newInMemoryKeystore(block: (var a: array[32, byte]; a[0] = 0x75; a),
                                 block: (var a: array[32, byte]; a[0] = 0x85; a))
const caseCount = 16

proc correct(c: int): bool =
  let J = 1 + (c div 8)
  let shareAfter = (c div 4) mod 2 == 1
  let seedAfter = (c div 2) mod 2 == 1
  let reshare = c mod 2 == 1

  let net = newLocalNetwork()
  let founder = newEpochCrypto(aliceKs, Room, @[bobKs.encIdentity()])
  let bobC = newEpochJoiner(bobKs)
  bobC.ingestGrant(founder.grantFor(0, bobKs.encIdentity()))
  let aliceS = newCoordinationSession(newLocalTransport(net), founder, Room)
  let bobS = newCoordinationSession(newLocalTransport(net), bobC, Room)
  if J == 2:
    founder.addMember(daveKs.encIdentity())
    bobC.ingestGrant(founder.grantFor(1, bobKs.encIdentity()))

  var early = initHashSet[string]()
  let (fidA, raw) = shareEvent(alice, "a.pdf", "application/pdf", cidOf(1), Net, blob(1), 100)
  let seedA = seedEvent(fidA, alice, true, "16UiuAlice", @["/ip4/10.0.0.1/tcp/8500"], Net, 101)
  proc post(e: Event, isEarly: bool) =
    let signed = signAuthored(aliceKs, Room, e)
    aliceS.publishAuthored(aliceKs, e)
    if isEarly:
      for x in aliceS.log.allVariants():
        if x.key == signed.key: early.incl eventId(x)

  if not shareAfter: post(raw, true)
  if not seedAfter: post(seedA, true)

  founder.addMember(carolKs.encIdentity())
  bobC.ingestGrant(founder.grantFor(J, bobKs.encIdentity()))
  let carolC = newEpochJoiner(carolKs)
  carolC.ingestGrant(founder.grantFor(J, carolKs.encIdentity()))
  let carolS = newCoordinationSession(newLocalTransport(net), carolC, Room)

  if shareAfter: post(raw, false)
  if seedAfter: post(seedA, false)
  var fid2 = ""
  if reshare:
    let (ok, f) = fileById(reduceSwarm(bobS.roomEvents()), fidA)
    if not ok: return false
    let (id2, again) = reshareEvent(bob, f, 300)
    fid2 = id2
    bobS.publishAuthored(bobKs, again)
    bobS.publishAuthored(bobKs, seedEvent(fid2, bob, true, "16UiuBob", @["/ip4/10.0.0.2/tcp/8500"], Net, 301))
  carolS.catchUp()

  for e in carolS.log.allVariants():
    if eventId(e) in early: return false
  let idx = reduceSwarm(carolS.roomEvents())
  let want = (if shareAfter: 1 else: 0) + (if reshare: 1 else: 0)
  if idx.len != want: return false
  let (hasA, a) = fileById(idx, fidA)
  if hasA != shareAfter: return false
  if hasA:
    if a.sharer != alice or a.key != hx(blob(1).key): return false
    if a.seederIds != (if seedAfter: @[alice] else: @[]): return false
  if reshare:
    let (has2, r) = fileById(idx, fid2)
    if not has2 or r.sharer != bob or r.seederIds != @[bob]: return false
    let b = blob(1)
    if r.cid != cidOf(1) or r.key != hx(b.key) or r.digest != hx(b.digest) or r.size != b.size:
      return false
  true

proc state(c: int): JsonNode = %*{"case": c, "decision_correct": correct(c)}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount: doAssert correct(c), "case " & $c
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
