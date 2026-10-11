## exo-720 — a declined intent's audit file. A decline is final, so the fold's stage can be
## "declined"; the file then carries the intent's declines, and its verifier accepts that
## stage only with a decline in the file and the approvals short of the threshold.
##   1. a declined 2-of-2 exports, verifies, and says "declined", with the decline carried;
##   2. the same file with its declines stripped (and re-signed by its exporter) is refused:
##      the claimed stage no longer follows from the file;
##   3. an intent nobody declined carries no "declines" field: its bytes are as before.
## Build: see probes/live_room.nim.

import std/strutils
import ./probes/audit_room

proc hasField(f: CborValue, name: string): bool =
  for (k, _) in f.pairs:
    if k.kind == ckText and k.t == name: return true

# ── 1. declined, exported, verified ──────────────────────────────────────────────
var r = newRoom("/muster/1/720-audit-declined/proto")
let id = r.propose("threshold", effectFor("threshold", 71))
r.declineAs("bob", id)
doAssert intentState(r.alice.log.allEvents(), liveDriverFor, id) == "declined",
  "a 2-of-2 one member declined is declined"
let res = r.exportAs("alice", id)
doAssert res.ok, "export refused: " & res.reason
let f = res.fileOf()
doAssert f.hasField("declines") and f.field("declines").arrOf.len == 1, "the decline rides in the file"
let v = verifyAudit(res.bytes)
doAssert v.ok and v.stage == "declined", "the file verifies as declined: " & v.reason
echo "1. a declined intent exports and verifies as declined OK"

# ── 2. stripped of its declines, the stage no longer follows ────────────────────
block:
  var body = cbMap(@[])
  for (k, val) in f.pairs:
    if k.kind == ckText and k.t in ["signature", "declines"]: continue
    body.pairs.add (k, val)
  let sig = aliceKs.sign(bodyDigest(body))
  body.pairs.add (cbText("signature"), cbBytes(@sig))
  let w = verifyAudit(encode(body))
  doAssert not w.ok and "does not follow" in w.reason, "a declined stage with no decline in the file: " & w.reason
  echo "2. stripped of its declines, the file is refused OK"

# ── 3. no declines, no field ────────────────────────────────────────────────────
block:
  var q = newRoom("/muster/1/720-audit-plain/proto")
  let id2 = q.propose("threshold", effectFor("threshold", 72))
  discard q.approveAs("alice", id2)
  let g = q.exportAs("alice", id2)
  doAssert g.ok and not g.fileOf().hasField("declines"), "a file with no declines has no declines field"
  doAssert verifyAudit(g.bytes).ok
  echo "3. an intent nobody declined carries no declines field OK"

echo "audit_declined_test: all OK"
