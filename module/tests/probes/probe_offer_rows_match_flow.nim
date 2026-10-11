## s6 — choosing material is choosing observers (contracts/specs/derived-exo-45e, oracle c6;
## property/trace).
##
## For a randomly chosen field a Safe payment's material can fill (every field its manifest
## declares, and one it does not), the rows an offer promises for a candidate equal, as a set
## of (field, observer) pairs, the rows the information-flow view (reduceFlow) records for
## that field once the material is shared into the room and the intent is submitted. Before
## 2026-10-11 the promise named only the manifest's rows, never the room the share itself
## shows the material to, so it understated what a choice discloses (offers.nim now names
## both).
## Emits {"traces": [[{promise_equals_record}, …]]}; self-asserts too.

import std/[sets, sequtils]
import ./live_room
import ../../src/drivers/manifest
import ../../src/coordination/offers
import ../../src/coordination/flow
import ../../src/wallet/material
import ../../src/intents/disclosure
import ./oracle_emit

var rngState: uint64 = 0xA0761D6478BD642F'u64
proc nextR(n: int): int =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  int((rngState shr 33) mod uint64(n))

let effectJson = effectFor("safe", 7)
let id = intentIdFor(effectJson, "safe")
let m = safeDrv.manifest(effectFromJson(effectJson))
var fields = m.discloses.mapIt(it.field).deduplicate()
fields.add "memo"                             # a field the manifest declares nothing for
let mine = @[Material(class: mcAddress, chain: "evm:31337", form: "public",
                      handle: "adapter:evm:31337:0xACCT", public: "0xACCT", grade: mgAttested,
                      source: msAdapter)]

proc pairs(rows: seq[DisclosureRow], field: string): HashSet[(string, string)] =
  for r in rows:
    if r.field == field: result.incl (r.field, $r.to)

var observations: seq[JsonNode]
for trial in 0 ..< 120:
  let field = fields[nextR(fields.len)]
  let r = req(rqAddress, "payee", rpCounterparty, need(mcAddress, "chain:31337", field))
  let offers = recipientOffers(@[r], mine, m)
  doAssert offers.len == 1 and offers[0].candidates.len == 1
  let promised = pairs(offers[0].candidates[0].discloses, field)
  # bind it: the share, then the intent leaves the room
  let events = @[policyDeclEvent(id, "safe"), proposeEvent(id, effectJson),
                 materialShareEvent(id, "payee", "bob", "0xACCT", "public", "address", field),
                 submitEvent(id)]
  let recorded = pairs(reduceFlow(events, liveDriverFor, @["alice", "bob"]).mapIt(
                       DisclosureRow(field: it.field, to: it.to)), field)
  observations.add flag("promise_equals_record", promised == recorded and promised.len > 0)

emitTrials(observations)
doAssert observations.allIt(it["promise_equals_record"].getBool),
  "an offer's promised rows differ from what the flow records once the material is bound"
stderr.writeLine "probe_offer_rows_match_flow: OK (120 trials over ", fields.len, " fields; promise = record)"
