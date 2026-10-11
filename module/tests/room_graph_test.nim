## The room map's projection (G1, exo-da4; docs/design/room-map.md §4): the room as
## nodes and edges folded from the log, adding no truth of its own.
##   1. every held entry is a node; edges name only nodes; seqs stay within the log
##   2. an approval hangs from its key until a VERIFIED binding ties that key to a member
##   3. what left is placed where it left, per observer, with the manifest's fields
##   4. reorder + duplication give the identical graph (invariant 4)
##   5. two members' graphs of one log differ only in viewer and readFrom (invariant 9)
##   6. a later joiner's graph holds nothing from before its admission (invariant 7)
##   7. structure, never content: no message body, effect value or chain reference
##   8. a report the fold refused stays in the graph, unattributed
## Stub + parts drivers; the binding is a real secp256k1 statement (libsodium + secp).

import std/[json, strutils, sequtils, sets, algorithm, tables]
import ./fixtures/parts_driver
import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/curve25519
import ../src/drivers/driver
import ../src/log/log
import ../src/coordination/intents
import ../src/coordination/room_graph

proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
proc secret(h: string): array[32, byte] = (for i in 0 ..< 32: result[i] = byte(parseHexInt(h[2*i .. 2*i+1])))
proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

# alice holds a real keystore: her member id is her encryption identity, her approval key
# a secp256k1 address, and the binding between them is a real statement
let ks = newInMemoryKeystore(secret("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"), seed(1))
let alice = hex(ks.encIdentity().toBytes())
let aliceKey = "0x" & hex(ks.address())
let bob = "b0b".repeat(4)
let carol = "ca7".repeat(4)

let stub: DriverFor = proc(kind: string): Driver =
  newStubDriver(rounds = 1, threshold = 1, finality = finExternal, verifyResult = true)
let pdrv = PartsDriver()
let both: DriverFor = proc(kind: string): Driver =
  (if kind == "parts": Driver(pdrv) else: stub(kind))

let effectJson = """{"to":"0xdeadbeefcafe","value":424242}"""
let idA = intentIdFor(effectJson)
let link = ks.bindingFor(LinkContext(account: "room", slot: "0", expiry: 2_000_000_000'u64))
let (_, msg) = newMessageEvent(alice, 1, "a secret note", 1)

# epoch 0: alice and bob; alice proposes A and approves it with her key, bound to her
# epoch 1: carol is admitted; A is submitted and final; a split among bob and carol runs
let pEffect = partsEffect([bob, carol], alice)
let idB = intentIdFor(pEffect, "parts")
let story = chain(@[msg,
  proposerEvent(idA, alice), proposeEvent(idA, effectJson),
  contributeEvent(idA, aliceKey, "sa"), keyBindingEvent(idA, aliceKey, hex(encodeLink(link))),
  membershipEvent(1, carol),
  submitEvent(idA, chainRef = "0xfeedface"), finalEvent(idA, chainRef = "0xfeedface"),
  policyDeclEvent(idB, "parts"), proposeEvent(idB, pEffect),
  contributeEvent(idB, bob, hexName(bob)), contributeEvent(idB, carol, hexName(carol)),
  contributeEvent(idB, "mallory", hexName("mallory")),
  partEvent(idB, bob, "settled", "mallory", "0xforged"),
  partEvent(idB, bob, "settled", bob, "0xb0bpaid")])
let founders = @[alice, bob]

proc node(g: RoomGraph, id: string): GraphNode =
  for n in g.nodes: (if n.id == id: return n)
  doAssert false, "no node " & id
proc hasNode(g: RoomGraph, id: string): bool = g.nodes.anyIt(it.id == id)
proc edgesOf(g: RoomGraph, kind: string): seq[GraphEdge] = g.edges.filterIt(it.kind == kind)
proc entryOf(g: RoomGraph, key: string, evs: seq[Event]): GraphNode =
  for e in canonicalOrder(evs): (if e.key == key: return g.node("e:" & eventId(e)))
  doAssert false, "no entry " & key

let g = reduceRoomGraph(story, both, founders, alice)

block:
  doAssert g.seqMax == story.len - 1
  doAssert g.nodes.countIt(it.kind == "entry") == story.len, "every held entry is a node"
  let ids = g.nodes.mapIt(it.id).toHashSet()
  for e in g.edges:
    doAssert e.src in ids and e.dst in ids, "edge names a missing node: " & $e
    doAssert e.seq >= 0 and e.seq <= g.seqMax
  for n in g.nodes: doAssert n.seq >= -1 and n.seq <= g.seqMax
  doAssert g.edgesOf("parent").len == story.len - 1, "the hash links, one per parent held"
  doAssert g.hasNode("m:" & alice) and g.hasNode("m:" & bob) and g.hasNode("m:" & carol)
  doAssert g.node("m:" & carol).seq >= 0 and g.node("m:" & carol).attrs["joined"].getInt() == 1
  doAssert g.epochs.len == 2 and g.epochs[1].admitted == carol
  doAssert g.hasNode("i:" & idA) and g.node("i:" & idA).attrs["state"].getStr() == "final"
  doAssert g.edgesOf("proposed").anyIt(it.src == "m:" & alice and it.dst == "i:" & idA)
  doAssert g.edgesOf("input").anyIt(it.dst == "i:" & idA and it.attrs["kind"].getStr() == "propose")
  echo "1. every held entry is a node; edges name only nodes; members, epochs, intents OK"

block:
  # alice's approval is driver-counted under her KEY; the verified binding ties it to her
  let ap = g.edgesOf("approved").filterIt(it.dst == "i:" & idA)
  doAssert ap.len == 1 and ap[0].src == "k:" & aliceKey, $ap
  doAssert g.edgesOf("bound").anyIt(it.src == "m:" & alice and it.dst == "k:" & aliceKey)
  # a binding naming a key its statement's signer is not ties nothing
  let forged = story & @[keyBindingEvent(idA, "0x" & "11".repeat(20), hex(encodeLink(link)))]
  let gf = reduceRoomGraph(forged, both, founders, alice)
  doAssert not gf.edgesOf("bound").anyIt(it.dst == "k:0x" & "11".repeat(20))
  echo "2. an approval hangs from its key; only a verified binding ties the key to a member OK"

block:
  let lv = g.edgesOf("leaves")
  let submitSeq = g.entryOf("intent/" & idA & "/submit", story).seq
  doAssert lv.anyIt(it.src == "i:" & idA and it.dst == "o:chain-observer" and it.seq == submitSeq)
  doAssert lv.allIt(it.seq >= submitSeq or it.src != "i:" & idA), "nothing of A leaves before submit"
  # the split: bob's counted settle leaves with the manifest's fields; the forged one does not
  let bobPaid = canonicalOrder(story).mapIt(it.key).find("intent/" & idB & "/part/" & bob & "/settled")
  let splitOut = lv.filterIt(it.src == "i:" & idB and it.dst == "o:chain-observer")
  doAssert splitOut.len == 1, $splitOut
  doAssert splitOut[0].attrs["fields"].getElems().mapIt(it.getStr()) == @["amount", "payer"]
  doAssert splitOut[0].seq > bobPaid, "the counted report is the later one, by bob himself"
  doAssert g.hasNode("o:store-node") and g.node("o:store-node").seq == -1
  doAssert g.edgesOf("enters").anyIt(it.src == "o:outside" and it.attrs["kind"].getStr() == "final")
  echo "3. what left is placed where it left, per observer, with the declared fields OK"

block:
  var shuffled = story.reversed()
  shuffled.add story[3]; shuffled.add story[0]
  doAssert $reduceRoomGraph(shuffled, both, founders, alice).toJson() == $g.toJson()
  echo "4. reorder + duplicate → identical graph (inv 4) OK"

block:
  var a = reduceRoomGraph(story, both, founders, alice).toJson()
  var c = reduceRoomGraph(story, both, founders, carol).toJson()
  doAssert a["viewer"].getStr() == alice and c["viewer"].getStr() == carol
  doAssert a["readFrom"].getInt() == 0 and c["readFrom"].getInt() == 1
  for k in ["viewer", "readFrom"]: (a.delete(k); c.delete(k))
  doAssert $a == $c, "the map says the same about the room to every member who holds the log"
  echo "5. two members' graphs of one log differ only in viewer and readFrom OK"

block:
  # carol's client opens nothing sealed before her admission: what she holds starts there
  let o = canonicalOrder(story)
  var at = 0
  while not o[at].key.startsWith("membership/"): inc at
  let held = o[at .. ^1]
  let gc = reduceRoomGraph(held, both, founders, carol)
  doAssert gc.readFrom == 1
  for n in gc.nodes:
    if n.kind == "entry": doAssert n.epoch >= 1, "an entry from before her admission: " & $n
  for e in o[0 ..< at]: doAssert not gc.hasNode("e:" & eventId(e))
  doAssert not gc.hasNode("i:" & idA), "an intent proposed before she joined is not on her map"
  doAssert not gc.hasNode("k:" & aliceKey), "nor the key that approved it"
  doAssert gc.hasNode("i:" & idB)
  echo "6. a later joiner's graph holds nothing from before its admission (inv 7) OK"

block:
  let s = $g.toJson()
  for secret in ["a secret note", "deadbeefcafe", "424242", "feedface", "b0bpaid", "forged"]:
    doAssert secret notin s, "content on the wire: " & secret
  echo "7. structure, never content OK"

block:
  # mallory is not a party: her approval and bob's part "settled" by her stay, unattributed
  let o = canonicalOrder(story)
  let mal = g.node("e:" & eventId(o[o.mapIt(it.key).find("intent/" & idB & "/sig/mallory/1")]))
  doAssert not mal.attrs["counted"].getBool() and not mal.attrs.hasKey("account"), $mal
  doAssert not g.hasNode("m:mallory") and not g.hasNode("k:mallory")
  doAssert not g.edgesOf("approved").anyIt(it.src.endsWith("mallory"))
  let forgedPart = g.entryOf("intent/" & idB & "/part/" & bob & "/settled", story)   # the first: mallory's
  doAssert not forgedPart.attrs["counted"].getBool() and not forgedPart.attrs.hasKey("account")
  echo "8. a report the fold refused stays in the graph, unattributed OK"

block:
  # a room-key approval ("ed:<the member's Ed25519 key>", the split's) is that member's own:
  # the key is the first half of the member's identity, and the driver verified it signed
  let edAlice = "ed:" & alice[0 ..< 64]
  let idC = intentIdFor("""{"to":"0xc","value":3}""")
  let evs = chain(@[proposeEvent(idC, """{"to":"0xc","value":3}"""), contributeEvent(idC, edAlice, "sc"),
                    contributeEvent(idC, "ed:" & "ab".repeat(32), "sd")])
  let gk = reduceRoomGraph(evs, both, founders, alice)
  doAssert gk.edgesOf("approved").anyIt(it.src == "m:" & alice and it.dst == "i:" & idC), $gk.edgesOf("approved")
  doAssert not gk.nodes.anyIt(it.id == "k:" & edAlice)
  doAssert gk.nodes.anyIt(it.id == "k:ed:" & "ab".repeat(32)), "a room key that is no member's stays a key"
  echo "9. a room-key approval hangs from the member whose identity holds that key OK"

block:
  # parentless events sort by content id, so log position says nothing about epoch: find
  # an epoch-1 message whose id sorts BEFORE the admission that opened epoch 1
  let admit = membershipEvent(1, carol)
  var late: Event
  for n in 0 .. 500:
    late = Event(key: "message/late" & $n, value: "{}")
    if eventId(late) < eventId(admit): break
  doAssert eventId(late) < eventId(admit)
  let evs = @[admit, late]
  var sealedIn = initTable[string, int]()
  sealedIn[eventId(late)] = 1; sealedIn[eventId(admit)] = 1
  proc epochOfLate(g: RoomGraph): int = g.node("e:" & eventId(late)).epoch
  doAssert reduceRoomGraph(evs, both, founders, alice).epochOfLate == 0, "the position fallback is wrong here"
  doAssert reduceRoomGraph(evs, both, founders, alice, sealedIn).epochOfLate == 1
  echo "10. an entry's epoch is the one whose key opened it, wherever it sorts OK"

block:
  # C4 (exo-6b8): positions are causal, and each proposal carries its state per step.
  # Five roots published in this order, each naming the one before in `after`; their ids
  # sort otherwise, so canonical order would scramble them.
  let effectS = """{"to":"0xs","value":5}"""
  let idS = intentIdFor(effectS)
  var evs: seq[Event]
  for e in @[proposerEvent(idS, alice), proposeEvent(idS, effectS), contributeEvent(idS, "0xk1", "s1"),
             submitEvent(idS), finalEvent(idS)]:
    var x = e
    if evs.len > 0: x.after = @[eventId(evs[^1])]
    evs.add x
  let gs = reduceRoomGraph(evs.reversed(), both, founders, alice)
  var bySeq: seq[(int, string)]
  for n in gs.nodes:
    if n.kind == "entry": bySeq.add (n.seq, n.attrs["kind"].getStr())
  bySeq.sort()
  doAssert bySeq.mapIt(it[1]) == @["proposer", "propose", "sig", "submit", "final"], $bySeq
  # the proposal's state after each of its entries is the fold over the causal prefix
  let steps = gs.node("i:" & idS).attrs["steps"].getElems()
  doAssert steps.mapIt(it["state"].getStr()) == @["proposed", "executable", "submitted", "final"], $steps
  for st in steps:
    let k = st["seq"].getInt()
    let prefix = causalOrder(evs)[0 .. k]
    var want = ""
    for v in reduceIntentViews(prefix, both): (if v.id == idS: want = v.state)
    doAssert st["state"].getStr() == want
  echo "11. positions are causal; a proposal's state per step is the fold over the causal prefix OK"

echo "room_graph_test: all OK"
