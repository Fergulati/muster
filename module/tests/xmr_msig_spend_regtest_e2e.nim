## A spend from a Monero multisig over the room with REAL wallets (ADR-020 S3,
## exo-dcc.34.3): three members set up a 2-of-3 over the room (S2), it is funded, and a
## spend is agreed, synced, built, checked, signed and submitted over the room, each step
## by a member's own monero-wallet-rpc, then final at 10 confirmations. Needs the chain:
## `infra/monero/regtest.sh up 4` first (:38091 the funder, :38092-94 the members).

import std/[json, strutils, sequtils, os, tables]
import ../src/drivers/[driver, kinds, xmr_msig]
import ../src/intents/lifecycle
import ../src/wallet/xmr_msig_wallet
import ../src/crypto/[keystore, curve25519]
import ../src/coordination/[session, accounts, intents, live, xmr_msig_setup, xmr_msig_spend]
import ./probes/live_room

proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let daemon = newRpcXmrMsigWallet("http://127.0.0.1:38081")
let funder = newRpcXmrMsigWallet("http://127.0.0.1:38091")
let ws = @[newRpcXmrMsigWallet("http://127.0.0.1:38092"), newRpcXmrMsigWallet("http://127.0.0.1:38093"),
           newRpcXmrMsigWallet("http://127.0.0.1:38094")]
let tag = $getCurrentProcessId()
proc mine(n: int, to: string) = discard daemon.call("generateblocks", %*{"amount_of_blocks": n, "wallet_address": to})
discard funder.call("create_wallet", %*{"filename": "sfunder-" & tag, "language": "English"})
for i, w in ws: discard w.call("create_wallet", %*{"filename": "sroom-m" & $i & "-" & tag, "language": "English"})
let fAddr = funder.address()
mine(120, fAddr)

var r = newRoom3("/muster/1/xmr-msig-spend-e2e/proto")
let ks = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ss = @[r.alice, r.bob, r.carol]
let ids = ks.mapIt(idOf(it))
proc pollAll() = (for s in ss: s.poll())
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = nil, xmrAllowRegtest = true)

# the wallet, set up over the room (S2)
doAssert xmrSetupOpen(r.alice, "t", XmrRegtestChain, 2, ids, allowRegtest = true) == ""
pollAll()
for i in 0 ..< 3: doAssert xmrSetupJoin(ss[i], ks[i], "t") == ""
for _ in 0 ..< 10:
  pollAll()
  var outs: seq[string]
  for i in 0 ..< 3: outs.add xmrSetupStep(ss[i], ks[i], ws[i], "t")
  if outs.allIt(it.startsWith("done ")): break
pollAll()
let acct = reduceAccounts(r.alice.log.allEvents()).filterIt(it.family == XmrMsigFamily)[0]
doAssert xmrMsigAccountOf(acct).ok
let policy = qualify("xmr-msig", acct.id)

funder.refresh()
discard funder.call("transfer", %*{"destinations": [{"amount": 5_000_000_000_000'u64, "address": acct.address}]})
mine(12, fAddr)
echo "1. a 2-of-3 set up over the room and funded OK"

let dest = funder.call("create_address", %*{"account_index": 0})["address"].getStr()
let effect = xmrMsigSpendJson(XmrRegtestChain, acct.address,
                              @[XmrRecipient(address: dest, amount: "1234567890000")], "50000000000", "rent")
let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effect, int64(Now), 1,
                           account = acct.address, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
pollAll()
doAssert liveContribute(r.alice, aliceKs, res(r.alice), id, "", "", bindCtx(), Now) == "collecting"
pollAll()
doAssert liveContribute(r.carol, room3CarolKs, res(r.carol), id, "", "", bindCtx(), Now) == "collecting"
var trace: seq[string]
var submitted = ""
for _ in 0 ..< 8:
  pollAll()
  var outs: seq[string]
  for i in 0 ..< 3: outs.add xmrSpendStep(ss[i], ks[i], ws[i], res(ss[i]), id, Now)
  trace.add $outs
  for o in outs:
    if o.startsWith("submitted "): submitted = o[10 .. ^1]
  if submitted.len > 0: break
doAssert submitted.len > 0, trace.join("\n")
echo "2. agreed, synced, built, checked, signed and submitted over the room: ", submitted[0 .. 11], "… OK"

mine(10, fAddr)
var finals = 0
for _ in 0 ..< 3:
  pollAll()
  finals = 0
  for i in 0 ..< 3:
    if xmrSpendStep(ss[i], ks[i], ws[i], res(ss[i]), id, Now) == "final": inc finals
  if finals == 3: break
pollAll()
for s in ss: doAssert reduceIntents(s.roomEvents(), res(s))[id].state == lsFinal
funder.refresh()
doAssert funder.confirmations(submitted.split(',')[0]) >= 10
echo "3. final at 10 confirmations on every member; the payee's wallet sees it OK"
