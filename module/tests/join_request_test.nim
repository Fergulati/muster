## exo-a87 — a join request discloses the encryption identity and nothing else.
##
## Spec derived-exo-45e s2: "entering a room discloses the encryption identity and nothing
## else". Until 2026-10-11 a join request carried a LinkStatement signed by the member's one
## secp key, so every room they asked to join recovered their address (and the public key
## their Bitcoin key shares). Now the request is the identity, the room, an expiry and the
## identity's own Ed25519 signature. This test holds:
##   1. a request round-trips and verifies for its room;
##   2. it is refused for another room, past its expiry, for another identity, or with a
##      signature by another key (nobody asks in another's name);
##   3. its bytes carry none of the asker's secp key: not the address, not the compressed or
##      uncompressed public key, and no room for a 65-byte recoverable signature;
##   4. an old secp-signed binding does not decode as a request.
## Needs libsodium + $SECP (run-suite.sh supplies them).

import ../src/crypto/keystore
import ../src/crypto/binding
import ../src/crypto/join_request
import ../src/crypto/curve25519

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)

proc contains(hay, needle: openArray[byte]): bool =
  if needle.len == 0 or needle.len > hay.len: return false
  for i in 0 .. hay.len - needle.len:
    var ok = true
    for j in 0 ..< needle.len:
      if hay[i + j] != needle[j]: ok = false; break
    if ok: return true

const room = "/muster/1/join-request/proto"
let bob = newInMemoryKeystore(seed(0x12), seed(0x22))
let mal = newInMemoryKeystore(seed(0x13), seed(0x23))
let req = bob.joinRequestFor(room, 1_000)

# ── 1. round trip, and it verifies for its room ─────────────────────────────────
block:
  let wire = encodeJoinRequest(req)
  doAssert decodeJoinRequest(wire) == req, "a request round-trips"
  doAssert req.enc == bob.encIdentity(), "it names the asker's encryption identity"
  doAssert joinRequestValid(req, room, 999) and joinRequestValid(req, room, 1_000),
    "valid for its room up to its expiry"
  echo "1. a request round-trips and verifies for its room OK"

# ── 2. refused for anything else ────────────────────────────────────────────────
block:
  doAssert not joinRequestValid(req, "/muster/1/other/proto", 0), "refused for another room"
  doAssert not joinRequestValid(req, room, 1_001), "refused past its expiry"
  var renamed = req
  renamed.enc = mal.encIdentity()
  doAssert not joinRequestValid(renamed, room, 0), "refused when it names another identity"
  var forged = mal.joinRequestFor(room, 1_000)
  forged.enc = bob.encIdentity()
  doAssert not joinRequestValid(forged, room, 0), "refused when another key signed it: nobody asks in Bob's name"
  var later = req
  later.expiry = 5_000
  doAssert not joinRequestValid(later, room, 0), "refused when its expiry was changed after signing"
  echo "2. refused for another room, expiry, identity or signer OK"

# ── 3. no secp key in it ─────────────────────────────────────────────────────────
block:
  let wire = encodeJoinRequest(req)
  doAssert not wire.contains(@(bob.address())), "the request carries Bob's secp address"
  let pub33 = bob.btcPubKey()
  doAssert pub33.len == 33 and not wire.contains(pub33), "the request carries Bob's secp public key"
  doAssert not wire.contains(pub33[1 .. ^1]), "the request carries the x coordinate of Bob's secp key"
  doAssert wire.len == 64 + 2 + room.len + 8 + 64,
    "the request is exactly identity ++ room ++ expiry ++ one Ed25519 signature: no room for a secp signature"
  echo "3. no secp address, public key or signature in a request OK"

# ── 4. an old secp-signed binding is not a request ──────────────────────────────
block:
  let old = encodeLink(bob.bindingFor(LinkContext(account: room, slot: "0", expiry: 1_000)))
  var refused = false
  try: discard decodeJoinRequest(old)
  except JoinRequestError: refused = true
  doAssert refused, "an old binding must not decode as a join request"
  echo "4. an old secp-signed binding does not decode as a request OK"

echo "join_request_test: all OK"
