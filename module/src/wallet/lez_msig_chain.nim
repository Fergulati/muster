## The chain seam a lez-msig settlement needs (epic exo-0d3): read the multisig's state, send
## its instructions, and see whether the chain included them. It also gives the chain's time,
## for the time lock's windows.
##
## `MsigLive` is the user's own LEZ sequencer (invariant 8), through `LezRpc`. The instruction
## goes out as a public v0.3 transaction from this member's own funded LEZ account: the
## keystore signs under `payerLabel` (never exported), and that account pays the fee. The
## multisig's account signs nothing: its authority is its members' approvals, which the program
## checks. A transaction the program refuses is INCLUDED on v0.3 and pays, so a caller judges
## a step by the state it reads back, never by inclusion (docs/labbook/lez-v03-migration.md
## trap 8).

import std/[options, tables, times]
import stint
import ../lez/msig
import ../lez/tx as leztx
import ../lez/account_view
import ../crypto/keystore
import ./types
import ./adapter
import ./lez_multisig_live        # LezRpc

type
  MsigRead* = object
    found*: bool                  ## the account holds a multisig state
    state*: MsigState
    balance*: UInt128             ## the vault: the account's native balance
    height*: uint64

  MsigSent* = object
    ok*: bool
    hash*, error*: string

  MsigChain* = ref object of ChainAdapter
    chain*: string                ## CAIP-2
    program*: seq[byte]           ## the lez-msig program's account id

method readMsig*(c: MsigChain, account: seq[byte]): MsigRead {.base.} =
  raise newException(WalletError, "MsigChain.readMsig is abstract")
method sendMsig*(c: MsigChain, shards: seq[LezShard], instruction: seq[byte]): MsigSent {.base.} =
  raise newException(WalletError, "MsigChain.sendMsig is abstract")
method included*(c: MsigChain, hash: string): bool {.base.} =
  raise newException(WalletError, "MsigChain.included is abstract")
method nowMs*(c: MsigChain): uint64 {.base.} =
  ## The time the chain's windows are judged against. Block timestamps are the sequencer's
  ## wall clock (lez/sequencer/core: Utc::now), so this host's clock is the best estimate.
  uint64(epochTime() * 1000.0)

method describe*(c: MsigChain): ChainDescriptor =
  let native = AssetId(chain: c.chain, symbol: "LEZ", kind: akNative, decimals: 9)
  ChainDescriptor(chain: c.chain, displayName: "Logos Execution Zone (" & c.chain & ")",
                  nativeAsset: native, accountForms: @[afPublic], finality: finImmediate)

method finality*(c: MsigChain, txRef: TxRef): Finality =
  if c.included(txRef.id): Finality(status: fsFinal, detail: "included")
  else: Finality(status: fsPending, detail: "not included yet")

proc msigShards*(program, account: seq[byte], ins: MsigInstruction): seq[LezShard] =
  ## The transaction's rows: the multisig's own shard, then exactly what its outflow selects.
  ## This is the program's own plan check (methods/guest), in the same order.
  result = @[LezShard(account: account, program: program)]
  proc pay(to: seq[byte]): seq[LezShard] = @[nativeShard(account), nativeShard(to)]
  case ins.kind
  of ikCreate, ikQueue: discard
  of ikSpend: result.add pay(ins.spend.to)
  of ikExecute, ikExecuteQueued:
    let a = ins.proposal.action
    case a.kind
    of akTransfer: result.add pay(a.to)
    of akCall:
      for r in a.rows: result.add LezShard(account: r.account, program: r.program)
    of akConfig, akCancel: discard

# ── live: the user's own sequencer ────────────────────────────────────────────
type MsigLive* = ref object of MsigChain
  rpc*: LezRpc
  ks*: Keystore
  payerLabel*: string             ## the keystore label of the member account that sends and pays
  sent: Table[string, float]

proc newMsigLive*(rpc: LezRpc, ks: Keystore, chain: string, program: seq[byte], payerLabel: string): MsigLive =
  MsigLive(rpc: rpc, ks: ks, chain: chain, program: program, payerLabel: payerLabel)

proc payer*(c: MsigLive): seq[byte] = publicAccountId(c.ks.lezMemberKey(c.payerLabel))

method readMsig*(c: MsigLive, account: seq[byte]): MsigRead =
  let h = c.rpc.lastBlockId()
  let a = c.rpc.getAccount(account)
  result = MsigRead(height: h, balance: a.balance)
  for (prog, data) in a.shards:
    if prog == c.program and data.len > 0:
      result.found = true
      result.state = decodeMsigState(data)

method sendMsig*(c: MsigLive, shards: seq[LezShard], instruction: seq[byte]): MsigSent =
  let payer = c.payer()
  var m: LezMessage3
  try:
    m = LezMessage3(programAccount: c.program, shards: shards, nonces: @[c.rpc.getAccount(payer).nonce],
                    instruction: instruction, fee: some defaultFee(payer))
  except CatchableError as e: return MsigSent(ok: false, error: "could not read the payer's nonce: " & e.msg)
  let ws = @[LezWitness(signature: c.ks.lezMemberSign(c.payerLabel, messageHash(m)),
                        xonly: c.ks.lezMemberKey(c.payerLabel))]
  let want = publicTxHash(m, ws)
  try:
    let got = c.rpc.sendTransaction(leeTxPublic(m, ws))
    if got != want: return MsigSent(ok: false, error: "the sequencer answered hash " & got & " for " & want)
  except CatchableError as e: return MsigSent(ok: false, error: e.msg)
  c.sent[want] = epochTime()
  MsigSent(ok: true, hash: want)

method included*(c: MsigLive, hash: string): bool = c.rpc.getTransaction(hash).known
