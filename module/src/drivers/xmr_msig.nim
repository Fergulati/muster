## monero.multisig-coordinated, kind xmr-msig (ADR-020, exo-dcc.34): a Monero room treasury.
## The room agrees a spend; each member's OWN monero-wallet-rpc holds their key and multisig
## state, and Muster holds neither. This driver is the agreement half: the effect, its
## refusals, the members' room-key agreements (M of N), and the describe-check a signer's
## client runs on a transaction set before its wallet signs (invariant 1, done in the
## member's wallet: a co-signer signs a transaction rebuilt from the same construction data
## describe_transfer reads, docs/labbook/monero-multisig-describe-transfer.md).
##
## Stagenet only, and labelled pre-FCMP++: Monero's current multisig is built on the scheme
## FCMP++ replaces, and upstream calls it experimental. A private regtest chain is accepted
## only where a test builds the driver with `allowRegtest`.

import std/[json, strutils, sequtils, algorithm, options]
import ../crypto/curve25519
import ../dcbor/dcbor
import ../intents/materialization
import ../intents/disclosure
import ../monero/address
import ./driver
import ./manifest
import ./profile

const
  XmrMsigFamily* = "monero.multisig-coordinated"
  XmrMsigKind* = "xmr-msig"
  XmrMsigSchema* = "muster.effect.monero.multisig-spend.v0"
  XmrMsigDomain* = "muster.monero.multisig-spend.v0"
  XmrRegtestChain* = "monero:regtest"   ## a private regtest chain (mainnet-format addresses): tests only
  XmrMaxAtomic = "18446744073709551615"  ## a Monero amount is a uint64

type
  XmrMsigAccount* = object
    chain*: string            ## CAIP-2: stagenet (or, in a test, monero:regtest)
    address*: string          ## the multisig address every member's wallet reports
    k*: int                   ## M: how many members' wallets sign a spend
    members*: seq[string]     ## the N members, by room identity (128 hex: ed25519 ‖ x25519)
  XmrRecipient* = object
    address*, amount*: string ## amount in atomic units, canonical decimal
  XmrSpend* = object
    chain*, account*: string
    recipients*: seq[XmrRecipient]
    feeCap*: string           ## the most fee the members accept, atomic units
    memo*: string
  XmrMsigDriver* = ref object of Driver
    account*: XmrMsigAccount
    allowRegtest: bool
    roster: seq[Ed25519Pub]
    pending: Materialization

proc hexd(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc edOf(member: string): Option[Ed25519Pub] =
  ## A room identity's Ed25519 half: its first 32 bytes.
  var h = member.toLowerAscii()
  if h.startsWith("0x"): h = h[2 .. ^1]
  if h.len < 64: return none(Ed25519Pub)
  var pk: Ed25519Pub
  try:
    for i in 0 ..< 32: pk[i] = byte(parseHexInt(h[2*i .. 2*i+1]))
  except ValueError: return none(Ed25519Pub)
  some(pk)

proc newXmrMsigDriver*(account: XmrMsigAccount, allowRegtest = false): XmrMsigDriver =
  result = XmrMsigDriver(account: account, allowRegtest: allowRegtest)
  for m in account.members:
    let e = edOf(m)
    if e.isSome: result.roster.add e.get

# ── the effect ─────────────────────────────────────────────────────────────────
proc xmrMsigSpendJson*(chain, account: string, recipients: seq[XmrRecipient], feeCap, memo: string): string =
  ## The effect a composer proposes, as the room reviews it.
  $(%*{"effect": "monero-multisig-spend", "chain": chain, "account": account,
       "recipients": recipients.mapIt(%*{"address": it.address, "amount": it.amount}),
       "feeCap": feeCap, "memo": memo})

proc fieldOf(e: Effect, name: string): CborValue =
  for (k, v) in e.fields:
    if k == name: return v
  cbNull()

proc textOf(e: Effect, name: string): string =
  let v = e.fieldOf(name)
  if v.kind == ckText: v.t else: ""

proc xmrSpendOf*(e: Effect): XmrSpend =
  ## The spend an effect carries, as carried — validation is signRefusal's.
  if e.schemaId != XmrMsigSchema: raise newException(ValueError, "not a Monero multisig spend")
  result = XmrSpend(chain: e.textOf("chain"), account: e.textOf("account"),
                    feeCap: e.textOf("feeCap"), memo: e.textOf("memo"))
  let r = e.fieldOf("recipients")
  if r.kind == ckArray:
    for x in r.arr:
      if x.kind != ckArray or x.arr.len != 2 or x.arr[0].kind != ckText or x.arr[1].kind != ckText:
        raise newException(ValueError, "a recipient is [address, amount]")
      result.recipients.add XmrRecipient(address: x.arr[0].t, amount: x.arr[1].t)

proc canonAtomic(s: string): bool =
  ## A positive canonical decimal that fits a uint64.
  if s.len == 0 or s.len > XmrMaxAtomic.len or s[0] == '0' or not s.allCharsInSet(Digits): return false
  s.len < XmrMaxAtomic.len or s <= XmrMaxAtomic

proc addressOnChain(d: XmrMsigDriver, address, chain: string): string =
  ## "" when `address` is a standard address or subaddress on `chain`'s network.
  if chain == XmrRegtestChain:
    let a = parseAddress(address)
    if not a.ok: return a.reason
    if a.network != xmrMainnet: return "not a regtest (mainnet-format) address"
    if a.kind == makIntegrated: return "an integrated address carries a payment id"
    return ""
  let a = acceptablePayTo(address, chain)
  if not a.ok: return a.reason
  ""

method signRefusal*(d: XmrMsigDriver, e: Effect): string =
  ## Why no member's client agrees to this spend ("" = it may): stagenet only (a private
  ## regtest where a test allows it), this account, recipients on this network that are
  ## not integrated addresses, positive canonical atomic amounts, and a fee cap.
  var s: XmrSpend
  try: s = xmrSpendOf(e)
  except ValueError as ex: return ex.msg
  if s.chain == XmrRegtestChain:
    if not d.allowRegtest: return "a private regtest chain is for tests only"
  elif s.chain != caip2Of(xmrStagenet):
    return "stagenet only: Monero multisig is experimental and pre-FCMP++ (ADR-020)"
  if s.chain != d.account.chain: return "the spend names another chain than the account's"
  if s.account != d.account.address: return "the spend names another account"
  if s.recipients.len == 0: return "a spend pays at least one recipient"
  for r in s.recipients:
    let why = d.addressOnChain(r.address, s.chain)
    if why.len > 0: return "recipient " & r.address[0 ..< min(12, r.address.len)] & "…: " & why
    if not canonAtomic(r.amount): return "an amount is a positive whole number of atomic units: " & r.amount
  if not canonAtomic(s.feeCap): return "a spend names its fee cap in atomic units"
  ""

# ── the agreement: members' room keys, M of them ────────────────────────────────
const SignedTag = "muster.monero.multisig-spend.signed.v0"

method describe*(d: XmrMsigDriver): DriverDescriptor =
  ## Two rounds, as Monero's multisig has (the sync carries the signing nonces, then the
  ## signers sign): round 1, M members agree with their room keys; round 2, M signers each
  ## record that their own wallet checked the transaction set (describeRefusal) and signed it.
  DriverDescriptor(rounds: 2, serializationDomain: XmrMsigDomain, finality: finExternal,
                   threshold: d.account.k)

proc roundMessage*(m: Materialization, round: int): seq[byte] =
  ## What a member's room key signs in each round: the materialization (round 1), or a
  ## distinct tag and the materialization (round 2), so neither stands in for the other.
  if round <= 1: return m.bytes
  for c in SignedTag: result.add byte(c)
  result.add m.bytes

method environment*(d: XmrMsigDriver): string = d.account.chain

proc sigOf(c: Contribution): (bool, Ed25519Sig) =
  if c.bytes.len != 64: return (false, default(Ed25519Sig))
  for i in 0 ..< 64: result[1][i] = c.bytes[i]
  result[0] = true

method expectMaterialization*(d: XmrMsigDriver, m: Materialization) = d.pending = m

method verifyContribution*(d: XmrMsigDriver, c: Contribution, round: int): bool =
  ## A member's Ed25519 room-key signature over this round's message.
  let (ok, sig) = sigOf(c)
  if not ok: return false
  let msg = roundMessage(d.pending, round)
  for pk in d.roster:
    if edVerify(pk, msg, sig): return true
  false

method identifyContributor*(d: XmrMsigDriver, m: Materialization, c: Contribution): string =
  ## The member whose room key signed either round's message.
  let (ok, sig) = sigOf(c)
  if not ok: return ""
  for round in [1, 2]:
    let msg = roundMessage(m, round)
    for pk in d.roster:
      if edVerify(pk, msg, sig): return "ed:" & hexd(pk)
  ""

method mayContribute*(d: XmrMsigDriver, e: Effect, names: seq[string]): Eligibility =
  let mine = bareNames(names)
  for pk in d.roster:
    if hexd(pk) in mine: return elYes
  for m in d.account.members:
    if m.toLowerAscii().replace("0x", "") in mine: return elYes
  elNo

# ── the describe-check (invariant 1, in the member's wallet) ────────────────────
proc describeRefusal*(s: XmrSpend, described: JsonNode): string =
  ## Before a member's wallet signs (sign_multisig): "" only when describe_transfer on the
  ## transaction set pays exactly the agreed recipients and amounts (in any order), sends
  ## any change only to the account itself, and spends no more fee than the cap. Every
  ## transaction in the set is checked; the recipients of all of them together must be
  ## exactly the agreed ones.
  if described == nil or described.kind != JObject or described{"desc"} == nil or
     described["desc"].kind != JArray or described["desc"].len == 0:
    return "describe_transfer described no transaction"
  var got: seq[(string, string)]
  var fee: uint64 = 0
  for d in described["desc"]:
    for r in d{"recipients"}.getElems():
      got.add (r{"address"}.getStr(), $r{"amount"}.getBiggestInt())
    fee += uint64(d{"fee"}.getBiggestInt())
    let changeAmt = d{"change_amount"}.getBiggestInt()
    let changeTo = d{"change_address"}.getStr()
    if changeAmt > 0 and changeTo != s.account:
      return "change goes to " & changeTo[0 ..< min(12, changeTo.len)] & "…, not the account"
  let want = s.recipients.mapIt((it.address, it.amount)).sorted()
  if got.sorted() != want:
    return "the transaction's recipients are not the agreed ones"
  if fee > parseBiggestUInt(s.feeCap):
    return "the fee " & $fee & " is over the agreed cap " & s.feeCap
  ""

# ── the family ─────────────────────────────────────────────────────────────────
method profile*(d: XmrMsigDriver): FamilyProfile =
  ## The registry's monero.multisig-coordinated: Monero's own aggregate threshold scheme,
  ## two rounds (the sync, then the signatures); each member's wallet holds secret multisig state; a key
  ## ceremony; a new address for a membership change; the chain shows nothing of the
  ## policy, the signers or the payment. Experimental, as upstream says.
  FamilyProfile(declared: true, family: XmrMsigFamily, settlement: "monero",
    locus: loAggregate, scheme: scAggregateThreshold, commits: cmContent, binding: bdNone,
    ordering: orDedup, expiry: exNone, setup: suDkg, signerChange: chNewAddress,
    revealsPolicy: rvNever, revealsSigners: rvNever, revealsEffect: evShielded,
    approverCost: acNone, rounds: d.describe().rounds, secretState: true, maturity: maExperimental,
    chain: d.account.chain, account: d.account.chain & ":" & d.account.address, k: d.account.k,
    n: d.account.members.len, bypassesKnown: true)

method manifest*(d: XmrMsigDriver, effect: Effect): ActionManifest =
  ## Needs each signer's own monero-wallet-rpc (setting xmr-msig-rpc) and a member's room
  ## key. The chain sees that a transaction exists, nothing of who or how much; each
  ## member's wallet node sees its sync and the signed transaction.
  ActionManifest(declared: true, agreement: d.describe(),
    requirements: @[req(rqEnvironment, d.account.chain), req(rqInfra, "xmr-msig-rpc", rpContributor),
                    req(rqAuthority, "account-member", rpContributor)],
    discloses: @[row("transaction-exists", obChainObserver), row("wallet-sync", obRpcProvider),
                 row("signed-tx", obRpcProvider)],
    touches: @[touch(d.account.chain, tmWrite), touch("monero-msig-wallet:" & d.account.address, tmWrite)])
