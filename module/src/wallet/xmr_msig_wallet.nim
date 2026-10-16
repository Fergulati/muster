## A member's OWN Monero multisig wallet, reached through their monero-wallet-rpc (ADR-020,
## exo-dcc.34): the setting `xmr-msig-rpc`, user-configured infrastructure like `btc-rpc`
## (invariant 8). The wallet holds the member's key and multisig state; Muster holds
## neither, and asks it only the multisig steps and reads below. A signature is asked for
## (`sign`) only after the describe-check passed (drivers/xmr_msig.describeRefusal).
##
## v1 talks to a monero-wallet-rpc started with --disable-rpc-login on 127.0.0.1 (digest
## auth is not implemented). Every call is under a chronos deadline (rpc_budget): a hung
## wallet never holds the module thread. Errors raise WalletError naming the method and the
## wallet's message, never the URL.

import std/[json, strutils]
import chronos
import chronos/apps/http/httpclient
import stew/byteutils
import ./types
import ./rpc_budget

type
  XmrWalletBusy* = object of WalletError
    ## The wallet did not answer in time, or could not be reached: try again on the next
    ## tick. A wallet syncing against a remote node holds its lock for seconds at a time
    ## (seen on stagenet, 2026-10-16), so this is ordinary, never a refusal.
  XmrMsigWallet* = ref object of RootObj
    ## The seam: the real wallet-rpc below, or a test's scripted wallet.
  MsigState* = object
    multisig*, ready*: bool
    threshold*, total*: int
  MsigRound* = object
    info*: string      ## the data the next round's peers need ("" when setup is done)
    address*: string   ## the multisig address, once known
  SignedSet* = object
    txset*: string     ## the set with this wallet's signature added (hex)
    txids*: seq[string]
  RpcXmrMsigWallet* = ref object of XmrMsigWallet
    url: string        ## http://127.0.0.1:<port>

method isMultisig*(w: XmrMsigWallet): MsigState {.base.} = raise newException(WalletError, "abstract")
method prepare*(w: XmrMsigWallet): string {.base.} = raise newException(WalletError, "abstract")
method make*(w: XmrMsigWallet, infos: seq[string], threshold: int): MsigRound {.base.} =
  raise newException(WalletError, "abstract")
method exchange*(w: XmrMsigWallet, infos: seq[string]): MsigRound {.base.} = raise newException(WalletError, "abstract")
method address*(w: XmrMsigWallet): string {.base.} = raise newException(WalletError, "abstract")
method refresh*(w: XmrMsigWallet) {.base.} = raise newException(WalletError, "abstract")
method unlocked*(w: XmrMsigWallet): tuple[balance, unlocked: string] {.base.} = raise newException(WalletError, "abstract")
method exportInfo*(w: XmrMsigWallet): string {.base.} = raise newException(WalletError, "abstract")
method importInfo*(w: XmrMsigWallet, infos: seq[string]): int {.base.} = raise newException(WalletError, "abstract")
method transfer*(w: XmrMsigWallet, recipients: seq[(string, string)]): string {.base.} =
  raise newException(WalletError, "abstract")
method describe*(w: XmrMsigWallet, txset: string): JsonNode {.base.} = raise newException(WalletError, "abstract")
method sign*(w: XmrMsigWallet, txset: string): SignedSet {.base.} = raise newException(WalletError, "abstract")
method submit*(w: XmrMsigWallet, txset: string): seq[string] {.base.} = raise newException(WalletError, "abstract")
method confirmations*(w: XmrMsigWallet, txid: string): int {.base.} = raise newException(WalletError, "abstract")
  ## -1 when the wallet does not know the txid (yet)

proc newRpcXmrMsigWallet*(url: string): RpcXmrMsigWallet =
  var u = url.strip()
  while u.endsWith("/"): u.setLen(u.len - 1)
  RpcXmrMsigWallet(url: u)

type Answer = tuple[status: int, reason, body: string]

proc exchange(address: HttpAddress, body: string, connectBy, headersBy: Duration): Future[Answer] {.
              async: (raises: [CancelledError, HttpError]).} =
  let session = HttpSessionRef.new(connectTimeout = connectBy, headersTimeout = headersBy)
  var req: HttpClientRequestRef
  var resp: HttpClientResponseRef
  try:
    req = HttpClientRequestRef.new(session, address, MethodPost,
                                   headers = @[(key: "Content-Type", value: "application/json")],
                                   body = body.toBytes())
    resp = await req.send()
    let bytes = await resp.getBodyBytes()
    (resp.status, resp.reason, string.fromBytes(bytes))
  finally:
    if resp != nil: await resp.closeWait()
    if req != nil: await req.closeWait()
    await session.closeWait()

proc call*(w: RpcXmrMsigWallet, meth: string, params: JsonNode = newJObject(),
           budget = sendBudget()): JsonNode =
  ## One JSON-RPC 2.0 call to /json_rpc under one deadline: by default the send budget,
  ## since it is the member's own wallet, which may be busy syncing. An RPC error raises
  ## WalletError; a transport failure or no answer within the budget, XmrWalletBusy.
  let body = $(%*{"jsonrpc": "2.0", "id": "muster", "method": meth, "params": params})
  let address = getHttpAddress(w.url & "/json_rpc").valueOr:
    raise newException(WalletError, "monero-wallet-rpc " & meth & ": not a wallet URL (" & $error & ")")
  let connectBy = (if budget > readBudget(): readBudget() else: budget + 1.seconds)
  var ans: Answer
  try: ans = bounded(exchange(address, body, connectBy, budget + 1.seconds), budget)
  except RpcTimeoutError:
    raise newException(XmrWalletBusy, "monero-wallet-rpc " & meth & ": no answer within " & $budget)
  except CatchableError as e:
    raise newException(XmrWalletBusy, "monero-wallet-rpc " & meth & ": unreachable: " & e.msg)
  var j: JsonNode
  try: j = parseJson(ans.body)
  except CatchableError:
    raise newException(WalletError, "monero-wallet-rpc " & meth & ": HTTP " & $ans.status & " " & ans.reason)
  let err = j{"error"}
  if err != nil and err.kind != JNull:
    let msg = err{"message"}.getStr($err)
    # the wallet's node went away (a remote node drops out for a while): try again later
    if "no connection to daemon" in msg.toLowerAscii():
      raise newException(XmrWalletBusy, "monero-wallet-rpc " & meth & ": " & msg)
    raise newException(WalletError, "monero-wallet-rpc " & meth & ": " & msg)
  if j{"result"} == nil: raise newException(WalletError, "monero-wallet-rpc " & meth & ": no result")
  j["result"]

method isMultisig*(w: RpcXmrMsigWallet): MsigState =
  let r = w.call("is_multisig")
  MsigState(multisig: r{"multisig"}.getBool(), ready: r{"ready"}.getBool(),
            threshold: r{"threshold"}.getInt(), total: r{"total"}.getInt())

method prepare*(w: RpcXmrMsigWallet): string =
  ## Upstream's experimental flag is asked for explicitly: the room says so (ADR-020).
  w.call("prepare_multisig", %*{"enable_multisig_experimental": true}, sendBudget())["multisig_info"].getStr()

method make*(w: RpcXmrMsigWallet, infos: seq[string], threshold: int): MsigRound =
  let r = w.call("make_multisig", %*{"multisig_info": infos, "threshold": threshold, "password": ""}, sendBudget())
  MsigRound(info: r{"multisig_info"}.getStr(), address: r{"address"}.getStr())

method exchange*(w: RpcXmrMsigWallet, infos: seq[string]): MsigRound =
  let r = w.call("exchange_multisig_keys", %*{"multisig_info": infos, "password": ""}, sendBudget())
  MsigRound(info: r{"multisig_info"}.getStr(), address: r{"address"}.getStr())

method address*(w: RpcXmrMsigWallet): string = w.call("get_address")["address"].getStr()

method refresh*(w: RpcXmrMsigWallet) = discard w.call("refresh", newJObject(), scanBudget())

method unlocked*(w: RpcXmrMsigWallet): tuple[balance, unlocked: string] =
  let r = w.call("get_balance")
  ($r{"balance"}.getBiggestInt(), $r{"unlocked_balance"}.getBiggestInt())

method exportInfo*(w: RpcXmrMsigWallet): string = w.call("export_multisig_info", newJObject(), sendBudget())["info"].getStr()

method importInfo*(w: RpcXmrMsigWallet, infos: seq[string]): int =
  w.call("import_multisig_info", %*{"info": infos}, sendBudget()){"n_outputs"}.getInt()

method transfer*(w: RpcXmrMsigWallet, recipients: seq[(string, string)]): string =
  ## Build the spend for the members to sign; the multisig wallet returns a transaction set.
  var dests = newJArray()
  for (a, amt) in recipients: dests.add %*{"address": a, "amount": parseBiggestUInt(amt)}
  let r = w.call("transfer", %*{"destinations": dests}, sendBudget())
  let s = r{"multisig_txset"}.getStr()
  if s.len == 0: raise newException(WalletError, "monero-wallet-rpc transfer: no multisig_txset (not a multisig wallet?)")
  s

method describe*(w: RpcXmrMsigWallet, txset: string): JsonNode =
  w.call("describe_transfer", %*{"multisig_txset": txset}, sendBudget())

method sign*(w: RpcXmrMsigWallet, txset: string): SignedSet =
  let r = w.call("sign_multisig", %*{"tx_data_hex": txset}, sendBudget())
  result.txset = r{"tx_data_hex"}.getStr()
  for t in r{"tx_hash_list"}.getElems(): result.txids.add t.getStr()

method submit*(w: RpcXmrMsigWallet, txset: string): seq[string] =
  for t in w.call("submit_multisig", %*{"tx_data_hex": txset}, sendBudget()){"tx_hash_list"}.getElems():
    result.add t.getStr()

method confirmations*(w: RpcXmrMsigWallet, txid: string): int =
  try:
    let r = w.call("get_transfer_by_txid", %*{"txid": txid})
    r{"transfer"}{"confirmations"}.getInt(0)
  except WalletError: -1
