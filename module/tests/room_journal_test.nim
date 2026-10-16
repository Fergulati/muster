## A room's own copy on the member's machine (exo-dcc.14). A room used to live only as long
## as the fleet's store kept it: Muster rebuilt it from the store and the keystore alone.
## Now each member keeps the frames it has seen — still sealed, as they travel — and
## rebuilds the room from them plus its keys (invariant 4), the store being catch-up.
##   1. the journal keeps data and grant frames once each, in order, and survives a reload;
##      beacons, join requests and invites are not kept (they are not the room's state)
##   2. a damaged journal reads as what it validly holds, never a raise
##   3. replay puts grants first, so a later epoch's data opens on replay
##   4. a member whose store copy is gone rebuilds the room from its journal and keystore:
##      the members, and what was said in every epoch it was admitted to
## Needs libsecp256k1 + libsodium (see tests/README.md).

import std/[os, strutils, sequtils]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/coordination/session
import ../src/coordination/room_journal

proc key(hex: string): array[32, byte] =
  var h = hex
  if h.len >= 2 and h[0] == '0' and (h[1] == 'x' or h[1] == 'X'): h = h[2 .. ^1]
  for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

let dir = getTempDir() / ("muster-room-journal-test-" & $getCurrentProcessId())
removeDir(dir)
let path = dir / "room.journal"

block file:
  var j = openJournal(path)
  doAssert j.record(@[0x00'u8, 1, 2, 3]), "a data frame is kept"
  doAssert j.record(@[0x02'u8, 9, 9]), "a grant frame is kept"
  doAssert not j.record(@[0x00'u8, 1, 2, 3]), "the same frame is kept once"
  for k in [0x01'u8, 0x03, 0x04, 0x05]:
    doAssert not j.record(@[k, 7, 7]), "kind " & $k & " is not the room's state"
  doAssert not j.record(@[]), "nothing is not a frame"
  let again = openJournal(path)
  doAssert again.frames() == @[@[0x00'u8, 1, 2, 3], @[0x02'u8, 9, 9]], $again.frames()
  doAssert again.replayOrder() == @[@[0x02'u8, 9, 9], @[0x00'u8, 1, 2, 3]], "grants first"
  echo "1. data and grants, once each, in order, across a reload; nothing else OK"

block damaged:
  let f = open(path, fmAppend)
  f.write("\xff\xff\xff\x7f partial")          # a length past the end: a torn write
  f.close()
  let j = openJournal(path)
  doAssert j.frames().len == 2, "a torn tail reads as the frames before it"
  echo "2. a damaged journal reads as what it validly holds OK"

removeDir(dir)

block rebuild:
  let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
  let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
  let carolKs = newInMemoryKeystore(key("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"), seed(3))
  const topic = "/muster/1/room-journal/proto"
  let bobPath = dir / "bob.journal"
  let net = newLocalNetwork()
  let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
  doAssert alice.admitInvited(bobKs.encIdentity())
  # Bob keeps a journal from the moment he joins
  var bj = openJournal(bobPath)
  let bob = newCoordinationSession(newLocalTransport(net), newEpochJoiner(bobKs), topic)
  bob.setJournal(proc(p: seq[byte]) {.gcsafe.} = {.cast(gcsafe).}: discard bj.record(p))
  bob.catchUp()
  alice.publish(Event(key: "msg/1", value: "epoch-one"))
  bob.publish(Event(key: "msg/2", value: "bob-says"))
  # Carol is admitted: a re-key; then more is said in the new epoch
  doAssert alice.admitInvited(carolKs.encIdentity())
  alice.publish(Event(key: "msg/3", value: "epoch-two"))
  doAssert bob.log.allEvents().anyIt(it.value == "epoch-two"), "Bob followed the re-key live"
  # the store loses the room (a fresh network has none of it); Bob relaunches
  let empty = newLocalNetwork()
  let bob2 = newCoordinationSession(newLocalTransport(empty), newEpochJoiner(bobKs), topic)
  bob2.catchUp()
  doAssert bob2.log.allEvents().len == 0, "no store copy: nothing from the store"
  bob2.replay(openJournal(bobPath).replayOrder())
  let vals = bob2.log.allEvents().mapIt(it.value)
  for v in ["epoch-one", "bob-says", "epoch-two"]:
    doAssert v in vals, v & " rebuilt from the journal: " & $vals
  doAssert carolKs.encIdentity() in bob2.members(), "the later epoch's roster too"
  echo "3-4. grants first; the room rebuilt from the journal and the keystore alone OK"

block founder:
  # 5. the founder too: its own later epochs come back from its journal and keystore
  let aliceKs = newInMemoryKeystore(key("0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
  let bobKs   = newInMemoryKeystore(key("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"), seed(2))
  const topic = "/muster/1/room-journal-founder/proto"
  let aPath = dir / "alice.journal"
  var aj = openJournal(aPath)
  let net = newLocalNetwork()
  let alice = newCoordinationSession(newLocalTransport(net), newEpochCrypto(aliceKs, topic), topic)
  alice.setJournal(proc(p: seq[byte]) {.gcsafe.} = {.cast(gcsafe).}: discard aj.record(p))
  alice.publish(Event(key: "msg/0", value: "founded"))
  doAssert alice.admitInvited(bobKs.encIdentity())
  alice.publish(Event(key: "msg/1", value: "after-admit"))
  let alice2 = newCoordinationSession(newLocalTransport(newLocalNetwork()), newEpochCrypto(aliceKs, topic), topic)
  alice2.replay(openJournal(aPath).replayOrder())
  let vals = alice2.log.allEvents().mapIt(it.value)
  doAssert "founded" in vals and "after-admit" in vals, "the founder's every epoch: " & $vals
  doAssert bobKs.encIdentity() in alice2.members()
  echo "5. the founder rebuilds every epoch from its journal OK"

removeDir(dir)
echo "room_journal_test: all OK"
