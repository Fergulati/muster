## Sending to someone in the room (exo-dcc.32, exo-dcc.33): a payment proposed on a member's
## behalf, with the sender its only payer — a split, so it is agreed, settled and confirmed
## like any (the split driver's agreesByProposing makes the sender's proposal their
## agreement). This module answers the one question a send adds: where it is paid. Always
## an address the payee shared into the room (an author-signed address-share, read over
## the room's authentic view), never one the sender typed; the payee's own client still
## checks it before they accept (creditorAgreeRefusal, xmrCreditorRefusal).
##
## Pure over the log — headless-testable; the hosted module wires it in.

import std/[json, strutils]
import ../log/log
import ../intents/materialization
import ../drivers/split
import ./intent_events
import ./intents
import ./xmr_request

proc bare(s: string): string =
  result = s.toLowerAscii()
  if result.startsWith("0x"): result = result[2 .. ^1]

proc sharedAddressOn*(events: seq[Event], who, asset, chain: string): string =
  ## The address `who` last shared into the room for `asset` on `chain` — their newest
  ## address-share card naming both, as written (Bitcoin and LEZ addresses are compared as
  ## written; case matters for some) — or "".
  let w = bare(who)
  for m in reduceMessages(events):             # oldest first: the newest share wins
    if bare(m.author) != w: continue
    try:
      let b = parseJson(m.body)
      if b.kind != JObject or b{"kind"}.getStr() != "address-share" or
         b{"asset"}.getStr() != asset or b{"chain"}.getStr() != chain: continue
      let a = b{"address"}.getStr()
      if a.len > 0: result = a
    except CatchableError: discard

proc lezAmountInFlight(events: seq[Event], driverFor: DriverFor, payTo, amount: string): bool =
  ## Whether a LEZ payment of exactly `amount` to `payTo` is proposed here and not yet done:
  ## a private note is matched to its part by amount at the key node, so a second unpaid
  ## payment of the same amount there could take the first one's note.
  for e in events:
    if not (e.key.startsWith("intent/") and e.key.endsWith("/propose")): continue
    let id = e.key["intent/".len ..< e.key.len - "/propose".len]
    let ej = effectJsonOf(events, id)
    if ej.len == 0: continue
    try:
      let sp = splitOf(effectFromJson(ej))
      if familyOfChain(sp.chain) != LezSplitFamily or sp.payTo != payTo: continue
      var same = false
      for sh in sp.shares:
        if sh.amount == amount: same = true
      if not same: continue
      if intentState(events, driverFor, id) notin ["final", "expired", "cancelled", "declined"]:
        return true
    except CatchableError: discard

proc behalfPayTo*(events: seq[Event], driverFor: DriverFor, family, who, chain,
                  amount: string): tuple[address, why: string] =
  ## Where a payment of `amount` to the member `who`, on `chain` of `family`, is paid when
  ## someone else proposes it:
  ##  - Ethereum (ETH or a token): the address they shared — reused freely, since each
  ##    payment is confirmed from its own transaction;
  ##  - Bitcoin: the address they shared on that network — reused freely, confirmed by txid;
  ##  - LEZ (private): the shielded key node they shared on that zone, refused while another
  ##    unpaid payment of the same amount waits on it ("amount-in-flight");
  ##  - Monero: xmrBehalfPayTo — never an address already backing a payment.
  ## "no-shared-address" when they shared none for it.
  var a = ""
  if family == MoneroSplitFamily: return xmrBehalfPayTo(events, who, chain)
  elif family == BtcSplitFamily: a = sharedAddressOn(events, who, "BTC", chain)
  elif family == LezSplitFamily:
    a = sharedAddressOn(events, who, "LEZ", chain)
    if a.len > 0 and lezAmountInFlight(events, driverFor, a, amount):
      return ("", "amount-in-flight: a payment of the same amount to their shared address is not done yet; " &
                  "send a slightly different amount, or ask them to share a fresh address")
  else: a = sharedAddressOf(events, who)
  if a.len == 0: return ("", "no-shared-address: they have shared no address for this on " & chain)
  (a, "")
