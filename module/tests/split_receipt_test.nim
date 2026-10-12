## A split's receipt (exo-dcc.7, step 1): the signature-audit file for a split family.
## audit.nim refused every split ("unknown policy evm-split@<chain>"): the verifier could
## not rebuild a split driver from the file. A split's materialization is a function of its
## effect and chain alone, and its agreements are room-key (ed:) signatures the verifier
## already checks, so the file can carry it.
##   1. an agreed split exports, and its file verifies from the file alone
## Real sessions and the real split driver (tests/probes/room_map_room.nim).

import ./probes/room_map_room
import ../src/coordination/audit

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

echo "split_receipt_test: all OK"
