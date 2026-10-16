## A scripted Monero multisig wallet for the xmr-msig tests (ADR-020): the same seam as a
## member's monero-wallet-rpc, with the exchange's ORDER checked as upstream's wallet
## checks it. Each message names its round and its wallet ("<round>:<id>"); make takes
## round-0 messages, the r-th exchange takes round r messages, each from the N-1 others.
## After `exchanges` exchange rounds the wallet is ready, and every wallet of one setup
## reports the same address: a stagenet (or regtest) standard address whose keys hash the
## sorted wallet ids and the threshold. No cryptography: the order and the outcome only.

import std/[json, strutils, sequtils, algorithm, tables, hashes]
import ../../src/hashing/sha256
import ../../src/crypto/curve25519
import ../../src/monero/address
import ../../src/wallet/[types, xmr_msig_wallet]

type FakeMsigWallet* = ref object of XmrMsigWallet
  id*: string
  net*: MoneroNetwork
  exchanges*: int          ## exchange rounds after make before ready
  calls*: int              ## every call that changes the wallet
  multisig*, ready*: bool
  k*, n*, done*: int
  peers*: seq[string]

proc keyOf(tag: string): array[32, byte] =
  ## a valid curve point, as fake_monero makes one
  var b: seq[byte]
  for c in tag: b.add byte(c)
  let d = sha256(b)
  var seed: array[32, byte]
  for i in 0 ..< 32: seed[i] = d[i]
  encFromSeed(seed).identity().ed

proc newFakeMsigWallet*(id: string, net = xmrStagenet, exchanges = 2): FakeMsigWallet =
  FakeMsigWallet(id: id, net: net, exchanges: exchanges)

proc ownAddress(w: FakeMsigWallet): string =
  encodeAddress(w.net, makStandard, keyOf(w.id & "/spend"), keyOf(w.id & "/view"))

proc sharedAddress(w: FakeMsigWallet): string =
  let tag = (w.peers & @[w.id]).sorted().join(",") & "/" & $w.k
  encodeAddress(w.net, makStandard, keyOf(tag & "/spend"), keyOf(tag & "/view"))

proc takeRound(w: FakeMsigWallet, infos: seq[string], round: int): seq[string] =
  for i in infos:
    let p = i.split(':')
    if p.len != 2 or p[0] != $round:
      raise newException(WalletError, "fake wallet " & w.id & ": expected round " & $round & " messages, got " & i)
    if p[1] == w.id: raise newException(WalletError, "fake wallet " & w.id & ": its own message")
    result.add p[1]

method isMultisig*(w: FakeMsigWallet): MsigState =
  MsigState(multisig: w.multisig, ready: w.ready, threshold: w.k, total: w.n)

method address*(w: FakeMsigWallet): string =
  if w.ready: w.sharedAddress() else: w.ownAddress()

method prepare*(w: FakeMsigWallet): string =
  if w.multisig: raise newException(WalletError, "fake wallet " & w.id & ": already multisig")
  "0:" & w.id

method make*(w: FakeMsigWallet, infos: seq[string], threshold: int): MsigRound =
  if w.multisig: raise newException(WalletError, "fake wallet " & w.id & ": already multisig")
  w.peers = w.takeRound(infos, 0)
  inc w.calls
  (w.multisig, w.k, w.n) = (true, threshold, infos.len + 1)
  MsigRound(info: "1:" & w.id)

method exchange*(w: FakeMsigWallet, infos: seq[string]): MsigRound =
  if not w.multisig or w.ready: raise newException(WalletError, "fake wallet " & w.id & ": not exchanging")
  if w.takeRound(infos, w.done + 1).sorted() != w.peers.sorted():
    raise newException(WalletError, "fake wallet " & w.id & ": messages from other wallets than make's")
  inc w.calls
  inc w.done
  if w.done >= w.exchanges:
    w.ready = true
    return MsigRound(info: "", address: w.sharedAddress())
  MsigRound(info: $(w.done + 1) & ":" & w.id)

proc walletAddressFake*(net: MoneroNetwork): string =
  ## an address nobody in a test agreed to pay
  encodeAddress(net, makStandard, keyOf("mallory/spend"), keyOf("mallory/view"))

# ── the spend half: a shared fake chain ─────────────────────────────────────────
# A transaction set is hex of JSON {recipients, fee, change, signers}. The wallet that
# builds it signs it; a wallet signs or builds only after importing M-1 others' sync data
# from this sync round; a set is accepted on chain with M signatures; a wallet sees a
# spend once it is in a block.
type FakeXmrChain* = ref object
  height*: int
  included*: Table[string, int]     ## txid → block height
  sets*: seq[string]                ## every set submitted

proc newFakeXmrChain*(): FakeXmrChain = FakeXmrChain(included: initTable[string, int]())
proc mine*(c: FakeXmrChain, n = 1) = c.height += n

var fakeChain* = newFakeXmrChain()   ## the one chain every fake wallet of a test spends on
var fakeChange* = 77'u64             ## the change a built spend returns to the wallet

proc hexStr(s: string): string =
  const d = "0123456789abcdef"
  for c in s: (result.add d[ord(c) shr 4]; result.add d[ord(c) and 0x0f])
proc unhexStr(h: string): string =
  for i in countup(0, h.len - 2, 2): result.add char(parseHexInt(h[i .. i + 1]))

type FakeSpendWallet* = ref object of FakeMsigWallet
  imported*: int                    ## others' sync data imported this round
  exports*: int
  fee*: uint64
  tamper*: string                   ## "" honest; "amount" / "recipient" / "fee" builds another spend

proc newFakeSpendWallet*(id: string, net = xmrStagenet): FakeSpendWallet =
  FakeSpendWallet(id: id, net: net, exchanges: 2, fee: 400)

method refresh*(w: FakeSpendWallet) = discard
method exportInfo*(w: FakeSpendWallet): string =
  inc w.exports
  w.imported = 0
  "sync:" & w.id & ":" & $w.exports
method importInfo*(w: FakeSpendWallet, infos: seq[string]): int =
  for i in infos:
    if not i.startsWith("sync:") or i.split(':')[1] == w.id:
      raise newException(WalletError, "fake wallet " & w.id & ": not another wallet's sync data: " & i)
  w.imported = infos.len
  infos.len

method transfer*(w: FakeSpendWallet, recipients: seq[(string, string)]): string =
  if w.imported < w.k - 1: raise newException(WalletError, "fake wallet " & w.id & ": not synced")
  var rs = recipients
  case w.tamper
  of "amount": rs[0][1] = $(parseBiggestUInt(rs[0][1]) + 1)
  of "recipient": rs[0][0] = walletAddressFake(w.net)
  else: discard
  let fee = (if w.tamper == "fee": w.fee * 1000 else: w.fee)
  hexStr($(%*{"recipients": rs.mapIt(%*[it[0], it[1]]), "fee": fee,
               "change": [w.sharedAddress(), fakeChange], "signers": [w.id]}))

method describe*(w: FakeSpendWallet, txset: string): JsonNode =
  let j = parseJson(unhexStr(txset))
  var rs = newJArray()
  for r in j["recipients"]: rs.add %*{"address": r[0].getStr(), "amount": parseBiggestUInt(r[1].getStr())}
  %*{"desc": [{"recipients": rs, "fee": j["fee"].getBiggestInt(),
               "change_address": j["change"][0].getStr(), "change_amount": j["change"][1].getBiggestInt()}]}

method sign*(w: FakeSpendWallet, txset: string): SignedSet =
  if w.imported < w.k - 1: raise newException(WalletError, "fake wallet " & w.id & ": not synced")
  let j = parseJson(unhexStr(txset))
  if j["signers"].getElems().anyIt(it.getStr() == w.id):
    raise newException(WalletError, "fake wallet " & w.id & ": already signed")
  inc w.calls
  j["signers"].add %w.id
  SignedSet(txset: hexStr($j), txids: @["tx-" & $fakeChain.sets.len])

method submit*(w: FakeSpendWallet, txset: string): seq[string] =
  let j = parseJson(unhexStr(txset))
  if j["signers"].len < w.k: raise newException(WalletError, "fake wallet " & w.id & ": not enough signers")
  let txid = "tx" & $hash(txset).uint
  if txid notin fakeChain.included:
    fakeChain.sets.add txset
    fakeChain.included[txid] = fakeChain.height + 1
  @[txid]

method confirmations*(w: FakeSpendWallet, txid: string): int =
  if txid notin fakeChain.included or fakeChain.included[txid] > fakeChain.height: return -1
  fakeChain.height - fakeChain.included[txid] + 1
