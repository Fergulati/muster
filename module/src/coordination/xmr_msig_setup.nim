## A Monero multisig wallet set up over the room (ADR-020 S2, exo-dcc.34.2).
##
## Each member's OWN monero-wallet-rpc does the key exchange; the room only carries its
## messages, in order, between the members' wallets. Muster holds no Monero key and
## computes none of the exchange: it hands each wallet the others' messages and publishes
## what the wallet returns. The log holds:
##   xmsig/<cid>/open                {chain, k, members}: the M of N and the N members, by
##                                   room identity, named by whoever opens it
##   xmsig/<cid>/join/<member>       the member's consent to take part (author-signed)
##   xmsig/<cid>/kex/<r>/<member>    round r of the member's wallet's key exchange
##                                   (author-signed): r = 0 prepare_multisig, r = 1
##                                   make_multisig, r >= 2 exchange_multisig_keys
## A member's wallet runs round r only when every member's round r-1 is in the log; the
## exchange is over when the wallet says it is ready. Each member then discloses the
## account its own wallet reports, with {ceremony} as config. The room trusts the account
## only when every one of its N members disclosed the same address (`xmrMsigAccountOf`):
## what the room says about the wallet is what each member's wallet said (invariant 9).
##
## Nothing secret enters the log: the exchange messages are what upstream's wallets send
## each other in any transport. A wallet that advanced past the room (a restart between its
## call and the publish) is refused, never re-run: its next message is gone, and the
## member starts again with a fresh wallet.

import std/[json, strutils, sequtils, tables, options]
import ../log/log
import ../crypto/keystore
import ../crypto/curve25519
import ../monero/address
import ../drivers/xmr_msig
import ../wallet/xmr_msig_wallet
import ./session
import ./authorship
import ./accounts

const XmsigPrefix* = "xmsig"

type XmrSetupView* = object
  open*: bool
  chain*: string
  k*: int
  members*: seq[string]                   ## room identities, as the open named them
  joined*: seq[string]                    ## members who consented, first-seen order
  kex*: Table[int, Table[string, string]] ## round → member → that round's message

proc validCid(cid: string): bool =
  cid.len in 1 .. 64 and cid.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'})

proc xmrSetupView*(events: seq[Event], cid: string): XmrSetupView =
  ## The ceremony as the log holds it: reduce(log). The open is read first; a join or a
  ## round message from anyone outside its members is not part of it; the first message
  ## for a (round, member) stands.
  let ordered = canonicalOrder(events)
  for e in ordered:
    if e.key == XmsigPrefix & "/" & cid & "/open":
      try:
        let j = parseJson(e.value)
        let ms = j["members"].getElems().mapIt(it.getStr())
        result = XmrSetupView(open: true, chain: j["chain"].getStr(), k: j["k"].getInt(), members: ms)
        break
      except CatchableError: discard
  if not result.open: return
  for e in ordered:
    let p = e.key.split('/')
    if p.len < 4 or p[0] != XmsigPrefix or p[1] != cid: continue
    case p[2]
    of "join":
      if p[3] in result.members and p[3] notin result.joined: result.joined.add p[3]
    of "kex":
      if p.len < 5 or p[4] notin result.members: continue
      var r: int
      try: r = parseInt(p[3])
      except ValueError: continue
      if r < 0: continue
      if r notin result.kex: result.kex[r] = initTable[string, string]()
      if p[4] notin result.kex[r]:
        try: result.kex[r][p[4]] = parseJson(e.value)["info"].getStr()
        except CatchableError: discard
    else: discard

proc openRefusal*(chain: string, k: int, members: seq[string], allowRegtest = false): string =
  ## Why a setup may not be opened ("" = it may): stagenet only (ADR-020), 2 <= M <= N,
  ## N distinct members.
  if chain == XmrRegtestChain:
    if not allowRegtest: return "a private regtest chain is for tests only"
  elif chain != caip2Of(xmrStagenet):
    return "stagenet only: Monero multisig is experimental and pre-FCMP++ (ADR-020)"
  if members.len < 2: return "a multisig wallet needs at least two members"
  if members.deduplicate().len != members.len: return "a member is named twice"
  if k < 2 or k > members.len: return "M of N needs 2 <= M <= N"
  ""

proc xmrSetupOpen*(s: CoordinationSession, cid, chain: string, k: int, members: seq[string],
                   allowRegtest = false): string =
  ## Open a setup naming its M of N and its members; "" when opened, else why not.
  if not validCid(cid): return "a ceremony id is letters, digits, '-', '_' or '.'"
  let why = openRefusal(chain, k, members, allowRegtest)
  if why.len > 0: return why
  if xmrSetupView(s.roomEvents(), cid).open: return "that ceremony is already open"
  s.publish(Event(key: XmsigPrefix & "/" & cid & "/open",
                  value: $(%*{"chain": chain, "k": k, "members": members})))
  ""

proc memberId(ks: Keystore): string =
  const d = "0123456789abcdef"
  for b in ks.encIdentity().toBytes(): (result.add d[int(b shr 4)]; result.add d[int(b and 0x0f)])

proc xmrSetupJoin*(s: CoordinationSession, ks: Keystore, cid: string): string =
  ## This member's consent to take part; "" when published, else why not.
  let v = xmrSetupView(s.roomEvents(), cid)
  if not v.open: return "the ceremony is not open"
  let me = memberId(ks)
  if me notin v.members: return "you are not one of its members"
  if me notin v.joined:
    s.publishAuthored(ks, Event(key: XmsigPrefix & "/" & cid & "/join/" & me, value: "{}"))
  ""

proc walletNetworkRefusal*(address, chain: string): string =
  ## "" when the wallet's own address is a standard address on `chain`'s network.
  let a = parseAddress(address)
  if not a.ok: return "the wallet's address: " & a.reason
  let want = (if chain == XmrRegtestChain: some(xmrMainnet) else: networkOfChain(chain))
  if want.isNone or a.network != want.get: return "the wallet is on another Monero network than the ceremony"
  if a.kind != makStandard: return "the wallet's address is not a primary address"
  ""

proc nextRound(v: XmrSetupView, me: string): int =
  while result in v.kex and me in v.kex[result]: inc result

proc xmrSetupStep*(s: CoordinationSession, ks: Keystore, w: XmrMsigWallet, cid: string): string =
  ## Advance this member's wallet by what the log allows: "round <r>", "done <address>"
  ## (ready, and disclosed), "waiting: …", or "refused: …". Idempotent: call it on every
  ## tick. Asks the wallet nothing until every member has joined.
  s.poll()
  let events = s.roomEvents()
  let v = xmrSetupView(events, cid)
  if not v.open: return "waiting: the ceremony is not open"
  let me = memberId(ks)
  if me notin v.members: return "not-a-participant"
  if me notin v.joined: return "waiting: you have not joined"
  if v.joined.len < v.members.len:
    return "waiting: " & $v.joined.len & " of " & $v.members.len & " members joined"
  let n = v.members.len
  let r = nextRound(v, me)
  try:
    let st = w.isMultisig()
    if st.ready:
      if st.threshold != v.k or st.total != n:
        return "refused: the wallet is a " & $st.threshold & "-of-" & $st.total & " wallet, not this ceremony's " &
               $v.k & "-of-" & $n
      if r < 2: return "refused: the wallet was already a multisig wallet; use a fresh wallet"
      let address = w.address()
      let why = walletNetworkRefusal(address, v.chain)
      if why.len > 0: return "refused: " & why
      let (found, ra) = findAccount(reduceAccounts(events), accountId(v.chain, address))
      if not (found and me in ra.disclosedBy):
        s.publishAuthored(ks, accountDiscloseEvent(RoomAccount(family: XmrMsigFamily, chain: v.chain,
          address: address, label: "Monero multisig " & $v.k & " of " & $n, signers: v.members,
          threshold: v.k, config: $(%*{"ceremony": cid})), me))
      return "done " & address
    if r == 0:
      if st.multisig: return "refused: the wallet is already a multisig wallet; use a fresh wallet"
      let why = walletNetworkRefusal(w.address(), v.chain)
      if why.len > 0: return "refused: " & why
      let info = w.prepare()
      s.publishAuthored(ks, Event(key: XmsigPrefix & "/" & cid & "/kex/0/" & me, value: $(%*{"info": info})))
      return "round 0"
    let prev = v.kex.getOrDefault(r - 1)
    if prev.len < n: return "waiting: round " & $(r - 1) & " from " & $(n - prev.len) & " members"
    let others = v.members.filterIt(it != me).mapIt(prev[it])
    var res: MsigRound
    if r == 1:
      if st.multisig: return "refused: the wallet advanced past the room; use a fresh wallet"
      res = w.make(others, v.k)
    else:
      if not st.multisig: return "refused: the wallet is not part of this ceremony's exchange"
      res = w.exchange(others)
    s.publishAuthored(ks, Event(key: XmsigPrefix & "/" & cid & "/kex/" & $r & "/" & me,
                                value: $(%*{"info": res.info})))
    "round " & $r
  except XmrWalletBusy as e:
    "waiting: your wallet did not answer (" & e.msg & ")"
  except CatchableError as e:
    "refused: " & e.msg

proc xmrSetupsJson*(events: seq[Event], me: string): JsonNode =
  ## Every setup in the room, for the UI: its M of N, who joined, the round each member's
  ## wallet has published, and whether this member is in it.
  result = newJArray()
  var seen: seq[string]
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len == 3 and p[0] == XmsigPrefix and p[2] == "open" and p[1] notin seen:
      seen.add p[1]
      let v = xmrSetupView(events, p[1])
      if not v.open: continue
      var rounds = newJObject()
      for m in v.members: rounds[m] = %nextRound(v, m)
      result.add %*{"ceremony": p[1], "chain": v.chain, "k": v.k, "n": v.members.len,
                    "members": v.members, "joined": v.joined, "rounds": rounds,
                    "mine": me in v.members, "joinedByMe": me in v.joined}
