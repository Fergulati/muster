## A Monero multisig set up over the room (ADR-020 S2, exo-dcc.34.2). Three members, a
## 2-of-3, each with their own wallet (here a scripted one that checks the exchange's
## order as upstream's does; xmr_msig_setup_regtest_e2e runs real wallets).
##   1. opening refuses what ADR-020 rules out: another network, M of N out of range, a
##      member named twice, a private regtest unless a test allows it;
##   2. nobody's wallet is asked anything until every member has joined;
##   3. the exchange runs over the log, each wallet's round r only once every member's
##      round r-1 is there; all three wallets end ready with one address, each member
##      discloses it, and only then is it an account the room acts from (xmr-msig@<id>);
##   4. one member's word is not the wallet: an account fewer than all its members
##      disclosed, or disclosed differently, is refused;
##   5. a wallet that is already multisig, or on another network, is refused, never run;
##      an outsider is not a participant; a round message forged in another member's name
##      is not part of the ceremony;
##   6. nothing but the open, joins and the wallets' own exchange messages enters the log.
## Needs the secp closure + stint + libsodium — see tests/README.md.

import std/[json, strutils, sequtils, tables]
import ../src/log/log
import ../src/drivers/[driver, kinds, xmr_msig]
import ../src/monero/address
import ../src/crypto/[keystore, curve25519]
import ../src/coordination/[session, accounts, authorship, xmr_msig_setup]
import ./probes/[live_room, fake_xmr_msig]

proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

var r = newRoom3("/muster/1/xmr-msig-setup/proto")
let ks = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ss = @[r.alice, r.bob, r.carol]
let ids = ks.mapIt(idOf(it))
let ws = @[newFakeMsigWallet("alice"), newFakeMsigWallet("bob"), newFakeMsigWallet("carol")]
let Stage = caip2Of(xmrStagenet)
proc pollAll() = (for s in ss: s.poll())
proc stepAll(cid: string): seq[string] =
  pollAll()
  for i in 0 ..< 3: result.add xmrSetupStep(ss[i], ks[i], ws[i], cid)

# ── 1. what may be opened ─────────────────────────────────────────────────────
block:
  doAssert openRefusal(caip2Of(xmrMainnet), 2, ids).contains("stagenet only")
  doAssert openRefusal(Stage, 1, ids).len > 0 and openRefusal(Stage, 4, ids).len > 0
  doAssert openRefusal(Stage, 2, @[ids[0], ids[0], ids[1]]).contains("twice")
  doAssert openRefusal(Stage, 2, @[ids[0]]).len > 0
  doAssert openRefusal(XmrRegtestChain, 2, ids).contains("tests only")
  doAssert openRefusal(XmrRegtestChain, 2, ids, allowRegtest = true) == ""
  doAssert xmrSetupOpen(r.alice, "bad/id", Stage, 2, ids).len > 0
  echo "1. opening: stagenet only, 2 <= M <= N, distinct members, regtest for tests OK"

# ── 2. nothing asked of a wallet before everyone joined ───────────────────────
const Cid = "treasury-1"
doAssert xmrSetupOpen(r.alice, Cid, Stage, 2, ids) == ""
pollAll()
doAssert xmrSetupOpen(r.bob, Cid, Stage, 2, ids).contains("already open")
doAssert xmrSetupStep(r.alice, aliceKs, ws[0], Cid).contains("not joined")
doAssert xmrSetupJoin(r.alice, aliceKs, Cid) == ""
doAssert xmrSetupJoin(r.bob, bobKs, Cid) == ""
pollAll()
doAssert xmrSetupStep(r.alice, aliceKs, ws[0], Cid) == "waiting: 2 of 3 members joined"
doAssert ws.allIt(it.calls == 0), "no wallet is asked anything before every member joined"
doAssert xmrSetupJoin(r.carol, room3CarolKs, Cid) == ""
echo "2. no wallet is asked anything until every member joined OK"

# ── 3. the exchange over the log ──────────────────────────────────────────────
var outcomes: seq[string]
var trace: seq[seq[string]]
# a busy wallet (one syncing against a remote node holds its lock) is waited for, never
# refused: a refusal would end the member's part in the setup (stagenet, 2026-10-16)
ws[1].busy = 2
pollAll()
doAssert xmrSetupStep(r.bob, bobKs, ws[1], Cid).startsWith("waiting: your wallet did not answer")
for step in 0 ..< 8:
  outcomes = stepAll(Cid)
  trace.add outcomes
pollAll()
doAssert outcomes.allIt(it.startsWith("done ")), $trace
let msigAddr = outcomes[0].split(' ')[1]
doAssert outcomes.allIt(it == "done " & msigAddr)
doAssert ws.allIt(it.ready and it.k == 2 and it.n == 3)
let accts = reduceAccounts(r.bob.log.allEvents()).filterIt(it.family == XmrMsigFamily)
doAssert accts.len == 1 and accts[0].address == msigAddr and accts[0].threshold == 2
doAssert accts[0].signers == ids and ids.allIt(it in accts[0].disclosedBy)
let (ok, acct, why) = xmrMsigAccountOf(accts[0])
doAssert ok, "account refused: " & why
doAssert acct.k == 2 and acct.members == ids and acct.chain == Stage
let d = driverForPolicy(qualify("xmr-msig", accts[0].id), accts, proc(k: string): Driver = nil)
doAssert d of XmrMsigDriver and XmrMsigDriver(d).account.address == msigAddr
doAssert xmrSetupStep(r.alice, aliceKs, ws[0], Cid) == "done " & msigAddr, "idempotent once done"
echo "3. a 2-of-3 over the room (a busy wallet waited for): three wallets ready, one address, disclosed by all three, xmr-msig@ acts OK"

# ── 4. one member's word is not the wallet ────────────────────────────────────
block:
  var a = accts[0]
  a.disclosedBy = ids[0 .. 1]
  doAssert not xmrMsigAccountOf(a).ok and xmrMsigAccountOf(a).detail.contains("have not disclosed")
  doAssert driverForPolicy(qualify("xmr-msig", a.id), @[a], proc(k: string): Driver = nil) of UnsupportedDriver
  var c = accts[0]
  c.conflict = true
  doAssert not xmrMsigAccountOf(c).ok
  var t = accts[0]
  t.threshold = 1
  doAssert not xmrMsigAccountOf(t).ok
  echo "4. an account fewer than all its members disclosed, or disclosed differently, is refused OK"

# ── 5. refusals: a used wallet, another network, an outsider, a forgery ───────
block:
  var r2 = newRoom3("/muster/1/xmr-msig-setup/refusals")
  doAssert xmrSetupOpen(r2.alice, "t2", Stage, 2, ids) == ""
  r2.alice.poll(); r2.bob.poll(); r2.carol.poll()
  for (s, k) in [(r2.alice, Keystore(aliceKs)), (r2.bob, Keystore(bobKs)), (r2.carol, Keystore(room3CarolKs))]:
    doAssert xmrSetupJoin(s, k, "t2") == ""
  r2.alice.poll(); r2.bob.poll(); r2.carol.poll()
  let used = newFakeMsigWallet("used")
  used.multisig = true
  doAssert xmrSetupStep(r2.alice, aliceKs, used, "t2").startsWith("refused: the wallet is already a multisig")
  let main = newFakeMsigWallet("mainnet-wallet", net = xmrMainnet)
  doAssert xmrSetupStep(r2.alice, aliceKs, main, "t2").contains("another Monero network")
  doAssert used.calls == 0 and main.calls == 0
  # Bob publishes a round-0 message under Alice's name: the room's authentic view drops it
  r2.bob.publish(Event(key: "xmsig/t2/kex/0/" & ids[0], value: $(%*{"info": "0:mallory"})))
  r2.alice.poll()
  doAssert ids[0] notin xmrSetupView(r2.alice.roomEvents(), "t2").kex.getOrDefault(0)
  var k9, s9: array[32, byte]
  for i in 0 ..< 32: (k9[i] = 9; s9[i] = 99)
  let outsider = newInMemoryKeystore(k9, s9)
  doAssert xmrSetupStep(r2.alice, outsider, newFakeMsigWallet("x"), "t2") == "not-a-participant"
  doAssert xmrSetupJoin(r2.alice, outsider, "t2").contains("not one of its members")
  echo "5. a used wallet or another network refused, never run; an outsider is not in it; a forged round is dropped OK"

# ── 6. what the log holds ────────────────────────────────────────────────────
block:
  for e in r.alice.log.allEvents():
    let p = e.key.split('/')
    if p[0] != "xmsig": continue
    doAssert p[2] in ["open", "join", "kex"], e.key
    if p[2] == "kex":
      let j = parseJson(e.value)
      doAssert toSeq(j.keys).filterIt(it notin ["info", AuthorSigField]).len == 0, e.value
  echo "6. the log holds the open, the joins and the wallets' own exchange messages, nothing else OK"
