## Membership grant handshake over the coordination session (the piece that lets a
## joiner actually get an epoch key without a side channel). A join-request carries
## no authority; a member decides to admit; the grant travels as an opaque control
## frame on the same topic. F-16 must still hold over the wire: the newly admitted
## member reads messages from their epoch on, and NOTHING from before their seam.
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/strutils
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/join_request
import ../src/coordination/session

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))

proc seed(b: byte): array[32, byte] =
  for i in 0 ..< 32: result[i] = b

let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
let malKs   = newInMemoryKeystore(key("0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"), seed(3))
let bobPub = bobKs.encIdentity()

const topic = "/muster/1/handshake/proto"
let net = newLocalNetwork()

# Alice founds the room (epoch 0, just her). Bob starts outside it entirely.
let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)

# Alice says something before Bob is admitted — this is the pre-seam history.
alice.publish(Event(key: "msg/1", value: "before-bob"))
doAssert bob.log.allEvents().len == 0, "Bob holds no key yet — cannot read epoch 0"
echo "1. outsider cannot read the room OK"

# Bob asks to join as his encryption identity, signed by it for this room. The request
# carries no authority and no secp key (exo-a87); Alice sees it as pending.
bob.requestJoin(bobKs.joinRequestFor(topic, high(uint64)))
doAssert bobPub in alice.pendingJoins(), "Alice sees Bob's join-request as pending"
doAssert bob.log.allEvents().len == 0, "a join-request alone admits nobody"
echo "2. join-request is discovery, not entry OK"

# exo-a87: Bob's request names his encryption identity and nothing else, signed by that
# identity. Asking in someone else's name is refused: Mallory sends a request naming Carol,
# signed with Mallory's key, and Alice never sees Carol pending. A request for another room
# is dropped too.
block:
  let carolPub = newInMemoryKeystore(seed(9), seed(4)).encIdentity()
  let mallory = newCoordinationSession(newLocalTransport(net), newEpochJoiner(malKs), topic)
  var forged = malKs.joinRequestFor(topic, high(uint64))
  forged.enc = carolPub
  mallory.requestJoin(forged)
  doAssert carolPub notin alice.pendingJoins(), "a request in another's name is dropped"
  mallory.requestJoin(malKs.joinRequestFor("/muster/1/elsewhere/proto", high(uint64)))
  doAssert malKs.encIdentity() notin alice.pendingJoins(), "a request for another room is dropped"
  var bobReq: JoinRequest
  for r in alice.pendingRequests():
    if r.enc == bobPub: bobReq = r
  doAssert joinRequestValid(bobReq, topic, 0), "Bob's own request verifies"
  let wire = encodeJoinRequest(bobReq)
  doAssert decodeJoinRequest(wire) == bobReq and wire.len == 64 + 2 + topic.len + 8 + 64,
    "the request is the identity, the room, an expiry and one Ed25519 signature: no secp key"
echo "3. a request is signed by the identity it names, and names nothing else OK"

# Alice admits Bob: re-key forward, grants published on the topic. Bob ingests his.
alice.admit(bobPub)
doAssert bobPub notin alice.pendingJoins(), "the request is cleared once admitted"
echo "4. member admits the joiner OK"

# Now Alice speaks in the new epoch; Bob can read it — the handshake worked.
alice.publish(Event(key: "msg/2", value: "after-bob"))
var sawAfter = false
for e in bob.log.allEvents():
  if e.key == "msg/2" and e.value == "after-bob": sawAfter = true
doAssert sawAfter, "Bob reads messages from his epoch onward"
echo "5. admitted member reads new messages OK"

# F-16 over the wire: Bob still cannot read the pre-admission message. He was
# granted only the new epoch's key, never epoch 0's.
for e in bob.log.allEvents():
  doAssert e.value != "before-bob", "F-16: the joiner must not read pre-seam history"
echo "6. F-16 holds across the handshake OK"

echo "membership_handshake_test: all OK"

# ── the admit is IN the log (exo-275 / M4): both members fold it; Bob sees his own
# admission and nothing from before his seam ─────────────────────────────────────
block:
  var aliceAdmits, bobAdmits = 0
  for e in alice.log.allEvents(): (if e.key.startsWith("membership/"): inc aliceAdmits)
  for e in bob.log.allEvents(): (if e.key.startsWith("membership/"): inc bobAdmits)
  doAssert aliceAdmits >= 1 and bobAdmits >= 1, "the admit is a log event on both sides"
  var aliceKeys: seq[string]
  for e in alice.log.allEvents(): aliceKeys.add e.key
  for e in bob.log.allEvents():
    doAssert e.key in aliceKeys, "everything Bob holds, Alice holds"
  doAssert bob.log.allEvents().len < alice.log.allEvents().len, "Bob cannot read the pre-seam history (F-16)"
  echo "admit recorded in the log; Bob's view starts at his own admission (F-16) OK"
