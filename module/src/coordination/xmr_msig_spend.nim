## A spend from a Monero multisig wallet, over the room (ADR-020 S3, exo-dcc.34.3).
##
## The members agree to the spend with their room keys (round 1, M of them). The first M
## round-1 approvals the fold counts, in its order, are the SIGNER SET; then, each from
## their own wallet and in set order:
##   sync    each signer refreshes and exports its multisig info:
##             intent/<id>/xsync/<member>/<i>/<n>    (author-signed, split into parts)
##   build   the first signer imports the others' info, builds the spend from the AGREED
##           effect (transfer), describes what it built, and publishes the set only if the
##           describe-check passes (the builder's wallet signs as it builds):
##             intent/<id>/xtx/<member>/<i>/<n>
##   sign    each next signer imports, describes the set the previous signer published,
##           signs only if the describe-check passes, and publishes the set it signed
##   round 2 each signer's word that its wallet signed after the check: an Ed25519
##           signature under the driver's round-2 tag (drivers/xmr_msig.roundMessage)
##   submit  the last signer's wallet submits; the room records the txids
##   final   any member's wallet sees the spend at 10 confirmations
## Only one spend per wallet is in flight: a later one waits until the earlier is final,
## expired or declined (the outputs it spends would collide). Muster never builds or signs
## a transaction itself: every wallet decides from what its own describe_transfer shows.
##
## The sets and sync data are what upstream's wallets exchange in any transport; they
## leave the room nowhere. Monero transactions carry no expiry: a set a signer published
## can be signed outside Muster after the room's expiry (the room says so, ADR-020).

import std/[json, strutils, sequtils, tables, algorithm]
import ../log/log
import ../intents/[materialization, lifecycle]
import ../drivers/[driver, xmr_msig]
import ../wallet/xmr_msig_wallet
import ../crypto/[keystore, curve25519]
import ./session
import ./authorship
import ./intent_events
import ./intents
import ./attest
import ./live

const
  XBlobPart* = 90_000           ## hex characters per event: delivery caps a message at 150 KiB
  XmrFinalDepth* = 10           ## Monero's unlock depth: a spend is final at 10 confirmations

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0f)])

proc memberOf(ks: Keystore): string = hexOf(ks.encIdentity().toBytes())
proc contributorName*(member: string): string =
  ## The name the driver gives a member's approvals: its Ed25519 half.
  "ed:" & member[0 ..< min(64, member.len)].toLowerAscii()

# ── blobs: a wallet's data, split into parts and author-signed ──────────────────
proc blobEvents*(intentId, kind, author, hex: string): seq[Event] =
  let n = max(1, (hex.len + XBlobPart - 1) div XBlobPart)
  for i in 0 ..< n:
    let part = hex[i * XBlobPart ..< min(hex.len, (i + 1) * XBlobPart)]
    result.add Event(key: "intent/" & intentId & "/" & kind & "/" & author & "/" & $i & "/" & $n,
                     value: $(%*{"part": part}))

proc readBlob*(events: seq[Event], intentId, kind, author: string): tuple[complete: bool, hex: string] =
  ## The blob `author` published, once every part is in the log; the first of each part stands.
  var parts = initTable[int, string]()
  var total = -1
  for e in canonicalOrder(events):
    let p = e.key.split('/')
    if p.len != 6 or p[0] != "intent" or p[1] != intentId or p[2] != kind or p[3] != author: continue
    var i, n: int
    try: (i, n) = (parseInt(p[4]), parseInt(p[5]))
    except ValueError: continue
    if n < 1 or i < 0 or i >= n or (total >= 0 and n != total): continue
    total = n
    if i notin parts:
      try: parts[i] = parseJson(e.value)["part"].getStr()
      except CatchableError: discard
  if total < 1 or parts.len != total: return (false, "")
  var hex = ""
  for i in 0 ..< total: hex.add parts[i]
  (true, hex)

proc published(events: seq[Event], intentId, kind, author: string): bool =
  for e in events:
    if e.key.startsWith("intent/" & intentId & "/" & kind & "/" & author & "/"): return true

# ── who signs, and which spend may proceed ──────────────────────────────────────
proc signerSet*(events: seq[Event], driverFor: DriverFor, intentId: string, k: int,
                members: seq[string]): seq[string] =
  ## The members whose round-1 approvals the fold counted first, in its order: the M
  ## wallets that sign. Fewer than M until round 1 closes.
  var byName = initTable[string, string]()
  for m in members: byName[contributorName(m)] = m
  for g in approvalGrades(events, driverFor, intentId):
    if g.round != 1 or g.grade == agRejected or g.who notin byName: continue
    let m = byName[g.who]
    if m notin result: result.add m
    if result.len == k: break

proc submittedRef*(events: seq[Event], intentId: string): string =
  for e in canonicalOrder(events):
    if e.key == "intent/" & intentId & "/submit": return e.value
  ""

proc inFlightBefore*(events: seq[Event], folded: Table[string, Intent], policy, intentId: string): string =
  ## The earliest spend from the same wallet that is agreed and not yet final, expired or
  ## declined, if it is not this one: "" = this one may proceed.
  var order: seq[(int, string)]
  var pos = 0
  for e in canonicalOrder(events):
    inc pos
    let p = e.key.split('/')
    if p.len == 3 and p[0] == "intent" and p[2] == "propose" and p[1] in folded:
      let it = folded[p[1]]
      if intentPolicyOf(events, p[1]) != policy: continue
      if it.state in {lsSubmitted, lsSettling, lsExecutable} or
         (it.state == lsCollecting and it.collection.round >= 2):
        order.add (pos, p[1])
  order.sort()
  if order.len > 0 and order[0][1] != intentId: order[0][1] else: ""

# ── this member's next step ─────────────────────────────────────────────────────
proc roundTwo(s: CoordinationSession, ks: Keystore, driverFor: DriverFor, intentId: string,
              nowSec: uint64): string =
  ## This member's round-2 record: its word that its wallet signed after the check.
  let plan = planApproval(s, driverFor, intentId, inApp = true, nowSec)
  if plan.refusal.len > 0: return plan.refusal
  let sig = ks.edSign(roundMessage(plan.mat, 2))
  let att = ks.edSign(plan.p)
  publishApproval(s, driverFor, plan, intentId, "0x" & hexOf(sig), "0x" & hexOf(att), inApp = true)

proc xmrSpendStep*(s: CoordinationSession, ks: Keystore, w: XmrMsigWallet, driverFor: DriverFor,
                   intentId: string, nowSec: uint64): string =
  ## Advance this member's part of one spend by what the log allows: "synced", "built",
  ## "signed", "submitted <txids>", "seen n of 10", "final", "waiting: …", "not-a-signer",
  ## or "refused: …". Idempotent: call it on every tick.
  s.poll()
  let events = s.roomEvents()
  let policy = intentPolicyOf(events, intentId)
  let drv = driverFor(policy)
  if not (drv of XmrMsigDriver): return "refused: not a Monero multisig spend"
  let d = XmrMsigDriver(drv)
  let folded = reduceIntents(events, driverFor)
  if intentId notin folded: return "refused: unknown intent"
  let it = folded[intentId]
  let me = memberOf(ks)
  case it.state
  of lsFinal: return "final"
  of lsExpired, lsDeclined, lsDropped: return "waiting: " & $it.state
  of lsSubmitted, lsSettling:
    let txids = submittedRef(events, intentId)
    if txids.len == 0 or txids == "1": return "waiting: submitted, no txid"
    try:
      w.refresh()
      var least = high(int)
      for t in txids.split(','): least = min(least, w.confirmations(t))
      if least < 0: return "waiting: your wallet has not seen the spend yet"
      if least >= XmrFinalDepth:
        s.publish(finalEvent(intentId, chainRef = txids))
        return "final"
      return "seen " & $least & " of " & $XmrFinalDepth
    except XmrWalletBusy as e: return "waiting: your wallet did not answer (" & e.msg & ")"
    except CatchableError as e: return "refused: " & e.msg
  else: discard
  if it.collection.round < 2 and not it.collection.complete:
    return "waiting: agreement (" & $it.collection.acceptedThisRound & " of " & $d.account.k & ")"
  let set = signerSet(events, driverFor, intentId, d.account.k, d.account.members)
  if set.len < d.account.k: return "waiting: the signer set"
  if me notin set: return "not-a-signer"
  let earlier = inFlightBefore(events, folded, policy, intentId)
  if earlier.len > 0: return "waiting: an earlier spend from this wallet (" & earlier[0 ..< min(10, earlier.len)] & "…)"
  let spend = xmrSpendOf(effectFromJson(effectJsonOf(events, intentId)))
  try:
    # sync: every signer's wallet exports what the others need to build and sign
    if not published(events, intentId, "xsync", me):
      w.refresh()
      for e in blobEvents(intentId, "xsync", me, w.exportInfo()): s.publishAuthored(ks, e)
      return "synced"
    var infos: seq[string]
    var missing = 0
    for m in set:
      let (ok, hex) = readBlob(events, intentId, "xsync", m)
      if not ok: inc missing
      elif m != me: infos.add hex
    if missing > 0: return "waiting: sync from " & $missing & " of " & $set.len & " signers"
    let idx = set.find(me)
    if published(events, intentId, "xtx", me):
      if idx == set.len - 1 and it.state == lsExecutable:
        # the last signer's set is complete: submit it (again, after a restart)
        let (ok, hex) = readBlob(events, intentId, "xtx", me)
        if not ok: return "waiting: my own set's parts"
        let txids = w.submit(hex)
        s.publish(submitEvent(intentId, chainRef = txids.join(",")))
        return "submitted " & txids.join(",")
      return "waiting: signer " & $(idx + 2) & " of " & $set.len
    discard w.importInfo(infos)
    var txset: string
    if idx == 0:
      txset = w.transfer(spend.recipients.mapIt((it.address, it.amount)))
      let why = describeRefusal(spend, w.describe(txset))
      if why.len > 0: return "refused: what your wallet built is not the agreed spend: " & why
    else:
      let (ok, prev) = readBlob(events, intentId, "xtx", set[idx - 1])
      if not ok: return "waiting: signer " & $idx & " of " & $set.len
      let why = describeRefusal(spend, w.describe(prev))
      if why.len > 0: return "refused: the set is not the agreed spend: " & why
      txset = w.sign(prev).txset
    for e in blobEvents(intentId, "xtx", me, txset): s.publishAuthored(ks, e)
    let r2 = roundTwo(s, ks, driverFor, intentId, nowSec)
    if idx < set.len - 1: return (if idx == 0: "built" else: "signed") & " (" & r2 & ")"
    if r2 != $lsExecutable: return "refused: round 2 did not complete: " & r2
    let txids = w.submit(txset)
    s.publish(submitEvent(intentId, chainRef = txids.join(",")))
    "submitted " & txids.join(",")
  except XmrWalletBusy as e:
    "waiting: your wallet did not answer (" & e.msg & ")"
  except CatchableError as e:
    "refused: " & e.msg
