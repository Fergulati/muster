## Like Muster? (exo-168): the tip addresses are pinned, each one valid on its own network,
## and a tip is sent only to a pinned address from a wallet the person connected. Pure:
## the options are a function of the table, the Wallet page's summary and the prompt.

import std/[json, sequtils, sets, strutils]
import ../src/wallet/support

const
  EthOk = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"        # EIP-55's own vector
  EthBadSum = "0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
  BtcMain = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"       # BIP-173
  BtcTest = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx"
  XmrMain = "42ey1afDFnn4886T7196doS9GPMzexD9gXpsZJDwVjeRVdFCSoHnv7KPbBeGpzJBzHRCAs9UxqeoyFQMYbqSWYTfJJQAWDm"
  XmrStage = "53teqCAESLxeJ1REzGMAat1ZeHvuajvDiXqboEocPaDRRmqWoVPzy46GLo866qRFjbNhfkNckyhST3WEvBviDwpUDd7DSzB"
  XmrStageIntegrated = "5K8mwfjumVseCcQEjNbf59Um6R9NfVUNkHTLhhPCmNvgDLVS88YW5tScnm83rw9mfgYtchtDDTW5jEfMhygi27j1QYphX38hg6m4VMtN29"
  XmrMainChain = "monero:418015bb9ae982a1975da7d79277c270"
  XmrStageChain = "monero:76ee3cc98646292206cd3e86f74d88b4"
  BtcMainChain = "bip122:000000000019d6689c085ae165831e93"
  LezPublic = "11111111111111111111111111111111"                # base58 of 32 zero bytes
  LezKeyNode = "priv:npk1:vpk1"

proc sa(id, chain, kind, address: string): SupportAddress =
  SupportAddress(id: id, chain: chain, name: id, kind: kind, address: address, purpose: "for " & id)

block:
  # the pinned table: ids unique, every kind known, and every address that is set valid
  # on its own chain, so a release never offers an address its network would refuse
  let t = supportTable()
  doAssert t.about.len > 0
  doAssert t.addresses.len >= 7
  doAssert t.addresses.mapIt(it.id).toHashSet.len == t.addresses.len
  for s in t.addresses:
    doAssert s.kind in ["evm", "btc", "monero", "lez"], s.id
    doAssert s.purpose.len > 0, s.id
    if s.address.len > 0:
      let v = validAddress(s)
      doAssert v.ok, s.id & ": " & v.reason

block:
  # each address on its network's own terms
  doAssert validAddress(sa("e", "evm:1", "evm", EthOk)).ok
  doAssert validAddress(sa("e", "evm:1", "evm", EthOk.toLowerAscii())).ok
  doAssert not validAddress(sa("e", "evm:1", "evm", EthBadSum)).ok           # a broken checksum
  doAssert not validAddress(sa("e", "evm:1", "evm", "0x1234")).ok
  doAssert not validAddress(sa("e", "evm:1", "evm", "")).ok                  # not set
  doAssert validAddress(sa("b", BtcMainChain, "btc", BtcMain)).ok
  doAssert not validAddress(sa("b", BtcMainChain, "btc", BtcTest)).ok        # a testnet address on mainnet
  doAssert validAddress(sa("x", XmrMainChain, "monero", XmrMain)).ok
  doAssert validAddress(sa("x", XmrStageChain, "monero", XmrStage)).ok
  doAssert not validAddress(sa("x", XmrMainChain, "monero", XmrStage)).ok    # stagenet in the mainnet slot
  doAssert not validAddress(sa("x", XmrStageChain, "monero", XmrStageIntegrated)).ok  # a payment id
  doAssert validAddress(sa("l", "lez:testnet", "lez", LezPublic)).ok
  doAssert validAddress(sa("l", "lez:testnet", "lez", LezKeyNode)).ok
  doAssert not validAddress(sa("l", "lez:testnet", "lez", "priv:npk1")).ok
  doAssert not validAddress(sa("l", "lez:testnet", "lez", "0OIl")).ok        # not base58
  doAssert not validAddress(sa("l", "evm:1", "lez", LezPublic)).ok

block:
  # the links a wallet opens: the address, the amount left to the payer
  doAssert paymentUri(sa("x", XmrStageChain, "monero", XmrStage)).startsWith("monero:" & XmrStage & "?")
  doAssert "tx_amount" notin paymentUri(sa("x", XmrStageChain, "monero", XmrStage))
  doAssert paymentUri(sa("b", BtcMainChain, "btc", BtcMain)) == "bitcoin:" & BtcMain & "?label=Muster"
  doAssert paymentUri(sa("e", "evm:11155111", "evm", EthOk)) == "ethereum:" & EthOk & "@11155111"
  doAssert paymentUri(sa("l", "lez:testnet", "lez", LezKeyNode)) == ""

block:
  # amounts, exactly: no rounding, no more places than the asset has, never zero
  doAssert toBaseUnits("1.5", 18).raw == "1500000000000000000"
  doAssert toBaseUnits("0.000000001", 9).raw == "1"
  doAssert toBaseUnits("12", 0).raw == "12"
  doAssert toBaseUnits(".5", 2).raw == "50"
  doAssert toBaseUnits("007.10", 2).raw == "710"
  doAssert not toBaseUnits("0.0000000001", 9).ok
  doAssert not toBaseUnits("0", 18).ok
  doAssert not toBaseUnits("0.000", 18).ok
  doAssert not toBaseUnits("-1", 18).ok
  doAssert not toBaseUnits("1e3", 18).ok
  doAssert not toBaseUnits("1.2.3", 18).ok
  doAssert not toBaseUnits("", 18).ok

let table = @[
  sa("eth", "evm:11155111", "evm", EthOk),
  sa("unset", "evm:1", "evm", ""),
  sa("xmr", XmrStageChain, "monero", XmrStage),
  sa("lez", "lez:testnet", "lez", LezKeyNode)]

let summary = %*{"wallets": [
  {"id": "ethereum", "name": "Ethereum", "dev": false, "balances": [
    {"chain": "evm:11155111", "account": "0xaaaa", "asset": "ETH", "display": "0.5 ETH", "raw": "500000000000000000"},
    {"chain": "evm:11155111", "account": "0xaaaa", "asset": "USDC", "display": "0 USDC", "raw": "0"},
    {"chain": "evm:11155111", "account": "0xaaaa", "asset": "DAI", "error": "read failed"}]},
  {"id": "monero", "name": "Monero", "balances": [
    {"chain": XmrStageChain, "account": XmrStage, "asset": "XMR", "display": "1 XMR", "raw": "1000000000000"}]},
  {"id": "lez", "name": "Logos Execution Zone", "dev": false, "balances": [
    {"chain": "lez:testnet", "account": "Pub1", "form": "public", "asset": "LEZ", "display": "1 LEZ", "raw": "1000000000"},
    {"chain": "lez:testnet", "account": "Priv1", "form": "shielded", "asset": "LEZ", "display": "2 LEZ", "raw": "2000000000"}]}]}

proc option(o: JsonNode, id: string): JsonNode =
  for x in o["options"]:
    if x["id"].getStr() == id: return x
  nil

block:
  # an address not set is never offered; a connected wallet offers what it holds on that
  # chain, a failed or empty read never; Monero is a link, never a send
  let o = supportOptions("about", table, summary, "")
  doAssert o["prompt"].getStr() == "unseen"
  doAssert o["connected"].getBool()
  doAssert o["options"].getElems().mapIt(it["id"].getStr()) == @["eth", "xmr", "lez"]
  let eth = option(o, "eth")
  doAssert eth["senders"].getElems().mapIt(it["asset"].getStr()) == @["ETH"]
  doAssert eth["discloses"]["payer"].getStr() == "everyone"
  doAssert option(o, "xmr")["senders"].len == 0
  doAssert option(o, "xmr")["discloses"]["payer"].getStr() == "only Muster"
  doAssert option(o, "xmr")["uri"].getStr().startsWith("monero:")
  # the LEZ: from the shielded account the private rail hides the payer; from the public one, not
  for s in option(o, "lez")["senders"]:
    let hidden = s["discloses"]["payer"].getStr() == "only Muster"
    doAssert hidden == (s["form"].getStr() == "shielded"), $s
  doAssert supportOptions("about", table, summary, "dismissed")["prompt"].getStr() == "dismissed"

block:
  # a development wallet (the runner's own key, the in-process LEZ) never sends a tip,
  # and alone it is not "a wallet connected"
  let dev = %*{"wallets": [
    {"id": "ethereum", "dev": true, "balances": [
      {"chain": "evm:11155111", "account": "0xdev", "asset": "ETH", "display": "9 ETH", "raw": "9000000000000000000"}]},
    {"id": "lez", "dev": true, "balances": [
      {"chain": "lez:testnet", "account": "Priv1", "form": "shielded", "asset": "LEZ", "display": "2 LEZ", "raw": "2000000000"}]}]}
  let o = supportOptions("about", table, dev, "")
  doAssert not o["connected"].getBool()
  for x in o["options"]: doAssert x["senders"].len == 0, $x
  doAssert not supportOptions("about", table, %*{"wallets": []}, "")["connected"].getBool()

block:
  # a send is only as offered: the address is the table's, never the caller's
  let o = supportOptions("about", table, summary, "")
  let ok = offeredSender(o, "eth", "0xaaaa", "ETH")
  doAssert ok.ok and ok.address == EthOk and ok.chain == "evm:11155111"
  doAssert not offeredSender(o, "eth", "0xaaaa", "USDC").ok      # nothing to send
  doAssert not offeredSender(o, "eth", "0xbbbb", "ETH").ok       # not a connected account
  doAssert not offeredSender(o, "xmr", XmrStage, "XMR").ok       # Muster never spends Monero
  doAssert not offeredSender(o, "unset", "0xaaaa", "ETH").ok     # an address not set
  doAssert not offeredSender(o, "nope", "0xaaaa", "ETH").ok
  doAssert offeredSender(o, "lez", "Priv1", "LEZ").address == LezKeyNode

echo "support_test: OK"
