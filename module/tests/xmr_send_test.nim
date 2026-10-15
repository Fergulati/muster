## Send Monero to someone (exo-dcc.32). A send is a Monero payment request proposed on the
## payee's behalf, with the sender its only payer: no new settlement, and ADR-018 holds —
## Muster holds no Monero key, the sender pays from any wallet, the payee's own wallet
## confirms. Held here:
##   1. the sender's proposal is their agreement (they are its only payer), so a send is
##      payable as soon as the payee agrees — one click each;
##   2. it pays at the newest address the payee shared, and nothing else;
##   3. an address that already backs a Monero payment in the room is never reused — the
##      payee's wallet could not tell the two apart ("shared-address-used"), nothing published;
##   4. with no address shared there is no send ("no-shared-address");
##   5. a payer proposing a split with OTHER payers in it still agrees by hand (unchanged).

import std/[json, strutils, sequtils]
import ./probes/xmr_room

proc sends(x: var XmrRoom, who, to, amount: string): string =
  ## `who` sends `amount` to `to` through the module's send path.
  inc x.seqNo
  let (s, ks) = x.r.sessionOf(who)
  xmrSend(s, ks, xmrFor, x.wallet(who), x.chain, identityOf(to), amount, "lunch",
          int64(Now), x.seqNo, Ttl)

proc share(x: XmrRoom, who: string, n: uint64, at: int64): string =
  let (s, ks) = x.r.sessionOf(who)
  let r = xmrShareAddress(s, ks, x.wallet(who), x.chain, n, at)
  doAssert r.ok, r.why
  x.r.sync()
  r.address

block send:
  var x = newXmrRoom("/muster/1/xmr-send/proto", XmrStage)
  # 4. nothing shared yet: no send, nothing published
  let before = x.r.bob.roomEvents().len
  let none = x.sends("bob", "alice", "500000000000")
  doAssert none.startsWith("no-shared-address"), none
  x.r.sync()
  doAssert x.r.bob.roomEvents().len == before, "a refused send publishes nothing"
  echo "4. no address shared: no send OK"

  # 1–2. Alice shares an address; Bob sends her 0.5 XMR at it
  let a1 = x.share("alice", 1, int64(Now))
  let id = x.sends("bob", "alice", "500000000000")
  doAssert id.startsWith("0x"), id
  x.r.sync()
  let ej = parseJson(effectJsonOf(x.r.alice.roomEvents(), id))
  doAssert ej["payTo"].getStr() == a1, "paid at the address she shared: " & $ej
  doAssert x.stateOf(id) == "collecting", "her word is still to come: " & x.stateOf(id)
  doAssert x.agree("alice", id) == "executable", "Bob's proposal was his agreement: one click each"
  x.r.sync()
  let link = x.linkOf("bob", id, "bob")
  doAssert link.ok and link.payTo == a1 and link.amount == "500000000000", $link
  echo "1-2. the sender's proposal is his agreement; paid at her shared address OK"

  # 3. Carol sends to the same address: refused, nothing published
  let n = x.r.carol.roomEvents().len
  let reused = x.sends("carol", "alice", "200000000000")
  doAssert reused.startsWith("shared-address-used"), reused
  x.r.sync()
  doAssert x.r.carol.roomEvents().len == n, "a refused send publishes nothing"
  # once Alice shares a fresh one, Carol's send goes through, at that one
  let a2 = x.share("alice", 2, int64(Now) + 60)
  doAssert a2 != a1
  let id2 = x.sends("carol", "alice", "200000000000")
  doAssert id2.startsWith("0x"), id2
  x.r.sync()
  doAssert parseJson(effectJsonOf(x.r.bob.roomEvents(), id2))["payTo"].getStr() == a2
  echo "3. an address backing a payment is never reused; a fresh share is OK"

block othersInIt:
  # 5. Bob proposes, on Alice's behalf, a split that names Carol too: Bob agrees by hand
  var x = newXmrRoom("/muster/1/xmr-send-2/proto", XmrStage)
  let a = x.share("alice", 1, int64(Now))
  let id = x.propose("bob", x.requestJson(a, @[(bob, "400"), (carol, "300")], "on behalf"))
  doAssert id.startsWith("0x"), id
  x.r.sync()
  doAssert x.agree("alice", id) == "collecting"
  doAssert x.agree("carol", id) == "collecting", "Bob has not agreed: there are other payers"
  doAssert x.agree("bob", id) == "executable"
  echo "5. a payer among several still agrees by hand OK"

echo "xmr_send_test: all OK"
