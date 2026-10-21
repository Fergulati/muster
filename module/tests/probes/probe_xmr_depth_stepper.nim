## derived-exo-dcc.5 s3 (amended, exo-e16): a part is confirmed only with at least the
## confirmation depth the agreed request names — a whole number of blocks from 1 to 720, 10
## when it names none. The depth is part of what everyone agreed to and signed: the same
## request with another depth is a different request no one agreed to, and a depth outside
## 1-720, or one named on a split that is not a Monero split, is refused. (The default depth
## keeps its own stepper, probe_xmr_confirm_stepper, unchanged.)
##
## STEPPER, 9 states:
##   * states 0-6, one per named depth d in {none, 1, 2, 3, 10, 11, 720}: for each
##     confirmation count c in {0, 1, 2, 3, 9, 10, 11, 719, 720}, a fresh room where Alice
##     proposes the request at d (the hosted path, xmrPropose) and Bob agrees; one history
##     row of exactly Bob's share at payTo, c deep, through Alice's REAL confirm pump. Bob's
##     part is confirmed iff c >= d (10 for none); below it nothing is published and the
##     room is exactly as it was;
##   * state 7, the depth is signed: for every pair d != d' of {none, 1, 2, 3, 10, 11, 720},
##     Bob's agreement signed over the request at d is refused by the real driver checking
##     the same request at d' (its materialization + verifyContribution), and accepted at d;
##   * state 8, refusals: a Monero request naming 0, 721, "01", "-1", "1.5", "x" or "10000"
##     is refused by the real driver and cannot be proposed (nothing published); a depth on
##     an Ethereum, Bitcoin or LEZ split is refused.
## Run by hand (no argv), it checks every state with doAssert.

import std/[json, strutils]
import ./xmr_room
import ./oracle_emit
import ../../src/drivers/[driver, split]
import ../../src/crypto/[keystore, curve25519]

const Depths = ["", "1", "2", "3", "10", "11", "720"]
const Confs = [0, 1, 2, 3, 9, 10, 11, 719, 720]
const Bad = ["0", "721", "01", "-1", "1.5", "x", "10000"]
const N = 9
const Share = "2000000000000"

proc need(d: string): int = (if d.len == 0: 10 else: parseInt(d))

proc depthCase(s, c: int): bool =
  ## Depth Depths[s], confirmations Confs[c], in a fresh room.
  let d = Depths[s]
  var x = newXmrRoom("/muster/1/xmr-depth-" & $s & "-" & $c & "/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, Share)], "depth", confirmations = d)
  if x.stateOf(id) != "executable": return false
  let w = x.wallet("alice")
  let txid = txidOf(s * 100 + c)
  w.rows = @[row(txid, "in", Share, Confs[c], $x.subIndexOf(payTo))]
  let should = Confs[c] >= need(d)
  x.r.sync()
  let logBefore = x.r.alice.roomEvents().len
  let stBefore = x.stateOf(id)
  let got = x.pump()
  x.r.sync()
  let part = x.partOf(id, "bob")
  if part.confirmed != should or got.len != (if should: 1 else: 0): return false
  if should: return part.tx == txid and x.stateOf(id) == "final"
  x.r.alice.roomEvents().len == logBefore and x.stateOf(id) == stBefore

proc effOf(d: string, family = MoneroSplitFamily): string =
  ## the request at depth `d`, Bob owing the share, paid at a stagenet subaddress
  let w = newFakeMonero("wallet-alice", "stagenet")
  case family
  of MoneroSplitFamily:
    splitEffectJson(XmrStage, "XMR", Share, alice, w.mint().address, @[SplitShare(who: bob, amount: Share)],
                    "depth", confirmations = d)
  of EvmSplitFamily:
    splitEffectJson("eip155:31337", "ETH", Share, alice, "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
                    @[SplitShare(who: bob, amount: Share)], "depth", confirmations = d)
  of BtcSplitFamily:
    splitEffectJson("bip122:0f9188f13cb7b2c71f2a335e3a4fc328", "BTC", "100000", alice,
                    "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080", @[SplitShare(who: bob, amount: "100000")],
                    "depth", confirmations = d)
  else:
    splitEffectJson("lez:testnet", "LEZ", "100000", alice, "priv:" & repeat("ab", 32) & ":" & repeat("cd", 32),
                    @[SplitShare(who: bob, amount: "100000")], "depth", confirmations = d)

proc signedState(): bool =
  ## Bob's agreement over the request at one depth counts for that depth alone.
  let w = newFakeMonero("wallet-alice", "stagenet")
  let payTo = w.mint().address
  proc eff(d: string): Effect =
    effectFromJson(splitEffectJson(XmrStage, "XMR", Share, alice, payTo, @[SplitShare(who: bob, amount: Share)],
                                   "depth", confirmations = d))
  let drv = newSplitDriver(MoneroSplitFamily, XmrStage, @[alice, bob])
  for d in Depths:
    let sig = bobKs.edSign(canonicalize(drv, eff(d)).bytes)
    var c = Contribution()
    for b in sig: c.bytes.add b
    for d2 in Depths:
      drv.expectMaterialization(canonicalize(drv, eff(d2)))
      if drv.verifyContribution(c, 1) != (d == d2): return false
  true

proc refusalState(): bool =
  let mon = newSplitDriver(MoneroSplitFamily, XmrStage, @[alice, bob])
  for b in Bad:
    if not mon.signRefusal(effectFromJson(effOf(b))).contains("confirmation depth"): return false
    var x = newXmrRoom("/muster/1/xmr-depth-bad-" & b & "/proto", XmrStage)
    let before = x.r.alice.roomEvents().len
    if x.propose("alice", effOf(b)).startsWith("0x"): return false
    if x.r.alice.roomEvents().len != before: return false
  for (fam, chain) in [(EvmSplitFamily, "eip155:31337"), (BtcSplitFamily, "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"),
                       (LezSplitFamily, "lez:testnet")]:
    let drv = newSplitDriver(fam, chain, @[alice, bob])
    if not drv.signRefusal(effectFromJson(effOf("1", fam))).contains("only a Monero split"): return false
  true

proc correct(s: int): bool =
  if s < Depths.len:
    for c in 0 ..< Confs.len:
      if not depthCase(s, c): return false
    return true
  if s == 7: return signedState()
  refusalState()

proc state(s: int): JsonNode = %*{"case": s, "decision_correct": correct(s)}

let arg = oracleStateArg()
if arg == nil:
  for s in 0 ..< N:
    if s < Depths.len:
      for c in 0 ..< Confs.len:
        doAssert depthCase(s, c), "depth '" & Depths[s] & "', " & $Confs[c] & " confirmations — judged wrongly"
    else:
      doAssert correct(s), "state " & $s & " (" & (if s == 7: "signed" else: "refusals") & ")"
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod N)])
