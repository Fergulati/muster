## s5 — unknown is preserved (contracts/specs/derived-exo-45e, oracle c5; property/trace).
##
## A requirement whose satisfiability cannot be determined grades exactly unknown: never met,
## never missing. Three ways a host cannot answer, each over random requirement lists:
##   1. no probe at all (every closure nil): every kind;
##   2. a probe that raises (an RPC that throws, a broker that errors): every kind;
##   3. the module's own probe (probeFromFacts) with the fact it would need absent: no RPC
##      to read a Safe's owners or a chain through, an owner read that fails, no Bitcoin
##      node, no Monero wallet reader, no Bitcoin account keys, no LEZ zone probe, a chain
##      it has no probe for, party-supplied material (address, asset), and a capability
##      (the host broker does not exist yet).
## Each trial's readiness is also never `ready` while an item is unknown.
## Emits {"traces": [[{unknown_never_collapses}, …]]}; self-asserts too.

import std/sequtils
import ../../src/drivers/manifest
import ../../src/drivers/driver
import ../../src/coordination/readiness
import ../../src/crypto/secp256k1
import ./oracle_emit

var rngState: uint64 = 0xD1B54A32D192ED03'u64
proc nextR(n: int): int =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  int((rngState shr 33) mod uint64(n))

let anyReq = @[
  req(rqEnvironment, "eip155:31337"), req(rqEnvironment, "bip122:000000000019d6689c085ae165831e93"),
  req(rqEnvironment, "monero:418015bb9ae982a1975da7d79277c270"), req(rqAuthority, "safe-owner", rpContributor),
  req(rqAuthority, "signer", rpContributor), req(rqAuthority, "roster-member", rpContributor),
  req(rqInfra, "rpc"), req(rqInfra, "lez-account"), req(rqCapability, "evm.sign"),
  req(rqModule, "eth_rpc_module"), req(rqAddress, "payee", rpContributor), req(rqAsset, "amount", rpContributor)]

# what probeFromFacts cannot answer with these facts (none of them configured or readable)
let unanswerable = @[
  req(rqEnvironment, "eip155:31337"),                         # no RPC to probe the chain through
  req(rqEnvironment, "bip122:000000000019d6689c085ae165831e93"),  # no Bitcoin node to ask
  req(rqEnvironment, "monero:418015bb9ae982a1975da7d79277c270"),  # no Monero wallet reader
  req(rqEnvironment, "solana:5eykt4UsFv8P8NJdTREpY1vzqKqZKvdp"), # a chain it has no probe for
  req(rqAuthority, "safe-owner", rpContributor),              # no RPC to read the owner set
  req(rqAuthority, "btc-multisig-key", rpContributor),        # no account keys to grade against
  req(rqInfra, "lez-account"), req(rqInfra, "lez-member-funded"), req(rqInfra, "something-new"),
  req(rqCapability, "evm.sign"),                              # no host broker yet
  req(rqAddress, "payee", rpContributor), req(rqAsset, "amount", rpContributor)]

proc pick(pool: seq[Requirement]): seq[Requirement] =
  for i in 0 ..< 1 + nextR(5): result.add pool[nextR(pool.len)]

proc allUnknown(r: Readiness): bool =
  r.items.len > 0 and r.items.allIt(it.status == rdUnknown) and not r.ready and r.unknown == r.items.len

var observations: seq[JsonNode]
let raising = ReadinessProbe(
  moduleLoaded: proc(n: string): ModuleGrade = raise newException(IOError, "host down"),
  environmentReachable: proc(n: string): Grade = raise newException(IOError, "rpc threw"),
  authorityHeld: proc(n: string): Grade = raise newException(IOError, "rpc threw"),
  infraConfigured: proc(n: string): Grade = raise newException(IOError, "config unreadable"),
  capabilityGranted: proc(n: string): Grade = raise newException(IOError, "broker error"))
for trial in 0 ..< 300:
  let reqs = pick(anyReq)
  let m = ActionManifest(declared: true, requirements: reqs)
  observations.add flag("unknown_never_collapses", assessReadiness(m, ReadinessProbe()).allUnknown)
  observations.add flag("unknown_never_collapses", assessReadiness(m, raising).allUnknown)
  # the module's probe, with nothing configured but an owner read that would fail
  var f = HostFacts(rpcUrl: "", expectedChainId: 31337, myAddress: default(Address))
  let m3 = ActionManifest(declared: true, requirements: pick(unanswerable))
  observations.add flag("unknown_never_collapses", assessReadiness(m3, probeFromFacts(f)).allUnknown)
  # an RPC is set, but the owner read itself fails: still unknown, never a guess
  f.rpcUrl = "http://rpc"
  f.ownersProbe = proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] =
    (false, @[], "getOwners failed")
  let m4 = ActionManifest(declared: true, requirements: @[req(rqAuthority, "safe-owner", rpContributor)])
  observations.add flag("unknown_never_collapses", assessReadiness(m4, probeFromFacts(f)).allUnknown)

emitTrials(observations)
doAssert observations.allIt(it["unknown_never_collapses"].getBool),
  "a requirement the host cannot answer graded met or missing, or readiness read ready"
stderr.writeLine "probe_unknown_preserved: OK (", observations.len, " readiness reads; every unanswerable requirement stayed unknown)"
