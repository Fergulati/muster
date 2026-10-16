## A scripted Monero multisig wallet for the xmr-msig tests (ADR-020): the same seam as a
## member's monero-wallet-rpc, with the exchange's ORDER checked as upstream's wallet
## checks it. Each message names its round and its wallet ("<round>:<id>"); make takes
## round-0 messages, the r-th exchange takes round r messages, each from the N-1 others.
## After `exchanges` exchange rounds the wallet is ready, and every wallet of one setup
## reports the same address: a stagenet (or regtest) standard address whose keys hash the
## sorted wallet ids and the threshold. No cryptography: the order and the outcome only.

import std/[json, strutils, sequtils, algorithm]
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
