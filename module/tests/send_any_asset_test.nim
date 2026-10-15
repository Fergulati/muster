## Send to someone in any asset Muster splits in (exo-dcc.33): where a payment proposed on
## a member's behalf is paid, by rail (behalfPayTo). Always an address THEY shared into the
## room, never one the sender typed; their own client still checks it before they accept.
##   1. Ethereum (ETH or a token): the address they shared — reused freely, since a
##      payment is confirmed from its own transaction;
##   2. Bitcoin: the address they shared on THAT network — reused freely, since a
##      payment is confirmed by its txid; none shared there: no send;
##   3. LEZ (private): the shielded key node they shared on that zone — but never while
##      another unpaid LEZ payment of the same amount waits on it, since a note is matched
##      by its amount ("amount-in-flight"); another amount goes;
##   4. Monero: as xmr_send_test holds — never an address already backing a payment;
##   5. a share posted in someone else's name never counts (the room's authentic view).

import std/[json, strutils]
import ../src/wallet/[types, lez_core, lez_adapter]
import ../src/coordination/send
import ./probes/xmr_room

proc shareAs(r: Room4, who: string, body: JsonNode, n: uint64) =
  let (s, ks) = r.sessionOf(who)
  let (_, ev) = newMessageEvent("0x" & identityOf(who), int64(Now) + int64(n), $body, n)
  s.publishAuthored(ks, ev)
  r.sync()

const BtcReg = "bip122:0f9188f13cb7b2c71f2a335e3a4fc328"
const BtcTest = "bip122:000000000933ea01ad0ee984209779ba"
let AliceBtc = "bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

block:
  var r = newRoom4("/muster/1/send-any/proto")
  let ev = proc(): seq[Event] = r.bob.roomEvents()

  # 1. Ethereum
  doAssert behalfPayTo(ev(), splitFor, EvmSplitFamily, alice, EvmChain, "1000").why.startsWith("no-shared-address")
  r.shareAs("alice", %*{"kind": "address-share", "asset": "ETH", "address": AlicePayTo, "form": 1}, 1)
  let e1 = behalfPayTo(ev(), splitFor, EvmSplitFamily, alice, EvmChain, "1000")
  doAssert e1.address == AlicePayTo and e1.why == "", $e1
  echo "1. Ethereum: the address they shared OK"

  # 2. Bitcoin, on the network shared and no other
  r.shareAs("alice", %*{"kind": "address-share", "asset": "BTC", "chain": BtcReg, "address": AliceBtc, "form": 1}, 2)
  let b1 = behalfPayTo(ev(), splitFor, BtcSplitFamily, alice, BtcReg, "50000")
  doAssert b1.address == AliceBtc and b1.why == "", $b1
  doAssert behalfPayTo(ev(), splitFor, BtcSplitFamily, alice, BtcTest, "50000").why.startsWith("no-shared-address")
  echo "2. Bitcoin: the address they shared on that network OK"

  # 3. LEZ: a shielded key node, never under a same-amount payment still waiting on it
  let lez = newFakeLezChain()
  let aliceW = newLezAdapter(newFakeLezCore(lez))
  var keyNode = ""
  for (form, address) in aliceW.receiveAddresses(aliceKs):
    if form == "shielded": keyNode = address
  doAssert keyNode.startsWith("priv:"), keyNode
  r.shareAs("alice", %*{"kind": "address-share", "asset": "LEZ", "chain": LezChain, "address": keyNode, "form": "shielded"}, 3)
  let l1 = behalfPayTo(ev(), splitFor, LezSplitFamily, alice, LezChain, "700")
  doAssert l1.address == keyNode and l1.why == "", $l1
  # a send of 700 to her is proposed (Bob its only payer) and not yet paid
  let eff = splitEffectJson(LezChain, "LEZ", "700", alice, keyNode, @[SplitShare(who: bob, amount: "700")], "")
  let id = r.propose(LezPolicy, eff)
  doAssert id.startsWith("0x"), id
  r.sync()
  doAssert behalfPayTo(ev(), splitFor, LezSplitFamily, alice, LezChain, "700").why.startsWith("amount-in-flight")
  doAssert behalfPayTo(ev(), splitFor, LezSplitFamily, alice, LezChain, "701").address == keyNode
  echo "3. LEZ: the key node they shared; never two unpaid payments of one amount on it OK"

  # 4. Monero goes by xmr_send_test's rule
  doAssert behalfPayTo(ev(), splitFor, MoneroSplitFamily, alice, XmrStage, "1").why.startsWith("no-shared-address")
  echo "4. Monero: by its own rule OK"

  # 5. Carol posts a share in Alice's name: never Alice's
  let (cs, cks) = r.sessionOf("carol")
  let (_, forged) = newMessageEvent("0x" & alice, int64(Now) + 9, $(%*{"kind": "address-share", "asset": "BTC",
                                     "chain": BtcTest, "address": "tb1qforged", "form": 1}), 9)
  discard cks
  cs.publish(forged)          # unsigned: the authentic view never reads it as hers
  r.sync()
  doAssert behalfPayTo(ev(), splitFor, BtcSplitFamily, alice, BtcTest, "1").why.startsWith("no-shared-address")
  echo "5. a share in someone else's name never counts OK"

echo "send_any_asset_test: all OK"
