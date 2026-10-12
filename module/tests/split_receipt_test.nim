## A split's receipt (exo-dcc.7, step 1): the signature-audit file for a split family.
## audit.nim refused every split ("unknown policy evm-split@<chain>"): the verifier could
## not rebuild a split driver from the file. A split's materialization is a function of its
## effect and chain alone, and its agreements are room-key (ed:) signatures the verifier
## already checks, so the file can carry it.
##   1. an agreed split exports, and its file verifies from the file alone
##   2. a split paid and confirmed: every counted part report rides in the file, each an
##      external read naming its part, step, author and chain reference, and the file
##      verifies at stage final
##   3. a part report the driver names another author for is refused, even in a file its
##      exporter re-signed: who reports a part is the driver's, read from the effect
##   4. the report for people says, per part, who reported paying and who reported receiving,
##      each an external read, never the raw event value
##   5. an XMR request (monero.split): Bob says he paid, Carol never does; the creditor's own
##      wallet read confirms both. The receipt verifies at final and says exactly that — one
##      "I paid", two confirmations, both by the creditor
## Real sessions and the real split driver (tests/probes/room_map_room.nim).

import std/[strutils, sequtils, algorithm]
import ./probes/room_map_room
import ./probes/xmr_room
import ./probes/fake_monero
import ../src/coordination/audit
import ../src/dcbor/dcbor
import ../src/hashing/hash_input

proc evCbor(e: Event): CborValue =
  ## An event as the audit file carries it.
  var ps = e.parents
  ps.sort()
  cbMap(@[(cbText("id"), cbText(eventId(e))), (cbText("parents"), cbArray(ps.mapIt(cbText(it)))),
          (cbText("key"), cbText(e.key)), (cbText("value"), cbText(e.value))])

proc get(m: CborValue, k: string): CborValue =
  for (kk, v) in m.pairs: (if kk.kind == ckText and kk.t == k: return v)

proc resigned(f: CborValue): seq[byte] =
  ## The file as a dishonest exporter would hand it over: altered, then signed with the
  ## exporter's own key, so only the verifier's own checks can catch it.
  var body = cbMap(@[])
  for (k, v) in f.pairs:
    if not (k.kind == ckText and k.t == "signature"): body.pairs.add (k, v)
  let d = digest(hashInput(AuditFormat, @[("body", cbBytes(encode(body)))]))
  var h: array[32, byte]
  for i in 0 ..< 32: h[i] = d[i]
  body.pairs.add (cbText("signature"), cbBytes(@(aliceKs.sign(h))))
  encode(body)

block:
  var r = newMapRoom("/muster/1/split-receipt/proto")
  r.join("carol", false)
  let id = r.proposeSplit("dinner")
  r.approve("bob", id); r.approve("carol", id)
  let a = exportAudit(r.alice.log.allEvents(), mapFor, id, aliceKs)
  doAssert a.ok, "the split exports: " & a.reason
  let v = verifyAudit(a.bytes)
  doAssert v.ok, "the split's file verifies: " & v.reason
  echo "1. an agreed split exports, and its file verifies from the file alone OK"

var paidFile: seq[byte]
block:
  var r = newMapRoom("/muster/1/split-receipt-paid/proto")
  r.join("carol", false)
  let id = r.proposeSplit("dinner")
  r.approve("bob", id); r.approve("carol", id)
  r.payPart("bob", id, "0x" & "b0".repeat(32)); r.confirmPart("bob", id, "0x" & "b0".repeat(32))
  r.payPart("carol", id, "0x" & "ca".repeat(32)); r.confirmPart("carol", id, "0x" & "ca".repeat(32))
  let a = exportAudit(r.alice.log.allEvents(), mapFor, id, aliceKs)
  doAssert a.ok, "the paid split exports: " & a.reason
  let v = verifyAudit(a.bytes)
  doAssert v.ok, "the paid split's file verifies: " & v.reason
  doAssert v.stage == "final", "stage: " & v.stage
  let parts = v.settlement.filterIt(it.kind.startsWith("part-"))
  doAssert parts.len == 4, "every counted report: " & $v.settlement
  for p in parts:
    doAssert p.grade == "external-read", "a report is what a member said they saw, never proof"
    doAssert p.part.len > 0 and p.author.len > 0
  let settled = parts.filterIt(it.kind == "part-settled")
  let confirmed = parts.filterIt(it.kind == "part-confirmed")
  doAssert settled.len == 2 and confirmed.len == 2
  doAssert settled.mapIt(it.author).sorted() == @[bob, carol].sorted(), "each share reported paid by its debtor"
  doAssert confirmed.allIt(it.author == alice), "each confirmed by the creditor's own read"
  doAssert "0x" & "b0".repeat(32) in settled.mapIt(it.chainRef), "the report names its chain reference"
  paidFile = a.bytes
  echo "2. a paid split carries every counted part report and verifies at final OK"

block:
  # Bob "confirms" his own payment: the driver says only the creditor confirms a part
  let f = decode(paidFile)
  let st = f.get("settlement")
  var swapped = false
  for i in 0 ..< st.arr.len:
    let key = st.arr[i].get("key").t
    if key.endsWith("/confirmed") and not swapped:
      let j = parseJson(st.arr[i].get("value").t)
      j["author"] = %bob
      st.arr[i] = evCbor(Event(key: key, value: $j))
      swapped = true
  doAssert swapped
  let v = verifyAudit(resigned(f))
  doAssert not v.ok and "author" in v.reason, "a report by the wrong member is refused: " & v.reason
  echo "3. a part report by a member the driver does not name is refused OK"

block:
  let rep = renderAuditReport(paidFile)
  doAssert "\"author\"" notin rep, "no raw report value in the report"
  doAssert rep.count("reported paying") == 2 and rep.count("reported receiving") == 2, rep
  doAssert "0x" & "b0".repeat(32) in rep
  doAssert "not proof" in rep
  echo "4. the report says who reported paying and receiving each part, as external reads OK"

block:
  var x = newXmrRoom("/muster/1/split-receipt-xmr/proto", XmrStage)
  let (id, payTo) = x.agreedRequest(@[(bob, "1500000000000"), (carol, "250000000000")], "rent")
  doAssert x.reportPaid("bob", id, txidOf(7)) == "submitted"
  let si = x.subIndexOf(payTo)
  x.wallet("alice").rows = @[row(txidOf(7), "in", "1500000000000", 10, $si),
                             row(txidOf(8), "in", "250000000000", 11, $si)]
  discard x.pump()
  doAssert x.stateOf(id) == "final"
  let (s, _) = x.r.sessionOf("alice")
  let a = exportAudit(s.log.allEvents(), xmrFor, id, aliceKs)
  doAssert a.ok, "the XMR request exports: " & a.reason
  let v = verifyAudit(a.bytes)
  doAssert v.ok and v.stage == "final", "the XMR request's file verifies at final: " & v.reason & " " & v.stage
  let paid = v.settlement.filterIt(it.kind == "part-settled")
  let conf = v.settlement.filterIt(it.kind == "part-confirmed")
  doAssert paid.len == 1 and paid[0].author == bob and paid[0].chainRef == txidOf(7), $v.settlement
  doAssert conf.len == 2 and conf.allIt(it.author == alice), "each confirmed by the creditor's wallet read: " & $conf
  echo "5. an XMR request's receipt: one \"I paid\", two confirmations by the creditor, final OK"

echo "split_receipt_test: all OK"
