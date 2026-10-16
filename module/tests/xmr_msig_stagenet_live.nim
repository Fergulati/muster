## A Monero multisig over the room on STAGENET, with real wallets and real blocks (ADR-020,
## exo-dcc.34). Not in the suite: it spends stagenet XMR and takes about 45 minutes.
## Three members' monero-wallet-rpc on stagenet (XMR_STAGE_MEMBERS, default
## :38181,:38182,:38183, started with --wallet-dir and --disable-rpc-login) get fresh
## wallets; a funded stagenet wallet (XMR_STAGE_FUNDER, default :38180) funds the 2-of-3
## (XMR_STAGE_FUND atomic, default 0.005 XMR) and receives the spend back
## (XMR_STAGE_SPEND, default 0.001 XMR). Run: module/tests/run-suite.sh e2e xmr_msig_stagenet_live

import std/[json, strutils, sequtils, os, tables, times]
import ../src/drivers/[driver, kinds, xmr_msig]
import ../src/intents/lifecycle
import ../src/monero/address
import ../src/wallet/[xmr_msig_wallet, rpc_budget]
import ../src/crypto/[keystore, curve25519]
import ../src/coordination/[session, accounts, intents, live, xmr_msig_setup, xmr_msig_spend]
import ./probes/live_room

proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let t0 = epochTime()
proc stamp(): string = $int(epochTime() - t0) & "s"
let funder = newRpcXmrMsigWallet(getEnv("XMR_STAGE_FUNDER", "http://127.0.0.1:38180"))
let ws = getEnv("XMR_STAGE_MEMBERS", "http://127.0.0.1:38181,http://127.0.0.1:38182,http://127.0.0.1:38183")
           .split(',').mapIt(newRpcXmrMsigWallet(it))
let fundAmt = getEnv("XMR_STAGE_FUND", "5000000000")
let spendAmt = getEnv("XMR_STAGE_SPEND", "1000000000")
let Stage = caip2Of(xmrStagenet)
let resume = getEnv("XMR_STAGE_RESUME")   ## the tag of an earlier run whose multisig to reuse
let tag = (if resume.len > 0: resume else: $getCurrentProcessId())
echo "   run tag ", tag

var r = newRoom3("/muster/1/xmr-msig-stagenet/" & tag)
let ks = @[Keystore(aliceKs), Keystore(bobKs), Keystore(room3CarolKs)]
let ss = @[r.alice, r.bob, r.carol]
let ids = ks.mapIt(idOf(it))
proc pollAll() = (for s in ss: s.poll())
proc res(s: CoordinationSession): DriverFor =
  let sess = s
  result = proc(policy: string): Driver =
    driverForPolicy(policy, reduceAccounts(sess.log.allEvents()), proc(k: string): Driver = nil)
proc retrying[T](what: string, f: proc(): T): T =
  ## a remote node drops out for minutes at a time: wait it out, up to 20 minutes
  for attempt in 0 ..< 40:
    try: return f()
    except XmrWalletBusy as e:
      echo "   [", stamp(), "] ", what, ": ", e.msg, " — retrying"
      sleep(30_000)
  raise newException(CatchableError, what & ": the wallet stayed busy")

var outs: seq[string]
if resume.len == 0:
  for i, w in ws: discard w.call("create_wallet", %*{"filename": "msig-m" & $i & "-" & tag, "language": "English"})
  # ── 1. the setup over the room ──────────────────────────────────────────────
  doAssert xmrSetupOpen(r.alice, "stage", Stage, 2, ids) == ""
  pollAll()
  for i in 0 ..< 3: doAssert xmrSetupJoin(ss[i], ks[i], "stage") == ""
  for _ in 0 ..< 20:
    pollAll()
    outs = @[]
    for i in 0 ..< 3: outs.add xmrSetupStep(ss[i], ks[i], ws[i], "stage")
    if outs.allIt(it.startsWith("done ")): break
    if outs.anyIt(it.startsWith("waiting: your wallet")): sleep(10_000)
  doAssert outs.allIt(it.startsWith("done ")), $outs
else:
  # the multisig an earlier run set up over its room (that room was in this process and
  # is gone): each member's wallet is reopened and discloses the address it reports
  for i, w in ws: discard w.call("open_wallet", %*{"filename": "msig-m" & $i & "-" & tag, "password": ""})
  let a0 = retrying("address", proc(): string = ws[0].address())
  for i, w in ws:
    let st = retrying("is_multisig", proc(): MsigState = w.isMultisig())
    doAssert st.ready and st.threshold == 2 and st.total == 3 and w.address() == a0
    ss[i].publishAuthored(ks[i], accountDiscloseEvent(RoomAccount(family: XmrMsigFamily, chain: Stage,
      address: a0, label: "Monero multisig 2 of 3", signers: ids, threshold: 2,
      config: $(%*{"ceremony": "stage"})), ids[i]))
pollAll()
let acct = reduceAccounts(r.alice.log.allEvents()).filterIt(it.family == XmrMsigFamily)[0]
doAssert xmrMsigAccountOf(acct).ok
echo "1. [", stamp(), "] a 2-of-3 on stagenet, disclosed by all three: ", acct.address

# ── 2. funded, and unlocked (10 blocks) ───────────────────────────────────────
let back = funder.address()
proc balances(): tuple[balance, unlocked: string] =
  retrying("balance", proc(): tuple[balance, unlocked: string] = (ws[0].refresh(); ws[0].unlocked()))
if parseBiggestUInt(balances().balance) < parseBiggestUInt(fundAmt):
  let fund = retrying("fund", proc(): JsonNode =
    funder.call("transfer", %*{"destinations": [{"amount": parseBiggestUInt(fundAmt), "address": acct.address}]}))
  echo "   [", stamp(), "] funded: tx ", fund["tx_hash"].getStr(), " fee ", fund["fee"].getBiggestInt()
else:
  echo "   [", stamp(), "] already funded"
while parseBiggestUInt(balances().unlocked) < parseBiggestUInt(fundAmt):
  doAssert epochTime() - t0 < 3600, "the funding did not unlock within an hour"
  sleep(30_000)
echo "2. [", stamp(), "] the multisig's funds are unlocked OK"

# ── 3. a spend over the room ──────────────────────────────────────────────────
let policy = qualify("xmr-msig", acct.id)
let effect = xmrMsigSpendJson(Stage, acct.address, @[XmrRecipient(address: back, amount: spendAmt)],
                              "1000000000", "stagenet run")
let id = liveProposeIntent(r.alice, aliceKs, res(r.alice), policy, effect, int64(Now), 1,
                           account = acct.address, ttlSec = Ttl)
doAssert id.startsWith("0x"), id
pollAll()
doAssert liveContribute(r.alice, aliceKs, res(r.alice), id, "", "", bindCtx(), Now) == "collecting"
pollAll()
doAssert liveContribute(r.carol, room3CarolKs, res(r.carol), id, "", "", bindCtx(), Now) == "collecting"
var submitted = ""
for _ in 0 ..< 40:
  pollAll()
  outs = @[]
  for i in 0 ..< 3: outs.add xmrSpendStep(ss[i], ks[i], ws[i], res(ss[i]), id, Now)
  echo "   [", stamp(), "] ", outs
  for o in outs:
    if o.startsWith("submitted "): submitted = o[10 .. ^1]
    doAssert not o.startsWith("refused"), o
  if submitted.len > 0: break
  if outs.anyIt(it.startsWith("waiting: your wallet")): sleep(30_000)
doAssert submitted.len > 0
echo "3. [", stamp(), "] agreed, synced, built, checked, signed, submitted over the room: ", submitted, " OK"

# ── 4. final at 10 confirmations ──────────────────────────────────────────────
while true:
  pollAll()
  outs = @[]
  for i in 0 ..< 3: outs.add xmrSpendStep(ss[i], ks[i], ws[i], res(ss[i]), id, Now)
  if outs.allIt(it == "final"): break
  doAssert epochTime() - t0 < 7200, "not final within two hours: " & $outs
  sleep(60_000)
pollAll()
for s in ss: doAssert reduceIntents(s.roomEvents(), res(s))[id].state == lsFinal
discard retrying("refresh", proc(): bool = (funder.refresh(); true))
let seen = funder.call("get_transfer_by_txid", %*{"txid": submitted.split(',')[0]})
echo "4. [", stamp(), "] final on every member at 10 confirmations; the funder's wallet saw ",
     seen{"transfer"}{"amount"}.getBiggestInt(), " atomic come back OK"
