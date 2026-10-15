## Sealed blobs for the room swarm (exo-4d0.3, docs/design/room-swarm.md §5.2). A file is
## sealed under a fresh key before it reaches Logos Storage, and opened only if every chunk
## authenticates, the stream ends where the sealer ended it, and the plaintext matches the
## size and digest the sharer committed. Anything else is a refusal that leaves no file
## behind. Needs libsodium (see tests/README.md).

import std/[os, strutils]
import ../src/crypto/blob_seal
import ../src/crypto/sodium
import ../src/hashing/sha256

let dir = getTempDir() / ("muster-blob-seal-" & $getCurrentProcessId())
createDir(dir)

proc writeBytes(path: string, b: seq[byte]) =
  var s = newString(b.len)
  for i, x in b: s[i] = char(x)
  writeFile(path, s)

proc readBytes(path: string): seq[byte] =
  let s = readFile(path)
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(c)

proc refuses(body: proc ()): bool =
  try: body(); false
  except BlobSealError: true

# 1. Round trip across sizes: empty, under one chunk, exactly one chunk, many chunks with a
#    ragged tail. The opened bytes are the original bytes, and the record names the
#    plaintext's size and the domain-separated digest of it.
for n in [0, 1, 1000, SealChunkBytes, SealChunkBytes + 1, 3 * SealChunkBytes + 777]:
  let src = dir / ("plain-" & $n)
  let sealed = dir / ("sealed-" & $n)
  let opened = dir / ("opened-" & $n)
  let data = randomBytes(n)
  writeBytes(src, data)
  let rec = sealFile(src, sealed)
  doAssert rec.size == uint64(n)
  doAssert rec.digest == plaintextDigest(uint64(n), sha256(data))
  doAssert rec.scheme == SealScheme
  doAssert getFileSize(sealed) == int64(sealedSizeOf(uint64(n))), "sealed size is predictable from the plaintext size"
  openFile(sealed, opened, rec.key, rec.size, rec.digest)
  doAssert readBytes(opened) == data, "round trip at " & $n & " bytes"
echo "1. round trip: empty, small, one chunk, many chunks OK"

# 2. Two seals of the same file differ (a fresh key and header each time): the ciphertext,
#    and so its storage CID, never links two shares of one file.
block:
  let src = dir / "same"
  writeBytes(src, randomBytes(5000))
  let a = sealFile(src, dir / "same-a")
  let b = sealFile(src, dir / "same-b")
  doAssert a.key != b.key
  doAssert readBytes(dir / "same-a") != readBytes(dir / "same-b")
  doAssert a.digest == b.digest, "the plaintext digest is the file's, not the seal's"
echo "2. two seals of one file share nothing but the plaintext digest OK"

# 3. Refusals. Each leaves no file at the destination, and no partial beside it.
let base = dir / "base"
let baseData = randomBytes(2 * SealChunkBytes + 10)
writeBytes(base, baseData)
let baseSealed = dir / "base.sealed"
let rec = sealFile(base, baseSealed)
let good = readBytes(baseSealed)

proc refusedClean(name: string, bytes: seq[byte], key = rec.key, size = rec.size,
                  digest = rec.digest): bool =
  let s = dir / (name & ".sealed")
  let d = dir / (name & ".out")
  writeBytes(s, bytes)
  result = refuses(proc () = openFile(s, d, key, size, digest))
  doAssert not fileExists(d), name & ": no file is left at the destination"
  for f in walkDir(dir):
    doAssert not f.path.startsWith(d), name & ": no partial is left beside it: " & f.path

block:
  var flipped = good
  flipped[good.len div 2] = flipped[good.len div 2] xor 1
  doAssert refusedClean("tampered", flipped), "a flipped ciphertext bit refuses"

  doAssert refusedClean("truncated-chunk", good[0 ..< good.len - SealChunkBytes div 2]),
    "a stream cut inside a chunk refuses"
  let lastChunk = 10 + SealAbytes
  doAssert refusedClean("dropped-final", good[0 ..< good.len - lastChunk]),
    "a stream that stops cleanly before its final chunk refuses (truncation)"
  doAssert refusedClean("trailing", good & @[byte 0, 1, 2]),
    "bytes after the final chunk refuse"
  doAssert refusedClean("header-only", good[0 ..< SealHeaderBytes]), "a bare header refuses"
  doAssert refusedClean("empty", @[]), "an empty blob refuses"

  var otherKey = rec.key
  otherKey[0] = otherKey[0] xor 1
  doAssert refusedClean("wrong-key", good, key = otherKey), "the wrong key refuses"

  doAssert refusedClean("wrong-size", good, size = rec.size - 1),
    "a size other than the committed one refuses"
  var otherDigest = rec.digest
  otherDigest[31] = otherDigest[31] xor 1
  doAssert refusedClean("wrong-digest", good, digest = otherDigest),
    "a digest other than the committed one refuses"

  # A sealer that commits a digest of other bytes: every chunk authenticates under the key,
  # and the open still refuses, because the digest is the sharer's word about the plaintext.
  let liar = dir / "liar"
  writeBytes(liar, randomBytes(100))
  let liarSealed = dir / "liar.sealed"
  let lrec = sealFile(liar, liarSealed)
  doAssert refusedClean("lying-digest", readBytes(liarSealed), key = lrec.key, size = lrec.size,
                        digest = plaintextDigest(lrec.size, sha256(randomBytes(100)))),
    "an authentic stream whose plaintext is not the committed digest refuses"
echo "3. tamper, truncation, trailing bytes, wrong key, size or digest: all refuse, nothing left behind OK"

# 4. A refused open never replaces a file that was already at the destination.
block:
  let d = dir / "keep.out"
  writeFile(d, "mine")
  var flipped = good
  flipped[^1] = flipped[^1] xor 1
  let s = dir / "keep.sealed"
  writeBytes(s, flipped)
  doAssert refuses(proc () = openFile(s, d, rec.key, rec.size, rec.digest))
  doAssert readFile(d) == "mine", "a refused open leaves an existing destination untouched"
echo "4. a refusal never overwrites what was there OK"

# 5. The digest is domain-separated: it is not the bare sha256 of the bytes, and size is in it.
block:
  let sha = sha256(baseData)
  doAssert plaintextDigest(rec.size, sha) != sha
  doAssert plaintextDigest(rec.size, sha) != plaintextDigest(rec.size + 1, sha)
echo "5. the plaintext digest is a domain-separated record over size and sha256 OK"

# 6. The upload name says nothing: random, the same shape every time, no trace of the file.
block:
  let a = neutralName()
  let b = neutralName()
  doAssert a != b
  doAssert a.endsWith(".bin") and a.len == b.len
  for c in a[0 ..< a.len - 4]: doAssert c in HexDigits
echo "6. neutral upload names OK"

removeDir(dir)
echo "blob_seal_test: all OK"
