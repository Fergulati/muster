## The coordinated Monero multisig, S1 (ADR-020, exo-dcc.34.1): family
## monero.multisig-coordinated, kind xmr-msig. The room agrees a spend; each member's own
## monero-wallet-rpc holds the key; Muster holds none. Held here:
##   1. the effect parses and decodes as written (muster.effect.monero.multisig-spend.v0)
##   2. the driver refuses what ADR-020 rules out: a chain other than stagenet (a private
##      regtest only where a test allows it), another account, a recipient on another
##      network or an integrated address, an amount that is not a positive canonical
##      decimal, no recipients, no fee cap
##   3. agreements are room-key signatures of the account's members, M of them
##   4. the describe-check: a signer's client signs only a transaction set whose
##      describe_transfer pays exactly the agreed recipients and amounts, with change only
##      to the account and the fee within the cap
##   5. it conforms (the suite every driver passes)

import std/[json, strutils, sequtils]
import ../src/crypto/curve25519
import ../src/crypto/keystore
import ../src/intents/materialization
import ../src/drivers/driver
import ../src/drivers/conformance
import ../src/drivers/xmr_msig
import ../src/coordination/intent_events
import ../src/monero/address
import ./probes/fake_monero

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc key(n: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = n)
let ks = @[newInMemoryKeystore(key(11), seed(1)), newInMemoryKeystore(key(12), seed(2)), newInMemoryKeystore(key(13), seed(3))]
proc idOf(k: Keystore): string =
  const d = "0123456789abcdef"
  for x in k.encIdentity().toBytes(): (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])
let members = ks.mapIt(idOf(it))
let Stage = caip2Of(xmrStagenet)
let account = walletAddress("treasury", xmrStagenet, 0, makStandard)
let dest = walletAddress("bob-wallet", xmrStagenet, 3)
let dest2 = walletAddress("carol-wallet", xmrStagenet, 1)
let acct = XmrMsigAccount(chain: Stage, address: account, k: 2, members: members)

proc spend(recips: seq[(string, string)], feeCap = "50000000000", chain = Stage, acc = account): string =
  xmrMsigSpendJson(chain, acc, recips.mapIt(XmrRecipient(address: it[0], amount: it[1])), feeCap, "rent")

block effect:
  let e = effectFromJson(spend(@[(dest, "1234567890000")]))
  doAssert e.schemaId == XmrMsigSchema, e.schemaId
  let s = xmrSpendOf(e)
  doAssert s.chain == Stage and s.account == account and s.feeCap == "50000000000" and s.memo == "rent"
  doAssert s.recipients == @[XmrRecipient(address: dest, amount: "1234567890000")]
  echo "1. the effect parses and decodes as written OK"

block refusals:
  let d = newXmrMsigDriver(acct)
  doAssert d.signRefusal(effectFromJson(spend(@[(dest, "1234567890000")]))) == "", "a valid spend"
  doAssert d.signRefusal(effectFromJson(spend(@[(dest, "1")], chain = caip2Of(xmrMainnet)))).len > 0, "mainnet refused"
  doAssert d.signRefusal(effectFromJson(spend(@[(dest, "1")], chain = XmrRegtestChain))).len > 0, "regtest refused unless allowed"
  doAssert d.signRefusal(effectFromJson(spend(@[(dest, "1")], acc = dest2))).len > 0, "another account"
  doAssert d.signRefusal(effectFromJson(spend(@[(walletAddress("x", xmrMainnet, 1), "1")]))).len > 0, "another network"
  doAssert d.signRefusal(effectFromJson(spend(@[(walletAddress("x", xmrStagenet, 0, makIntegrated), "1")]))).len > 0, "integrated"
  for bad in ["0", "01", "-1", "1.5", "", "99999999999999999999999"]:
    doAssert d.signRefusal(effectFromJson(spend(@[(dest, bad)]))).len > 0, "amount " & bad
  doAssert d.signRefusal(effectFromJson(spend(@[]))).len > 0, "no recipients"
  doAssert d.signRefusal(effectFromJson(spend(@[(dest, "1")], feeCap = ""))).len > 0, "no fee cap"
  let reg = newXmrMsigDriver(XmrMsigAccount(chain: XmrRegtestChain, address: walletAddress("t", xmrMainnet, 0, makStandard),
                                            k: 2, members: members), allowRegtest = true)
  doAssert reg.signRefusal(effectFromJson(spend(@[(walletAddress("d", xmrMainnet, 1), "5")], chain = XmrRegtestChain,
                                                acc = reg.account.address))) == "", "regtest where a test allows it"
  echo "2. stagenet only, this account, this network's addresses, positive canonical amounts, a fee cap OK"

block agreements:
  let d = newXmrMsigDriver(acct)
  let e = effectFromJson(spend(@[(dest, "1234567890000")]))
  doAssert d.describe().threshold == 2 and d.describe().rounds == 2
  let m = canonicalize(d, e)
  d.expectMaterialization(m)
  let sig = ks[1].edSign(m.bytes)
  doAssert d.verifyContribution(Contribution(bytes: @sig), 1), "a member's room key"
  doAssert d.identifyContributor(m, Contribution(bytes: @sig)).startsWith("ed:")
  let outsider = newInMemoryKeystore(key(14), seed(4))
  doAssert not d.verifyContribution(Contribution(bytes: @(outsider.edSign(m.bytes))), 1), "not a member"
  doAssert d.mayContribute(e, @[members[0]]) == elYes and d.mayContribute(e, @[idOf(outsider)]) == elNo
  # round 2, "my wallet checked and signed": its own message, never the round-1 one
  let signed2 = ks[2].edSign(roundMessage(m, 2))
  doAssert d.verifyContribution(Contribution(bytes: @signed2), 2), "a signer's round-2 record"
  doAssert not d.verifyContribution(Contribution(bytes: @signed2), 1), "a round-2 record is no agreement"
  doAssert not d.verifyContribution(Contribution(bytes: @sig), 2), "an agreement is no round-2 record"
  doAssert d.identifyContributor(m, Contribution(bytes: @signed2)).startsWith("ed:")
  echo "3. agreements are members' room keys, M of them; round 2 its own message OK"

block describeCheck:
  let s = xmrSpendOf(effectFromJson(spend(@[(dest, "1000"), (dest2, "2000")], feeCap = "500")))
  proc desc(recips: seq[(string, int)], fee = 400, change = account, changeAmt = 77): JsonNode =
    %*{"desc": [{"recipients": recips.mapIt(%*{"address": it[0], "amount": it[1]}), "fee": fee,
                 "change_address": change, "change_amount": changeAmt}]}
  doAssert describeRefusal(s, desc(@[(dest, 1000), (dest2, 2000)])) == "", "exactly the agreed payment"
  doAssert describeRefusal(s, desc(@[(dest2, 2000), (dest, 1000)])) == "", "in any order"
  doAssert "recipients" in describeRefusal(s, desc(@[(dest, 1000)])), "one missing"
  doAssert "recipients" in describeRefusal(s, desc(@[(dest, 1000), (dest2, 2000), (walletAddress("m", xmrStagenet, 9), 5)])), "one extra"
  doAssert "recipients" in describeRefusal(s, desc(@[(dest, 1001), (dest2, 2000)])), "an amount changed"
  doAssert "fee" in describeRefusal(s, desc(@[(dest, 1000), (dest2, 2000)], fee = 501)), "a fee over the cap"
  doAssert "change" in describeRefusal(s, desc(@[(dest, 1000), (dest2, 2000)], change = dest2)), "change elsewhere"
  doAssert describeRefusal(s, desc(@[(dest, 1000), (dest2, 2000)], change = "", changeAmt = 0)) == "", "no change at all"
  doAssert describeRefusal(s, %*{"desc": []}).len > 0 and describeRefusal(s, %*{"error": "x"}).len > 0, "nothing described"
  echo "4. the describe-check: the agreed recipients and amounts only, change to the account, the fee within the cap OK"

block conforms:
  let d = newXmrMsigDriver(acct)
  let e = effectFromJson(spend(@[(dest, "1234567890000")]))
  let t = effectFromJson(spend(@[(dest, "1234567890001")]))
  let m = canonicalize(d, e)
  let r = checkConformance(d, e, t, Contribution(bytes: @(ks[0].edSign(m.bytes))),
                           @[Contribution(bytes: @(ks[0].edSign(roundMessage(m, 2))))])
  doAssert r.allPass(), "xmr-msig must conform: " & $r.failed()
  echo "5. conforms (", r.checks.len, " checks) OK"

echo "xmr_msig_test: all OK"
