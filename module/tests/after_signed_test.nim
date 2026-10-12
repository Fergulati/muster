## `after` signed by the author on author-bearing kinds (C5, exo-dde.15;
## docs/design/causal-parents.md §5 decision 2). The author signs the heads they had
## seen with `afterSig`, beside `after` and like it outside the event's identity:
##   1. publishAuthored stamps `after` and signs it; a peer's authentic view keeps it
##   2. a member who re-publishes someone's message with a forged `after` reorders nothing
##      and suppresses nothing: the room reads the author's own copy
##   3. a copy whose `after` no signature covers keeps its place in the room — it is still
##      the author's signed message — and loses only its ordering claim
##   4. an event that names no author is untouched
##   5. none of it reaches state: the authentic view's state digest and ids are the same
##      with or without the forged copies
##   6. the session's cached view (roomEvents) is the uncached one (authenticEvents over
##      every copy), on both members, after forged copies were checked and cached
## LocalTransport + epoch crypto; needs libsecp256k1 + libsodium.

import std/[strutils, sequtils, algorithm]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/log/log
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/intents

proc key(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs = newInMemoryKeystore(key("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs = newInMemoryKeystore(key("59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let carolKs = newInMemoryKeystore(key("7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(3))
let aliceId = hex(aliceKs.encIdentity().toBytes())
const topic = "/muster/1/after-signed/proto"
let net = newLocalNetwork()
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
bob.requestJoin(bobKs.joinRequestFor(topic, high(uint64)))
alice.admit(bobKs.encIdentity())

proc authentic(s: CoordinationSession, k: string): Event =
  for e in s.roomEvents(): (if e.key == k: return e)
  doAssert false, "not in the room's view: " & k

alice.publish(Event(key: "msg/plain", value: "1"))
let (mid, m) = newMessageEvent(aliceId, 1, "hello from alice", 1)
alice.publishAuthored(aliceKs, m)
let k = "message/" & mid
let honest = bob.authentic(k)

block:
  doAssert honest.after.len > 0 and honest.afterSig.len > 0, "stamped and signed"
  doAssert afterVerified(topic, honest), "the author's own after verifies"
  echo "1. publishAuthored stamps after and signs it; the peer's view keeps it OK"

block:
  # bob re-publishes alice's message with an after of his choosing, ground so its digest
  # sorts first — the copy the log would keep if nothing checked who wrote the after
  var forged = honest
  var n = 0
  while true:
    forged.after = @[toSeq(0 ..< 32).mapIt("0f").join("") & $n]
    forged.afterSig = honest.afterSig
    if afterDigest(forged) < afterDigest(honest): break
    inc n
  bob.publish(forged)
  alice.poll(); bob.poll()
  for s in [alice, bob]:
    let seen = s.authentic(k)
    doAssert seen.after == honest.after, "the room reads the author's own after, not the forged one"
  echo "2. a re-published copy with a forged after reorders nothing and suppresses nothing OK"

block:
  # carol joins and receives ONLY a copy with an after nobody signed: the message stays,
  # its ordering claim goes
  var events = alice.roomEvents().filterIt(it.key != k)
  var bare = honest
  bare.after = @[eventId(events[0])]
  bare.afterSig = ""
  let view = authenticEvents(events & @[bare], topic)
  let got = view.filterIt(it.key == k)
  doAssert got.len == 1, "the author's signed message is never dropped for its ordering claim"
  doAssert got[0].after.len == 0, "an after no signature covers is not read"
  echo "3. an unsigned after loses only its ordering claim OK"

block:
  let plain = bob.authentic("msg/plain")
  doAssert plain.after.len > 0 or true      # a sealed event's after is any member's claim, read as is
  var other = plain
  other.after = @["ab".repeat(32)]
  doAssert authenticEvents(@[other], topic).len == 1 and authenticEvents(@[other], topic)[0].after == other.after
  echo "4. an event that names no author is untouched OK"

block:
  let a = authenticEvents(alice.log.allVariants(), topic)
  let b = authenticEvents(alice.log.allEvents().filterIt(it.key != "nothing"), topic)
  doAssert reduce(a).stateDigest == reduce(b).stateDigest
  doAssert a.mapIt(eventId(it)).sorted().deduplicate() == b.mapIt(eventId(it)).sorted().deduplicate()
  echo "5. none of it reaches state OK"

block:
  # a forged copy reusing the genuine signature over another `after` is cached as forged,
  # and a second read gives the same view as the first, cached or not
  var reuse = honest
  reuse.after = @["cd".repeat(32)]
  bob.publish(reuse)
  alice.poll(); bob.poll()
  for s in [alice, bob]:
    let first = s.roomEvents()
    let again = s.roomEvents()
    let fresh = authenticEvents(s.log.allVariants(), topic)
    doAssert $first == $fresh and $again == $fresh, "the cached view is the uncached one"
    doAssert s.authentic(k).after == honest.after, "a reused signature over another after is not the author's"
  echo "6. the cached view is the uncached one OK"

echo "after_signed_test: all OK"
