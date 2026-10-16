## The xmr-msig wallet client against real Monero (exo-dcc.34.1): a 2-of-3 on a private
## regtest chain through RpcXmrMsigWallet, and the driver's describe-check on what the real
## wallet describes. Needs the chain: `infra/monero/regtest.sh up 4` first (monerod :38081,
## wallet RPCs :38091 funder, :38092-94 the three members). Held here:
##   1. setup through the client: prepare, make, exchange until ready; one address for all
##   2. sync, build, describe: the describe-check passes for the agreed spend and refuses a
##      spend that differs (another amount, another recipient)
##   3. sign (one co-signer), submit, and 10 confirmations read back through the client

import std/[json, strutils, sequtils, os]
import ../src/wallet/xmr_msig_wallet
import ../src/drivers/xmr_msig

let daemon = newRpcXmrMsigWallet("http://127.0.0.1:38081")
let funder = newRpcXmrMsigWallet("http://127.0.0.1:38091")
let ws = @[newRpcXmrMsigWallet("http://127.0.0.1:38092"), newRpcXmrMsigWallet("http://127.0.0.1:38093"),
           newRpcXmrMsigWallet("http://127.0.0.1:38094")]
let tag = $getCurrentProcessId()
proc mine(n: int, to: string) = discard daemon.call("generateblocks", %*{"amount_of_blocks": n, "wallet_address": to})

discard funder.call("create_wallet", %*{"filename": "funder-" & tag, "language": "English"})
for i, w in ws: discard w.call("create_wallet", %*{"filename": "m" & $i & "-" & tag, "language": "English"})
let fAddr = funder.address()
mine(120, fAddr)

block setup:
  let infos = ws.mapIt(it.prepare())
  var rnd: seq[string]
  for i, w in ws: rnd.add w.make(infos.filterIt(it != infos[i]), 2).info
  for _ in 0 ..< 4:
    if ws.allIt(it.isMultisig().ready): break
    var nxt: seq[string]
    for i, w in ws: nxt.add w.exchange(rnd.filterIt(it != rnd[i])).info
    rnd = nxt
  doAssert ws.allIt(it.isMultisig().ready and it.isMultisig().threshold == 2 and it.isMultisig().total == 3)
  doAssert ws.mapIt(it.address()).deduplicate().len == 1, "one address for every member"
  echo "1. setup through the client: ready, one address OK"

let msig = ws[0].address()
funder.refresh()
discard funder.call("transfer", %*{"destinations": [{"amount": 5_000_000_000_000'u64, "address": msig}]})
mine(12, fAddr)
for w in ws: w.refresh()

block spend:
  let ex = ws.mapIt(it.exportInfo())
  for i, w in ws: discard w.importInfo(ex.filterIt(it != ex[i]))
  let dest = funder.call("create_address", %*{"account_index": 0})["address"].getStr()
  let agreed = XmrSpend(chain: XmrRegtestChain, account: msig, feeCap: "50000000000",
                        recipients: @[XmrRecipient(address: dest, amount: "1234567890000")])
  let txset = ws[0].transfer(@[(dest, "1234567890000")])
  let described = ws[1].describe(txset)
  doAssert describeRefusal(agreed, described) == "", "the agreed spend: " & describeRefusal(agreed, described)
  var other = agreed
  other.recipients[0].amount = "1234567890001"
  doAssert "recipients" in describeRefusal(other, described), "another amount is refused"
  other = agreed
  other.recipients[0].address = fAddr
  doAssert "recipients" in describeRefusal(other, described), "another recipient is refused"
  echo "2. sync, build, describe: the agreed spend passes, another is refused OK"
  let signed = ws[1].sign(txset)
  doAssert signed.txids.len == 1 and signed.txset.len > 0
  let txids = ws[2].submit(signed.txset)
  doAssert txids == signed.txids
  mine(10, fAddr)
  ws[0].refresh()
  doAssert ws[0].confirmations(txids[0]) >= 10, "10 confirmations read through the client"
  echo "3. sign, submit, 10 confirmations through the client OK"

echo "xmr_msig_regtest_e2e: all OK"
