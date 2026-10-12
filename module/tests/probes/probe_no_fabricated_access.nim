## s4 — access is never fabricated (contracts/specs/derived-exo-45e, oracle c4; property/trace).
##
## For random authority requirements against random recognized sets — a Safe's owner set as
## the chain reports it, an EIP-191 signer set, the room roster, a Bitcoin account's keys —
## this instance's key grades met exactly when the target set contains it, never when it
## does not, and grading never adds the key to the set (the Safe owner self-injection that
## exo-45e K3 removed). The SAME probe the module builds (probeFromFacts) grades the
## requirement, so a regression in the module's grading flips the flag.
## Emits {"traces": [[{access_only_when_recognized}, …]]}; self-asserts too.

import std/[sequtils, strutils]
import ../../src/drivers/manifest
import ../../src/drivers/driver
import ../../src/coordination/readiness
import ../../src/crypto/secp256k1
import ../../src/crypto/curve25519
import ./oracle_emit

var rngState: uint64 = 0x9E3779B97F4A7C15'u64
proc nextR(n: int): int =
  rngState = rngState * 6364136223846793005'u64 + 1442695040888963407'u64
  int((rngState shr 33) mod uint64(n))

proc addrOf(n: int): Address = (for i in 0 ..< 20: result[i] = byte(n))
proc edOf(n: int): Ed25519Pub = (for i in 0 ..< 32: result[i] = byte(n))
proc btcKeyOf(n: int): string = "02" & toHex(n, 2).toLowerAscii.repeat(32)

proc ownersOnChain(os: seq[Address]): proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] {.gcsafe.} =
  ## the chain's answer to getOwners: exactly these owners
  (proc(url: string, safe: Address): tuple[known: bool, owners: seq[Address], detail: string] = (true, os, "owners read"))

const Kinds = ["safe-owner", "signer", "roster-member", "btc-multisig-key"]
var observations: seq[JsonNode]
var met, missing = 0
for trial in 0 ..< 400:
  let kind = Kinds[nextR(Kinds.len)]
  # a random recognized set over a small alphabet, so "mine is in it" happens often
  var members: seq[int]
  for i in 0 ..< 1 + nextR(5):
    let n = 1 + nextR(8)
    if n notin members: members.add n
  let me = 1 + nextR(8)
  let recognized = me in members
  var f = HostFacts(rpcUrl: "http://rpc", expectedChainId: 31337, myAddress: addrOf(me),
                    myEd: edOf(me), myBtcKey: btcKeyOf(me), safe: addrOf(99))
  let owners = members.mapIt(addrOf(it))
  f.ownersProbe = ownersOnChain(owners)   # what the chain read returns
  f.signers = owners
  f.roster = members.mapIt(edOf(it))
  f.btcSigners = members.mapIt(btcKeyOf(it))
  let m = ActionManifest(declared: true, requirements: @[req(rqAuthority, kind, rpContributor)])
  let r = assessReadiness(m, probeFromFacts(f))
  let st = r.items[0].status
  if st == rdMet: inc met
  if st == rdMissing: inc missing
  # met iff recognized; when the set is known, an unrecognized key is missing (never met);
  # and grading added nothing to any set
  let ok = (st == rdMet) == recognized and (recognized or st == rdMissing) and
           f.signers == owners and f.roster == members.mapIt(edOf(it)) and
           f.btcSigners == members.mapIt(btcKeyOf(it))
  observations.add flag("access_only_when_recognized", ok)

emitTrials(observations)
doAssert observations.allIt(it["access_only_when_recognized"].getBool),
  "an authority graded met for a key its target does not recognize, or grading changed the set"
doAssert met > 0 and missing > 0, "the trials must grade both a recognized and an unrecognized key"
stderr.writeLine "probe_no_fabricated_access: OK (400 trials, ", met, " met, ", missing, " missing; never met unrecognized)"
