## Sealed blobs — what the room swarm hands to Logos Storage (exo-4d0.3,
## docs/design/room-swarm.md §5.2).
##
## Storage moves opaque bytes: anyone who learns a CID and reaches a node serving it can
## fetch them, and the node announces what it serves to a public DHT. So a file is sealed
## before it is uploaded, under a fresh key that travels only inside the room (sealed to
## the epoch it was shared in, invariant 7). The sealed form is libsodium's secretstream
## (XChaCha20-Poly1305), cut into SealChunkBytes messages, so a large file is sealed and
## opened without being held in memory:
##
##   header (24) ‖ message₀ ‖ … ‖ messageₙ        each message = chunk + 17 bytes,
##                                               the last one tagged FINAL
##
## Nothing in it names Muster, the file, or its type: no magic bytes, no version field
## (the share event names the scheme), and the upload goes out under a neutral name
## because Storage's manifest carries the filename and mimetype in the clear.
##
## Opening refuses — raising BlobSealError and leaving nothing at the destination, not even
## a partial — unless every message authenticates, the stream ends exactly at its FINAL
## message, and the plaintext has the size and digest the sharer committed. The digest is
## a domain-separated hash-input record over (size, sha256) (invariant 5), so it is the
## sharer's word about the plaintext, checked here whatever Storage said about its own
## Merkle tree. An authentic stream of other bytes than the ones committed is refused.

import std/[os, strutils]
import ./sodium
import ../dcbor/dcbor
import ../hashing/hash_input

export hash_input.Sha256Digest

const
  SealScheme* = "xchacha20poly1305-secretstream-64k.v1"
  PlaintextDomain* = "muster.blob.plaintext.v1"
  SealChunkBytes* = 65536
  SealHeaderBytes* = StreamHeaderBytes
  SealAbytes* = StreamAbytes

type
  BlobSealError* = object of CatchableError
  SealedBlob* = object
    scheme*: string
    key*: array[32, byte]      ## the file key: goes into the room, never into Storage
    size*: uint64              ## plaintext bytes
    digest*: Sha256Digest      ## plaintextDigest(size, sha256(plaintext))

proc plaintextDigest*(size: uint64, sha: array[32, byte]): Sha256Digest =
  digest(hashInput(PlaintextDomain, @[("sha256", cbBytes(@sha)), ("size", cbUint(size))]))

proc chunkCount(size: uint64): uint64 =
  max(1'u64, (size + SealChunkBytes - 1) div SealChunkBytes)

proc sealedSizeOf*(size: uint64): uint64 =
  ## The sealed size is the plaintext size plus a constant per chunk: Storage, and anyone
  ## it serves, learns the plaintext's size to within 17 bytes per 64 KiB (§5.5).
  SealHeaderBytes.uint64 + size + SealAbytes.uint64 * chunkCount(size)

proc neutralName*(): string =
  ## The name a sealed blob is uploaded under: 32 random hex digits and ".bin".
  toHex(randomBytes(16)).toLowerAscii & ".bin"

proc readUpTo(f: File, n: int): seq[byte] =
  result = newSeq[byte](n)
  let got = if n > 0: f.readBuffer(addr result[0], n) else: 0
  result.setLen(got)

proc writeAll(f: File, b: openArray[byte]) =
  if b.len > 0 and f.writeBuffer(unsafeAddr b[0], b.len) != b.len:
    raise newException(IOError, "short write")

proc sealFile*(src, dst: string, key = randomKey()): SealedBlob =
  ## Seal the file at `src` into `dst` under `key` (fresh by default). Returns what the
  ## share event carries. Raises BlobSealError if the file cannot be read whole or changes
  ## size while it is sealed.
  try:
    let size = uint64(getFileSize(src))
    let count = chunkCount(size)
    var (push, header) = initStreamPush(key)
    var sha = initSha256Stream()
    var inp = open(src, fmRead)
    defer: inp.close()
    var outp = open(dst, fmWrite)
    defer: outp.close()
    outp.writeAll(header)
    var total = 0'u64
    for i in 0'u64 ..< count:
      let chunk = inp.readUpTo(SealChunkBytes)
      total += uint64(chunk.len)
      sha.update(chunk)
      let tag = if i == count - 1: StreamTagFinal else: StreamTagMessage
      outp.writeAll(push.push(chunk, tag))
    if total != size or inp.readUpTo(1).len != 0:
      raise newException(BlobSealError, "the file changed size while it was sealed: " & src)
    SealedBlob(scheme: SealScheme, key: key, size: size,
               digest: plaintextDigest(size, sha.finish()))
  except BlobSealError as e:
    raise e
  except CatchableError as e:
    raise newException(BlobSealError, "cannot seal " & src & ": " & e.msg)

proc openFile*(src, dst: string, key: array[32, byte], size: uint64, digest: Sha256Digest) =
  ## Open the sealed blob at `src` into `dst`, or refuse. The plaintext is written beside
  ## `dst` and moved into place only once every check has passed; on a refusal it is
  ## removed, and a file already at `dst` is left as it was.
  let partial = dst & ".partial-" & toHex(randomBytes(8)).toLowerAscii
  var moved = false
  try:
    var inp = open(src, fmRead)
    defer: inp.close()
    block write:
      var outp = open(partial, fmWrite)
      defer: outp.close()
      let header = inp.readUpTo(SealHeaderBytes)
      if header.len != SealHeaderBytes:
        raise newException(BlobSealError, "not a sealed blob: shorter than its header")
      var pull = initStreamPull(key, header)
      var sha = initSha256Stream()
      var total = 0'u64
      var final = false
      while not final:
        let msg = inp.readUpTo(SealChunkBytes + SealAbytes)
        if msg.len == 0:
          raise newException(BlobSealError, "the blob ends before its final chunk (truncated)")
        let (plain, tag) = pull.pull(msg)
        if tag == StreamTagFinal: final = true
        elif tag != StreamTagMessage:
          raise newException(BlobSealError, "unexpected stream tag " & $tag)
        elif msg.len != SealChunkBytes + SealAbytes:
          raise newException(BlobSealError, "a short chunk that is not the last")
        total += uint64(plain.len)
        if total > size:
          raise newException(BlobSealError, "the blob holds more than the committed " & $size & " bytes")
        sha.update(plain)
        outp.writeAll(plain)
      if inp.readUpTo(1).len != 0:
        raise newException(BlobSealError, "bytes after the final chunk")
      if total != size:
        raise newException(BlobSealError, "the blob holds " & $total & " bytes, not the committed " & $size)
      if plaintextDigest(total, sha.finish()) != digest:
        raise newException(BlobSealError, "the plaintext is not the one the sharer committed (digest mismatch)")
    moveFile(partial, dst)
    moved = true
  except BlobSealError as e:
    raise e
  except CatchableError as e:
    raise newException(BlobSealError, "cannot open " & src & ": " & e.msg)
  finally:
    if not moved and fileExists(partial): removeFile(partial)
