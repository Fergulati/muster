## A spend from a Monero multisig wallet over the room (ADR-020 S3, exo-dcc.34.3). Three
## members, a 2-of-3 set up over the room, each with their own (scripted) wallet;
## xmr_msig_spend_regtest_e2e runs real wallets.
##   1. agree: no wallet is asked anything before M members agreed; the first M round-1
##      approvals are the signer set; the member outside it signs nothing; round 2 is never
##      sent for a member on the intents tick (liveNextRounds), only after their wallet signed;
##   2. sync, build, sign, submit: the builder builds the AGREED spend, the next signer signs
##      what it described, the last submits; one set reaches the chain, with the agreed
##      recipients and M signatures; final on every member at 10 confirmations, not before;
##   3. a builder whose wallet built something else publishes nothing;
##   4. a co-signer handed a set that is not the agreed spend refuses and signs nothing;
##   5. one spend per wallet in flight: a second agreed spend waits until the first is final.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, tables]
import ../src/log/log
import ../src/drivers/[driver, kinds, xmr_msig]
import ../src/intents/lifecycle
import ../src/monero/address
import ../src/crypto/[keystore, curve25519]
import ../src/coordination/[session, accounts, intents, intent_events, live, xmr_msig_setup, xmr_msig_spend]
import ./probes/[live_room, fake_xmr_msig, fake_monero]

proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let ks = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ids = ks.mapIt(idOf(it))
let Stage = caip2Of(xmrStagenet)
let dest = walletAddress("landlord", xmrStagenet, 2)

type Room = object
  ss: seq[CoordinationSession]
  ws: seq[FakeSpendWallet]
  account: RoomAccount
  policy: string

proc pollAll(r: Room) = (for s in r.ss: s.poll())
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = nil)

proc setupRoom(topic: string): Room =
  let r3 = newRoom3(topic)
  result.ss = @[r3.alice, r3.bob, r3.carol]
  result.ws = @[newFakeSpendWallet("alice-" & topic), newFakeSpendWallet("bob-" & topic),
                newFakeSpendWallet("carol-" & topic)]
  doAssert xmrSetupOpen(result.ss[0], "w", Stage, 2, ids) == ""
  result.pollAll()
  for i in 0 ..< 3: doAssert xmrSetupJoin(result.ss[i], ks[i], "w") == ""
  for _ in 0 ..< 8:
    result.pollAll()
    for i in 0 ..< 3: discard xmrSetupStep(result.ss[i], ks[i], result.ws[i], "w")
  result.pollAll()
  let accts = reduceAccounts(result.ss[0].log.allEvents()).filterIt(it.family == XmrMsigFamily)
  doAssert accts.len == 1 and xmrMsigAccountOf(accts[0]).ok
  result.account = accts[0]
  result.policy = qualify("xmr-msig", accts[0].id)

proc spendJson(r: Room, amount = "1000", memo = "rent"): string =
  xmrMsigSpendJson(Stage, r.account.address, @[XmrRecipient(address: dest, amount: amount)], "500", memo)

proc propose(r: Room, effect: string): string =
  result = liveProposeIntent(r.ss[0], aliceKs, res(r.ss[0]), r.policy, effect, int64(Now), 1,
                             account = r.account.address, ttlSec = Ttl)
  doAssert result.startsWith("0x"), result
  r.pollAll()

proc agree(r: Room, i: int, id: string): string =
  result = liveContribute(r.ss[i], ks[i], res(r.ss[i]), id, "", "", bindCtx(), Now)
  r.pollAll()

proc stepAll(r: Room, id: string): seq[string] =
  r.pollAll()
  for i in 0 ..< 3: result.add xmrSpendStep(r.ss[i], ks[i], r.ws[i], res(r.ss[i]), id, Now)
  r.pollAll()

# ── 1–2. an honest spend, end to end ─────────────────────────────────────────
block:
  fakeChain = newFakeXmrChain()
  var r = setupRoom("/muster/1/xmr-spend/honest")
  let id = r.propose(r.spendJson())
  doAssert r.stepAll(id).allIt(it.startsWith("waiting: agreement")), "nothing before M agreed"
  doAssert r.ws.allIt(it.exports == 0)
  doAssert r.agree(0, id) == "collecting"
  doAssert r.agree(2, id) == "collecting", "round 1 closes; round 2 is open"
  let set = signerSet(r.ss[0].roomEvents(), res(r.ss[0]), id, 2, ids)
  doAssert set.len == 2 and ids[1] notin set, $set
  doAssert liveNextRounds(r.ss[0], aliceKs, res(r.ss[0]), proc(x: string): LinkContext = bindCtx(), Now).len == 0,
    "round 2 is never sent for a member on the tick"
  let outsideCalls = r.ws[1].calls
  var trace: seq[seq[string]]
  for _ in 0 ..< 6:
    trace.add r.stepAll(id)
    if fakeChain.sets.len > 0: break
  doAssert fakeChain.sets.len == 1, $trace
  doAssert trace.anyIt(it[1] == "not-a-signer")
  doAssert r.ws[1].calls == outsideCalls and r.ws[1].exports == 0, "the member outside the set did nothing"
  let onChain = parseJson(block:
    var s = ""
    let h = fakeChain.sets[0]
    for i in countup(0, h.len - 2, 2): s.add char(parseHexInt(h[i .. i + 1]))
    s)
  doAssert onChain["recipients"] == %*[[dest, "1000"]] and onChain["signers"].len == 2
  echo "1. agreement: nothing before M; the first M are the signer set; round 2 never sent on the tick OK"
  doAssert r.stepAll(id).allIt(it.startsWith("waiting: your wallet has not seen") or it.startsWith("seen")), "submitted, not final"
  fakeChain.mine(5)
  doAssert r.stepAll(id).allIt(it == "seen 5 of 10")
  fakeChain.mine(5)
  discard r.stepAll(id)
  for s in r.ss:
    doAssert reduceIntents(s.roomEvents(), res(s))[id].state == lsFinal
  echo "2. sync, build, check, sign, submit: one set on chain, the agreed spend, M signatures; final at 10 OK"

# ── 3. a builder whose wallet built something else ───────────────────────────
block:
  fakeChain = newFakeXmrChain()
  var r = setupRoom("/muster/1/xmr-spend/builder")
  let id = r.propose(r.spendJson())
  discard r.agree(0, id)
  discard r.agree(2, id)
  let set = signerSet(r.ss[0].roomEvents(), res(r.ss[0]), id, 2, ids)
  for i in 0 ..< 3: r.ws[i].tamper = "amount"
  var outs: seq[seq[string]]
  for _ in 0 ..< 4: outs.add r.stepAll(id)
  doAssert outs.anyIt(it.anyIt(it.startsWith("refused: what your wallet built is not the agreed spend"))), $outs
  doAssert not r.ss[0].roomEvents().anyIt(it.key.contains("/xtx/")), "the builder published nothing"
  doAssert fakeChain.sets.len == 0 and set.len == 2
  echo "3. a builder whose wallet built another spend publishes nothing OK"

# ── 4. a co-signer handed a set that is not the agreed spend ─────────────────
block:
  fakeChain = newFakeXmrChain()
  var r = setupRoom("/muster/1/xmr-spend/cosigner")
  let id = r.propose(r.spendJson())
  discard r.agree(0, id)
  discard r.agree(2, id)
  let set = signerSet(r.ss[0].roomEvents(), res(r.ss[0]), id, 2, ids)
  let b = ids.find(set[0])
  let c = ids.find(set[1])
  discard r.stepAll(id)                       # both synced; the builder would build next
  r.ws[b].tamper = "recipient"
  # the builder's wallet built a spend to someone else, and it is published unchecked
  # (as a builder outside Muster could): the co-signer must catch it
  discard r.ws[b].importInfo(@["sync:" & r.ws[c].id & ":1"])
  let forged = r.ws[b].transfer(@[(dest, "1000")])
  for e in blobEvents(id, "xtx", set[0], forged): r.ss[b].publishAuthored(ks[b], e)
  r.pollAll()
  let before = r.ws[c].calls
  let got = xmrSpendStep(r.ss[c], ks[c], r.ws[c], res(r.ss[c]), id, Now)
  doAssert got.startsWith("refused: the set is not the agreed spend") and got.contains("recipients"), got
  doAssert r.ws[c].calls == before and fakeChain.sets.len == 0
  echo "4. a co-signer handed another spend refuses, signs nothing OK"

# ── 5. one spend in flight per wallet ────────────────────────────────────────
block:
  fakeChain = newFakeXmrChain()
  var r = setupRoom("/muster/1/xmr-spend/inflight")
  let first = r.propose(r.spendJson(memo = "first"))
  let second = r.propose(r.spendJson(memo = "second"))
  for id in [first, second]:
    discard r.agree(0, id)
    discard r.agree(2, id)
  # the earlier in the log's canonical order goes first: the same one for every member
  let a1 = r.stepAll(first)
  let a2 = r.stepAll(second)
  let waits = proc(o: seq[string]): bool = o.filterIt(it != "not-a-signer").allIt(it.startsWith("waiting: an earlier spend"))
  doAssert waits(a1) != waits(a2), $a1 & " / " & $a2
  let (goes, waiting) = (if waits(a2): (first, second) else: (second, first))
  for _ in 0 ..< 6: discard r.stepAll(goes)
  doAssert r.stepAll(waiting).filterIt(it != "not-a-signer").allIt(it.startsWith("waiting: an earlier spend"))
  fakeChain.mine(10)
  discard r.stepAll(goes)
  doAssert reduceIntents(r.ss[0].roomEvents(), res(r.ss[0]))[goes].state == lsFinal
  doAssert not r.stepAll(waiting).anyIt(it.startsWith("waiting: an earlier spend")), "the second proceeds once the first is final"
  echo "5. a second spend from the wallet waits until the first is final OK"
