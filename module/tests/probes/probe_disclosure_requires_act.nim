## s2 — nothing is disclosed without an act; entering a room discloses the encryption
## identity and nothing else (contracts/specs/derived-exo-45e, oracle c2; property/trace).
##
## Random sequences over a room on an in-process network, three people. The operations that
## are NOT acts: asking to join, admitting, posting a chat message, catching up, and reading
## (the intents fold, the messages, the pending list). The one act: an approval, which
## publishes the approver's key binding (keyBindingEvent, as an in-app approval does). After
## every step the probe reads everything that leaves an instance — every frame the store node
## holds, every join request a member opens, every event in every member's log — and checks
## that a person who has NOT acted appears there by nothing but their encryption identity:
##   - every join request, opened as a member opens it, is exactly one JoinRequest (identity,
##     room, expiry, one Ed25519 signature) and nothing else. A secp key need not appear as
##     bytes to be disclosed: the old request's binding carried none, yet its signature
##     recovered the address. So the shape is checked, not only the bytes (a negative
##     control below proves the check flags an old binding);
##   - no secp address or public key (compressed, or its x coordinate), in bytes or in hex,
##     in any frame, opened request or log event;
##   - every key-binding event names someone who acted.
##
## exo-a87 is the regression this holds: until 2026-10-11 a join request carried a binding
## signed by the asker's secp key, so asking to join disclosed their address.
## Emits {"traces": [[{step, disclosure_only_after_act}, …], …]}; self-asserts too.

import std/[sequtils, strutils]
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/crypto/keystore
import ../../src/crypto/binding
import ../../src/crypto/conversation
import ../../src/coordination/session
import ../../src/coordination/intent_events
import ./oracle_emit

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)]
proc contains(hay, needle: openArray[byte]): bool =
  if needle.len == 0 or needle.len > hay.len: return false
  for i in 0 .. hay.len - needle.len:
    var ok = true
    for j in 0 ..< needle.len:
      if hay[i + j] != needle[j]: ok = false; break
    if ok: return true

var rngState: uint64 = 0x2545F4914F6CDD1D'u64
proc nextR(n: int): int =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  int((rngState shr 33) mod uint64(n))

type Person = object
  name: string
  ks: Keystore
  crypto: ConversationCrypto
  sess: CoordinationSession
  acted: bool

const FrameJoinRequest = 0x01'u8   # session.nim's kind byte for a sealed join request

proc onlyARequest(plain: seq[byte]): bool =
  ## The opened plaintext is one JoinRequest and nothing else: it decodes, and re-encodes
  ## to exactly these bytes.
  try: encodeJoinRequest(decodeJoinRequest(plain)) == plain
  except CatchableError: false

# negative control: the request exo-a87 replaced (a secp-signed binding) is flagged
block:
  let ks = newInMemoryKeystore(seed(0x7f), seed(0x6f))
  doAssert not onlyARequest(encodeLink(ks.bindingFor(LinkContext(account: "/muster/1/x/proto", slot: "0", expiry: 9)))),
    "the probe must flag an old secp-signed binding as more than a request"
  doAssert onlyARequest(encodeJoinRequest(ks.joinRequestFor("/muster/1/x/proto", 9)))

proc secrets(p: Person): seq[seq[byte]] =
  ## The bytes that would disclose p's secp key: the address, the compressed public key,
  ## its x coordinate.
  let pub = p.ks.btcPubKey()
  @[@(p.ks.address()), pub, pub[1 .. ^1]]

var opened, acts, admitted = 0   # coverage: the traces did open requests, admit and act

proc runTrace(t: int, steps: int): seq[JsonNode] =
  let topic = "/muster/1/disclosure-" & $t & "/proto"
  let net = newLocalNetwork()
  var people: seq[Person]
  for i, nm in ["alice", "bob", "carol"]:
    let ks = Keystore(newInMemoryKeystore(seed(byte(0x31 + i + 4 * t)), seed(byte(0x41 + i + 4 * t))))
    let crypto: ConversationCrypto = if i == 0: newEpochCrypto(ks, topic) else: newEpochJoiner(ks)
    people.add Person(name: nm, ks: ks, crypto: crypto,
                      sess: newCoordinationSession(newLocalTransport(net), crypto, topic))
  proc member(i: int): bool = people[i].ks.encIdentity() in people[0].sess.members()
  var bindingAuthors: seq[string]   # addresses of every key-binding event an act published
  for step in 0 ..< steps:
    let op = ["ask", "admit", "message", "read", "catchup", "approve"][nextR(6)]
    let i = nextR(3)
    case op
    of "ask":
      if not member(i): discard people[i].sess.requestJoin(people[i].ks.joinRequestFor(topic, high(uint64)))
    of "admit":
      # any member admits whoever is pending (a member decides)
      for j in 0 ..< 3:
        if member(j):
          for m in people[j].sess.pendingJoins(): people[j].sess.admit(m)
          break
    of "message":
      if member(i):
        people[i].sess.publish(Event(key: "msg/" & $t & "/" & $step, value: people[i].name & " says hi"))
    of "read":
      for p in people:
        discard reduceMessages(p.sess.log.allEvents())   # a fold: reading discloses nothing
        discard p.sess.pendingJoins()
        discard p.sess.members()
    of "catchup":
      people[i].sess.catchUp()
    of "approve":
      # the act: an approval publishes the approver's key binding into the room's log
      if member(i):
        let a = hexOf(people[i].ks.address())
        let st = people[i].ks.bindingFor(LinkContext(account: "intent-0x" & $t, slot: "0", expiry: high(uint64)))
        people[i].sess.publish(keyBindingEvent("0x" & $t, a, hexOf(encodeLink(st))))
        people[i].acted = true
        inc acts
        bindingAuthors.add a
    else: discard

    # ── what left, after this step ──
    let frames = newLocalTransport(net).storeQuery(topic).mapIt(it.payload)
    var outward = frames
    var ok = true
    # every join request, opened by whoever can open it
    for f in frames:
      if f.len > 1 and f[0] == FrameJoinRequest:
        for p in people:
          var plain: seq[byte]
          try: plain = p.crypto.openJoinRequest(f[1 .. ^1])
          except CatchableError: continue
          if not onlyARequest(plain): ok = false
          outward.add plain
          inc opened
    var logText = ""
    for p in people:
      for e in p.sess.log.allEvents(): logText.add e.key & "\n" & e.value & "\n"
    for p in people:
      if p.acted: continue
      for s in p.secrets():
        if outward.anyIt(it.contains(s)): ok = false
        if logText.toLowerAscii.contains(hexOf(s)): ok = false
    for p in people:
      for e in p.sess.log.allEvents():
        let parts = e.key.split('/')
        if parts.len >= 4 and parts[0] == "intent" and parts[2] == "binding" and parts[3] notin bindingAuthors:
          ok = false
    result.add %*{"step": op, "disclosure_only_after_act": ok}
  admitted += people[0].sess.members().len - 1

var traces: seq[seq[JsonNode]]
for t in 0 ..< 12: traces.add runTrace(t, 14)
emitTraces(traces)
var allHeld = true
for tr in traces:
  for s in tr:
    if not s["disclosure_only_after_act"].getBool: allHeld = false
doAssert allHeld, "a secp key left an instance before its owner acted"
doAssert opened > 0 and acts > 0 and admitted > 0,
  "the traces must open join requests (" & $opened & "), admit (" & $admitted & ") and act (" & $acts & ")"
stderr.writeLine "probe_disclosure_requires_act: OK (12 traces of 14 steps; ", opened, " join requests opened, ",
  admitted, " admitted, ", acts, " acts; nothing disclosed before an act)"
