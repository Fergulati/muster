## Like Muster? (exo-168): tipping the project from a wallet the person connected.
##
## The addresses are pinned in `support.json`, beside this file, read at build time and
## never fetched (invariant 8). The Pages site publishes the same file, so the addresses a
## build shows can be checked against the repo. Each one is held to its network's own
## rules by support_test: an address that does not parse on its chain is never offered.
##
## Pure: the options are a function of the table, the Wallet page's summary and whether
## the prompt was dismissed, so muster_module only gathers them. A send names an option
## and one of the senders offered for it, never an address: the module pays only a pinned
## address, from a wallet the person connected (never a development one).
##
## Who sees a tip is said per row, as the room's cards say it (the education square):
##   * Ethereum and Bitcoin: the payer's address and the amount, to everyone, for good.
##   * Monero: neither, to anyone but the recipient. Muster never spends Monero, so a
##     Monero tip is a `monero:` link paid from any wallet.
##   * The LEZ: the rail decides. A shielded sender to the shielded key node hides both;
##     a public sender is seen paying (a shield).

import std/[json, strutils]
import ../hashing/keccak256
import ../bitcoin/[bech32, network]
import ../monero/address as xmr
import ../lez/tx as leztx

const SupportJson* = staticRead("support.json")

type
  SupportAddress* = object
    id*, chain*, name*, kind*, address*, purpose*: string
    testnet*: bool

proc parseSupport*(text: string): tuple[about: string, addresses: seq[SupportAddress]] =
  let j = parseJson(text)
  result.about = j{"about"}.getStr()
  for a in j{"addresses"}:
    result.addresses.add SupportAddress(
      id: a{"id"}.getStr(), chain: a{"chain"}.getStr(), name: a{"name"}.getStr(),
      kind: a{"kind"}.getStr(), address: a{"address"}.getStr().strip(),
      purpose: a{"for"}.getStr(), testnet: a{"testnet"}.getBool(false))

proc supportTable*(): tuple[about: string, addresses: seq[SupportAddress]] =
  parseSupport(SupportJson)

# ── each address, on its network's own terms ────────────────────────────────────

proc eip55Ok(a: string): bool =
  ## 0x + 40 hex; a mixed-case address must carry its EIP-55 checksum.
  if a.len != 42 or not a.startsWith("0x") or not a[2 .. ^1].allCharsInSet(HexDigits): return false
  let body = a[2 .. ^1]
  if body == body.toLowerAscii() or body == body.toUpperAscii(): return true
  let lower = body.toLowerAscii()
  let h = keccak256(lower.toOpenArrayByte(0, lower.high))
  for i, c in body:
    if c in {'0'..'9'}: continue
    let nibble = (if i mod 2 == 0: int(h[i div 2]) shr 4 else: int(h[i div 2]) and 15)
    if (nibble >= 8) != (c in {'A'..'F'}): return false
  true

proc lezShielded*(a: string): bool = a.startsWith("priv:")

proc validAddress*(s: SupportAddress): tuple[ok: bool, reason: string] =
  ## Whether the pinned address is one its chain accepts. An empty one is "not set".
  if s.address.len == 0: return (false, "not set")
  case s.kind
  of "evm":
    if not s.chain.startsWith("evm:"): return (false, "an evm address on a chain that is not evm:<id>")
    if not eip55Ok(s.address): return (false, "not an Ethereum address (0x + 40 hex, EIP-55 if mixed case)")
  of "btc":
    try:
      let n = networkByCaip2(s.chain)
      discard decodeSegwitAddress(n.hrp, s.address)
    except CatchableError as e: return (false, "not a segwit address on " & s.chain & ": " & e.msg)
  of "monero":
    let a = xmr.acceptablePayTo(s.address, s.chain)
    if not a.ok: return (false, a.reason)
  of "lez":
    if not s.chain.startsWith("lez:"): return (false, "a LEZ address on a chain that is not lez:<zone>")
    if lezShielded(s.address):
      let parts = s.address["priv:".len .. ^1].split(':')
      if parts.len != 2 or parts[0].len == 0 or parts[1].len == 0:
        return (false, "a shielded LEZ address is priv:<npk>:<vpk>")
    else:
      try: discard leztx.accountIdFromBase58(s.address)
      except CatchableError as e: return (false, e.msg)
  else: return (false, "unknown kind " & s.kind.escape)
  (true, "")

proc paymentUri*(s: SupportAddress): string =
  ## A link a wallet opens with the address filled in, the amount left to the payer: a
  ## `monero:` URI (wallet2's make_uri), BIP-21, EIP-681. The LEZ has none.
  case s.kind
  of "monero":
    let u = xmr.makePaymentUri(s.chain, s.address, 0'u64, "A tip for Muster", "Muster")
    if u.ok: u.uri else: ""
  of "btc": "bitcoin:" & s.address & "?label=Muster"
  of "evm": "ethereum:" & s.address & "@" & s.chain["evm:".len .. ^1]
  else: ""

proc discloses*(s: SupportAddress, senderForm = ""): JsonNode =
  ## Who sees a tip: {payer, amount: "everyone" | "only Muster", note}.
  case s.kind
  of "evm":
    %*{"payer": "everyone", "amount": "everyone",
       "note": "An Ethereum payment names your address and the amount, on chain, for good."}
  of "btc":
    %*{"payer": "everyone", "amount": "everyone",
       "note": "A Bitcoin payment shows the coins you spend and the amount, on chain, for good."}
  of "monero":
    %*{"payer": "only Muster", "amount": "only Muster",
       "note": "A Monero payment hides who paid and how much from everyone but the recipient."}
  of "lez":
    if lezShielded(s.address) and senderForm == "shielded":
      %*{"payer": "only Muster", "amount": "only Muster",
         "note": "From your shielded account to a shielded one: the private rail hides who paid and how much."}
    elif lezShielded(s.address):
      %*{"payer": "everyone", "amount": "everyone",
         "note": "From a public account the zone sees you shield the amount. Send from your shielded account to hide both."}
    else:
      %*{"payer": "everyone", "amount": "everyone",
         "note": "A public LEZ transfer names both accounts and the amount."}
  else: %*{"payer": "unknown", "amount": "unknown", "note": ""}

# ── amounts ─────────────────────────────────────────────────────────────────────

proc toBaseUnits*(amount: string, decimals: int): tuple[ok: bool, raw, reason: string] =
  ## "1.5", 18 → "1500000000000000000". Digits and at most one point; no more fractional
  ## digits than the asset has; never zero. String arithmetic, so nothing is rounded.
  let s = amount.strip()
  if s.len == 0: return (false, "", "no amount")
  let parts = s.split('.')
  if parts.len > 2: return (false, "", "not a number: " & s.escape)
  let whole = parts[0]
  let frac = (if parts.len == 2: parts[1] else: "")
  if whole.len + frac.len == 0 or not (whole & frac).allCharsInSet({'0'..'9'}):
    return (false, "", "not a number: " & s.escape)
  if frac.len > decimals:
    return (false, "", "at most " & $decimals & " decimal places")
  var raw = (whole & frac & repeat('0', decimals - frac.len)).strip(trailing = false, chars = {'0'})
  if raw.len == 0: return (false, "", "a tip of zero")
  (true, raw, "")

# ── the options the modal shows ─────────────────────────────────────────────────

proc sendersOn(summary: JsonNode, chain: string): JsonNode =
  ## The connected, non-development wallets' balances on `chain` worth sending from:
  ## a read that answered, above zero.
  result = newJArray()
  if summary == nil or summary{"wallets"}.kind != JArray: return
  for w in summary["wallets"]:
    if w{"dev"}.getBool(false): continue
    if w{"balances"}.kind != JArray: continue
    for b in w["balances"]:
      if b{"chain"}.getStr() != chain or b.hasKey("error") or b.hasKey("pending"): continue
      let raw = b{"raw"}.getStr()
      if raw.len == 0 or raw.strip(chars = {'0'}).len == 0: continue
      var s = %*{"wallet": w{"id"}.getStr(), "walletName": w{"name"}.getStr(),
                 "account": b{"account"}.getStr(), "asset": b{"asset"}.getStr(),
                 "display": b{"display"}.getStr(), "raw": raw}
      if b.hasKey("form"): s["form"] = b["form"]
      result.add s

proc connectedWallet*(summary: JsonNode): bool =
  ## A wallet the person connected (not the runner's development key or demo chain).
  if summary == nil or summary{"wallets"}.kind != JArray: return false
  for w in summary["wallets"]:
    if not w{"dev"}.getBool(false): return true
  false

proc supportOptions*(about: string, table: seq[SupportAddress], summary: JsonNode,
                     prompt: string): JsonNode =
  ## {prompt: "unseen" | "dismissed", connected, about, options: [{id, chain, name,
  ##  testnet, address, for, uri, discloses, senders: [{wallet, walletName, account,
  ##  asset, display, raw, form?, discloses}]}]}. An address not set, or one its chain
  ##  would refuse, is left out. Monero is never sent from: Muster never spends it.
  var opts = newJArray()
  for s in table:
    if not validAddress(s).ok: continue
    var senders = newJArray()
    if s.kind in ["evm", "lez"]:
      for x in sendersOn(summary, s.chain):
        x["discloses"] = discloses(s, x{"form"}.getStr())
        senders.add x
    opts.add %*{"id": s.id, "chain": s.chain, "name": s.name, "testnet": s.testnet,
                "address": s.address, "for": s.purpose, "uri": paymentUri(s),
                "discloses": discloses(s), "senders": senders}
  %*{"prompt": (if prompt == "dismissed": "dismissed" else: "unseen"),
     "connected": connectedWallet(summary), "about": about, "options": opts}

proc offeredSender*(options: JsonNode, id, account, asset: string):
    tuple[ok: bool, address, chain, reason: string] =
  ## A send is allowed only as offered: an option the table holds, and a sender the
  ## summary showed for it. The address comes from the table, never the caller.
  if options == nil or options{"options"}.kind != JArray: return (false, "", "", "no options")
  for o in options["options"]:
    if o{"id"}.getStr() != id: continue
    for x in o{"senders"}:
      if x{"account"}.getStr() == account and x{"asset"}.getStr() == asset:
        return (true, o{"address"}.getStr(), o{"chain"}.getStr(), "")
    return (false, "", "", "that wallet cannot send to " & o{"name"}.getStr() & " from here")
  (false, "", "", "no tip address " & id.escape)
