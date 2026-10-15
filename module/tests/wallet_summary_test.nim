## The Wallet page shows what this instance has been given, and nothing it has not
## (exo-f37, reported 2026-10-15): a Basecamp member who had opened a Monero wallet and
## never set up Ethereum saw Ethereum balances for Muster's own internal key, and no Monero
## at all. Pure: the summary is a function of what the host answered.

import std/[json, sequtils, strutils]
import ../src/wallet/monero_backend
import ../src/wallet/summary

let evmRows = %*[
  {"chain": "evm:11155111", "account": "0xaaaa", "asset": "ETH", "grade": "attested", "display": "0.5 ETH", "raw": "500000000000000000"},
  {"chain": "lez:testnet", "account": "Pub1", "asset": "LEZ", "grade": "attested", "display": "1 LEZ", "raw": "1000000000"}]
let demoRows = %*[{"chain": "mock:shielded", "account": "m1", "asset": "MOCK", "grade": "attested", "display": "5000 MOCK", "raw": "5000000000"}]

proc ids(s: JsonNode): seq[string] = s["wallets"].getElems().mapIt(it["id"].getStr())
proc connects(s: JsonNode): seq[string] = s["connect"].getElems().mapIt(it["id"].getStr() & ":" & it["action"].getStr())
proc wallet(s: JsonNode, id: string): JsonNode =
  for w in s["wallets"]:
    if w["id"].getStr() == id: return w
  nil

let noMonero = MoneroView(module: "unknown")
let openWallet = MoneroView(module: "ready",
  status: WalletStatus(read: rsAnswered, state: "ready", wallet: "alice", network: "stagenet"),
  receive: ReceiveInfo(read: rsAnswered, primary: "5Alice…primary"),
  balances: Balances(read: rsAnswered, balance: "1500000000000", unlocked: "1000000000000"))

block:
  # Basecamp, no Ethereum account chosen for Muster: no Ethereum wallet, whatever the
  # wallet aggregate read for Muster's own key; the way to connect one instead
  let s = walletSummary(SummaryInputs(platform: true, evmAccount: "", keystoreAccounts: 0,
                                      rows: evmRows, monero: noMonero))
  doAssert "ethereum" notin s.ids, "no Ethereum wallet the person never set up: " & $s
  doAssert "ethereum:accounts" in s.connects, "it says how to connect one: " & $s
  for w in s["wallets"]:
    for b in w["balances"]: doAssert not b["chain"].getStr().startsWith("evm:"), "no EVM balance shown: " & $s
  echo "1. Basecamp, no Ethereum account chosen: no Ethereum wallet, a way to add one OK"

block:
  # accounts exist in the keystore, none chosen for Muster: choose one (Settings)
  let s = walletSummary(SummaryInputs(platform: true, evmAccount: "", keystoreAccounts: 2,
                                      rows: evmRows, monero: noMonero))
  doAssert "ethereum" notin s.ids
  doAssert "ethereum:settings" in s.connects, $s
  echo "2. keystore accounts but none chosen: choose one in Settings OK"

block:
  # the account the person chose: the Ethereum wallet, its balances
  let s = walletSummary(SummaryInputs(platform: true, evmAccount: "0xAAAA", keystoreAccounts: 1,
                                      rows: evmRows, monero: noMonero))
  let w = s.wallet("ethereum")
  doAssert w != nil and w["account"].getStr() == "0xaaaa", $s
  doAssert w["balances"].len == 1 and w["balances"][0]["display"].getStr() == "0.5 ETH", $s
  doAssert s.connects.allIt(not it.startsWith("ethereum:")), $s
  echo "3. the chosen account is the Ethereum wallet, with its balances OK"

block:
  # a Monero wallet open in Monero Wallet: the Monero wallet, its address and balance
  let s = walletSummary(SummaryInputs(platform: true, evmAccount: "", rows: evmRows, monero: openWallet))
  let w = s.wallet("monero")
  doAssert w != nil, "the open Monero wallet is shown: " & $s
  doAssert w["account"].getStr() == "5Alice…primary" and w["network"].getStr() == "stagenet", $w
  doAssert w["wallet"].getStr() == "alice", $w
  doAssert w["balances"][0]["asset"].getStr() == "XMR", $w
  doAssert w["balances"][0]["display"].getStr() == "1.5 XMR", $w
  doAssert w["balances"][0]["unlocked"].getStr() == "1 XMR", $w
  doAssert w["balances"][0]["chain"].getStr() == "monero:stagenet", $w
  doAssert s.ids == @["monero", "lez"], "Monero, and the LEZ the wallet read — never Ethereum: " & $s.ids
  echo "4. an open Monero wallet: shown, with its address and balance OK"

block:
  # the backend running with no wallet open; installed but not running; not installed;
  # a host that cannot say (the standalone runner): each says what it can, nothing more
  let none = walletSummary(SummaryInputs(platform: true, rows: newJArray(), monero: MoneroView(module: "ready",
    status: WalletStatus(read: rsAnswered, state: "no_wallet"))))
  doAssert "monero" notin none.ids and "monero:monero" in none.connects, $none
  let stopped = walletSummary(SummaryInputs(platform: true, rows: newJArray(), monero: MoneroView(module: "installed")))
  doAssert "monero" notin stopped.ids and "monero:monero" in stopped.connects, $stopped
  let missing = walletSummary(SummaryInputs(platform: true, rows: newJArray(), monero: MoneroView(module: "not-installed")))
  doAssert "monero:install" in missing.connects and missing["connect"][^1]["package"].getStr() == MoneroWalletApp, $missing
  let unknown = walletSummary(SummaryInputs(platform: false, rows: newJArray(), monero: noMonero))
  doAssert unknown.connects.allIt(not it.startsWith("monero:")), $unknown
  echo "5. no wallet open / not running / not installed / unknown host: each said, never a fake wallet OK"

block:
  # asked but not answered yet (the first look): checking, never "no wallet"
  let s = walletSummary(SummaryInputs(platform: true, rows: newJArray(), monero: MoneroView(module: "ready",
    status: WalletStatus(read: rsUnread, detail: "not yet"))))
  doAssert "monero" notin s.ids and "Monero" in s["checking"].getElems().mapIt(it.getStr()), $s
  # an open wallet whose balance is not read yet: the wallet, its balance pending
  var v = openWallet
  v.balances = Balances(read: rsUnread)
  let p = walletSummary(SummaryInputs(platform: true, rows: newJArray(), monero: v))
  doAssert p.wallet("monero")["balances"][0]{"pending"}.getBool(), $p
  doAssert not p.wallet("monero")["balances"][0].hasKey("display"), "a balance not read is never a zero: " & $p
  echo "6. not answered yet: checking; a balance not read: pending, never zero OK"

block:
  # the standalone runner: its own key on its configured chain, and its demo chain, named so
  let s = walletSummary(SummaryInputs(platform: false, evmAccount: "0xBBBB",
                                      rows: %(evmRows.getElems() & demoRows.getElems()), monero: noMonero))
  doAssert s.ids == @["ethereum", "lez", "demo"], $s.ids
  doAssert s.wallet("ethereum")["dev"].getBool(), "the runner's own key is marked as development: " & $s
  let fake = walletSummary(SummaryInputs(platform: false, evmAccount: "0xBBBB", rows: evmRows, lezDemo: true, monero: noMonero))
  doAssert fake.wallet("lez")["dev"].getBool(), "the in-process LEZ is marked as development: " & $fake
  doAssert not s.wallet("lez")["dev"].getBool(), "a real LEZ wallet is not: " & $s
  doAssert s.connects.len == 0, $s
  echo "7. the standalone runner: its own key and demo chain, marked as development OK"

echo "wallet_summary_test: OK"
