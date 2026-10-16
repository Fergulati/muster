## A Monero multisig set up over the room with REAL wallets (ADR-020 S2, exo-dcc.34.2):
## three members, each with their own monero-wallet-rpc, a 2-of-3 on a private regtest
## chain. Needs the chain: `infra/monero/regtest.sh up 4` first (wallet RPCs :38092-94 are
## the members' wallets). Held here:
##   1. the room carries every round between the wallets, in order, until each wallet
##      says it is ready; the three wallets report one address, and each member discloses it;
##   2. that address is what each wallet's own get_address says, every wallet is a 2-of-3,
##      and the room acts from the account (xmr-msig@<id>) only now;
##   3. stepping again asks the wallets nothing new and changes nothing.

import std/[json, strutils, sequtils, os]
import ../src/drivers/[driver, kinds, xmr_msig]
import ../src/wallet/xmr_msig_wallet
import ../src/crypto/[keystore, curve25519]
import ../src/coordination/[session, accounts, xmr_msig_setup]
import ./probes/live_room

proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let ws = @[newRpcXmrMsigWallet("http://127.0.0.1:38092"), newRpcXmrMsigWallet("http://127.0.0.1:38093"),
           newRpcXmrMsigWallet("http://127.0.0.1:38094")]
let tag = $getCurrentProcessId()
for i, w in ws: discard w.call("create_wallet", %*{"filename": "room-m" & $i & "-" & tag, "language": "English"})

var r = newRoom3("/muster/1/xmr-msig-setup-e2e/proto")
let ks = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ss = @[r.alice, r.bob, r.carol]
let ids = ks.mapIt(idOf(it))
proc pollAll() = (for s in ss: s.poll())

const Cid = "regtest-treasury"
doAssert xmrSetupOpen(r.alice, Cid, XmrRegtestChain, 2, ids, allowRegtest = true) == ""
pollAll()
for i in 0 ..< 3: doAssert xmrSetupJoin(ss[i], ks[i], Cid) == ""

var outcomes, trace: seq[string]
for step in 0 ..< 10:
  pollAll()
  outcomes = @[]
  for i in 0 ..< 3: outcomes.add xmrSetupStep(ss[i], ks[i], ws[i], Cid)
  trace.add $outcomes
  if outcomes.allIt(it.startsWith("done ")): break
doAssert outcomes.allIt(it.startsWith("done ")), trace.join("\n")
let msigAddr = outcomes[0].split(' ')[1]
doAssert outcomes.allIt(it == "done " & msigAddr), $outcomes
echo "1. the room carried the exchange: ", trace.len, " steps, one address ", msigAddr[0 .. 11], "… OK"

pollAll()
for w in ws:
  let st = w.isMultisig()
  doAssert st.ready and st.threshold == 2 and st.total == 3
  doAssert w.address() == msigAddr
let accts = reduceAccounts(r.carol.log.allEvents()).filterIt(it.family == XmrMsigFamily)
doAssert accts.len == 1 and accts[0].address == msigAddr and ids.allIt(it in accts[0].disclosedBy)
let d = driverForPolicy(qualify("xmr-msig", accts[0].id), accts, proc(k: string): Driver = nil,
                        xmrAllowRegtest = true)
doAssert d of XmrMsigDriver and XmrMsigDriver(d).account.k == 2
echo "2. each wallet is a ready 2-of-3 at that address; disclosed by all three; xmr-msig@ acts OK"

let before = r.alice.log.allEvents().len
pollAll()
for i in 0 ..< 3: doAssert xmrSetupStep(ss[i], ks[i], ws[i], Cid) == "done " & msigAddr
pollAll()
doAssert r.alice.log.allEvents().len == before
echo "3. stepping again changes nothing OK"
