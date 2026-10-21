## A shared fixture for the room swarm's spec probes (derived-exo-4d0.4): four members —
## Alice, Bob, Carol and Mallory — each with a keystore, one room and another, and
## builders for genuine and tampered `file/` events. Every probe reads the room the way the
## hosted module does: `authenticEvents` (authorship.nim) then `reduceSwarm` (swarm.nim).
## Not a probe itself.

import std/json
import ../../src/log/log
import ../../src/crypto/keystore
import ../../src/crypto/curve25519
import ../../src/crypto/blob_seal
import ../../src/coordination/authorship
import ../../src/coordination/swarm
export log, keystore, curve25519, blob_seal, authorship, swarm

proc seedOf(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hx*(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

let aliceKs* = newInMemoryKeystore(seedOf(0x71), seedOf(0x81))
let bobKs* = newInMemoryKeystore(seedOf(0x72), seedOf(0x82))
let carolKs* = newInMemoryKeystore(seedOf(0x73), seedOf(0x83))
let malloryKs* = newInMemoryKeystore(seedOf(0x74), seedOf(0x84))
proc idOf*(ks: Keystore): string = hx(ks.encIdentity().toBytes())
let alice* = idOf(aliceKs)
let bob* = idOf(bobKs)
let carol* = idOf(carolKs)
let mallory* = idOf(malloryKs)

const Room* = "/muster/1/room-swarm-probe/proto"
const OtherRoom* = "/muster/1/another-room/proto"
const Net* = "logos.dev"

proc blob*(n: byte): SealedBlob =
  ## A sealed blob's record, distinct per n. The fold never opens blobs.
  result = SealedBlob(scheme: SealScheme, size: 1000'u64 + n)
  for i in 0 ..< 32: (result.key[i] = byte(i) xor n; result.digest[i] = byte(255 - i) xor n)

proc cidOf*(n: byte): string = "zDvZProbeCiphertext" & $n

proc signedBy*(ks: Keystore, e: Event, room = Room): Event =
  ## `e` with an author signature made by `ks`, for `room`, whoever `e` names. When `ks` is
  ## the named author and `room` is Room, this is the genuine event; otherwise a forgery
  ## whose signature is well-formed but not the named author's, or not for this room.
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  let unsigned = Event(parents: e.parents, key: e.key, value: $j)
  j[AuthorSigField] = %hx(ks.edSign(authorDigest(room, unsigned)))
  Event(parents: e.parents, key: e.key, value: $j)

proc share*(sharer: Keystore, n: byte, at: int64, name = "file.bin"): (string, Event) =
  ## A genuine share of blob n by `sharer`, and its file id.
  let (fid, e) = shareEvent(idOf(sharer), name, "application/octet-stream", cidOf(n), Net, blob(n), at)
  (fid, signAuthored(sharer, Room, e))

proc seed*(who: Keystore, fid: string, on: bool, at: int64): Event =
  signAuthored(who, Room, seedEvent(fid, idOf(who), on, "16Uiu" & idOf(who)[0 ..< 8],
                                    @["/ip4/10.0.0.1/tcp/8500"], Net, at))

proc retract*(who: Keystore, fid: string, at: int64): Event =
  signAuthored(who, Room, retractEvent(fid, idOf(who), at))

proc index*(events: seq[Event], room = Room): seq[SwarmFile] =
  ## The room's file index as the hosted module reads it.
  reduceSwarm(authenticEvents(events, room))

proc edited*(e: Event, field: string, value: JsonNode): Event =
  ## `e` with one body field changed AFTER it was signed.
  var j = parseJson(e.value)
  j[field] = value
  Event(parents: e.parents, key: e.key, value: $j)

proc stripped*(e: Event): Event =
  ## `e` with its author signature removed.
  var j = parseJson(e.value)
  if j.hasKey(AuthorSigField): j.delete(AuthorSigField)
  Event(parents: e.parents, key: e.key, value: $j)

proc withSigOf*(e, donor: Event): Event =
  ## `e` carrying the signature lifted from another genuine event.
  var j = parseJson(e.value)
  j[AuthorSigField] = parseJson(donor.value)[AuthorSigField]
  Event(parents: e.parents, key: e.key, value: $j)

proc rekeyed*(e: Event, key: string): Event =
  ## `e` under another log key, its body and signature untouched.
  Event(parents: e.parents, key: key, value: e.value)

proc fileById*(idx: seq[SwarmFile], fid: string): (bool, SwarmFile) =
  for f in idx:
    if f.fid == fid: return (true, f)

proc seederIds*(f: SwarmFile): seq[string] =
  for s in f.seeders: result.add s.member
