## s7 — material is classified, never scored (contracts/specs/derived-exo-45e, oracle c7;
## property/trace).
##
## Over random catalogues and requirements, every candidate the offers surface returns (its
## JSON, what the card renders) carries a public face, a class, a form, a grade and its
## disclosure rows, and nothing else: no number anywhere (no score, rank, weight or
## percentage), and no ordering of its own. Candidates come in the catalogue's order, so a
## permuted catalogue permutes them the same way.
## Emits {"traces": [[{classify_not_score}, …]]}; self-asserts too.

import std/[sequtils, algorithm]
import ../../src/drivers/manifest
import ../../src/coordination/offers
import ../../src/wallet/material
import ../../src/intents/disclosure
import ./oracle_emit

var rngState: uint64 = 0xE7037ED1A0B428DB'u64
proc nextR(n: int): int =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  int((rngState shr 33) mod uint64(n))

const Allowed = ["public", "class", "form", "grade", "discloses"]
let grades = [mgVerifiedLocally, mgAttested, mgDeclared]

proc noNumbers(j: JsonNode): bool =
  case j.kind
  of JInt, JFloat: false
  of JObject: toSeq(j.pairs).allIt(noNumbers(it.val))
  of JArray: toSeq(j.items).allIt(noNumbers(it))
  else: true

let m = ActionManifest(declared: true, discloses: @[row("to", obChainObserver), row("value", obChainObserver)])
var observations: seq[JsonNode]
for trial in 0 ..< 200:
  var cat: seq[Material]
  for i in 0 ..< 1 + nextR(7):
    let isAddr = nextR(2) == 0
    cat.add Material(class: (if isAddr: mcAddress else: mcAuthority), chain: (if isAddr: "evm:31337" else: ""),
                     form: (if isAddr: "public" else: "secp256k1"), handle: "h" & $trial & "-" & $i,
                     public: "0xP" & $trial & "-" & $i, grade: grades[nextR(grades.len)], source: msAdapter)
  let reqs = @[req(rqAddress, "payee", rpCounterparty, need(mcAddress, "chain:31337", "to")),
               req(rqAuthority, "signer", rpContributor, need(mcAuthority, "signer"))]
  let offers = recipientOffers(reqs, cat, m)
  var ok = true
  for o in offers:
    let j = o.toJson()
    for c in j["candidates"]:
      if toSeq(c.keys).anyIt(it notin Allowed) or not noNumbers(c): ok = false
    # input-stable: the candidates are the matching holdings in the catalogue's own order
    let want = cat.filterIt(it.class == o.requirement.needs.class).mapIt(it.public)
    if o.candidates.mapIt(it.material.public) != want: ok = false
  # a permuted catalogue permutes the candidates the same way
  let rev = cat.reversed()
  for (a, b) in zip(offers, recipientOffers(reqs, rev, m)):
    if b.candidates.mapIt(it.material.public) != a.candidates.mapIt(it.material.public).reversed(): ok = false
  observations.add flag("classify_not_score", ok)

emitTrials(observations)
doAssert observations.allIt(it["classify_not_score"].getBool),
  "a candidate carried a number or a field beyond class, grade and rows, or the offers reordered the catalogue"
stderr.writeLine "probe_no_score: OK (200 trials; classified, never scored, in the catalogue's order)"
