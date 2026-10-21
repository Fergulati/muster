## libsodium binding — the authenticated symmetric cipher under the epoch layer's
## ECIES (F-16). We bind `crypto_secretbox` (XSalsa20-Poly1305 AEAD) rather than
## hand-roll a cipher: on the signing/encryption path we lean on a vetted library,
## the same way we consume secp256k1. Symbols resolve at link (the module build
## adds libsodium via nix.packages); ABI-stable, so no header is needed.

type SodiumError* = object of CatchableError

{.push importc, cdecl.}
proc sodium_init(): cint
proc crypto_secretbox_easy(c, m: ptr byte, mlen: culonglong, n, k: ptr byte): cint
proc crypto_secretbox_open_easy(m, c: ptr byte, clen: culonglong, n, k: ptr byte): cint
proc crypto_pwhash(o: ptr byte, olen: culonglong, passwd: ptr char, passwdlen: culonglong,
                   salt: ptr byte, opslimit: culonglong, memlimit: csize_t, alg: cint): cint
proc randombytes_buf(buf: pointer, size: csize_t)
# Streaming AEAD (XChaCha20-Poly1305 secretstream) and streaming SHA-256, for files too
# large to hold in memory (the room swarm's sealed blobs, exo-4d0.3). The state structs
# are opaque here: we allocate them by the size libsodium reports.
proc crypto_secretstream_xchacha20poly1305_statebytes(): csize_t
proc crypto_secretstream_xchacha20poly1305_init_push(st: pointer, header, k: ptr byte): cint
proc crypto_secretstream_xchacha20poly1305_push(st: pointer, c: ptr byte, clen: ptr culonglong,
    m: ptr byte, mlen: culonglong, ad: ptr byte, adlen: culonglong, tag: uint8): cint
proc crypto_secretstream_xchacha20poly1305_init_pull(st: pointer, header, k: ptr byte): cint
proc crypto_secretstream_xchacha20poly1305_pull(st: pointer, m: ptr byte, mlen: ptr culonglong,
    tag: ptr uint8, c: ptr byte, clen: culonglong, ad: ptr byte, adlen: culonglong): cint
proc crypto_hash_sha256_statebytes(): csize_t
proc crypto_hash_sha256_init(st: pointer): cint
proc crypto_hash_sha256_update(st: pointer, m: ptr byte, mlen: culonglong): cint
proc crypto_hash_sha256_final(st: pointer, o: ptr byte): cint
{.pop.}

const
  KeyBytes* = 32
  NonceBytes = 24
  MacBytes = 16
  # Argon2id parameters — the "interactive" profile from libsodium (crypto_pwhash_*
  # _INTERACTIVE), the vetted default for a passphrase that gates a local keyfile.
  PwSaltBytes* = 16
  PwOpsInteractive = 2'u64
  PwMemInteractive = 67108864   # 64 MiB
  PwAlgArgon2id13 = 2

# One-time init (thread-safe, idempotent in libsodium). Runs at module load.
discard sodium_init()

proc randomBytes*(n: int): seq[byte] =
  result = newSeq[byte](n)
  if n > 0: randombytes_buf(addr result[0], csize_t(n))

proc randomKey*(): array[32, byte] =
  randombytes_buf(addr result[0], csize_t(32))

proc pwhashKey*(passphrase: string, salt: array[PwSaltBytes, byte]): array[32, byte] =
  ## Derive a 32-byte symmetric key from a passphrase with Argon2id (memory-hard).
  ## The same passphrase + salt always yields the same key, so it unwraps a keyfile
  ## sealed under it; a wrong passphrase yields a different key and the AEAD open
  ## fails. This is what makes the file-backed keystore stopgap defensible at rest.
  var s = salt
  var p = passphrase
  let pp = if p.len > 0: addr p[0] else: nil
  if crypto_pwhash(addr result[0], culonglong(32), pp, culonglong(p.len),
                   addr s[0], PwOpsInteractive, csize_t(PwMemInteractive),
                   PwAlgArgon2id13) != 0:
    raise newException(SodiumError, "pwhash failed (out of memory?)")

proc secretboxSeal*(key: array[32, byte], plaintext: openArray[byte]): seq[byte] =
  ## AEAD encrypt. Output is nonce(24) ++ (MAC(16) ++ ciphertext) — self-contained,
  ## a fresh random nonce every call.
  var nonce: array[NonceBytes, byte]
  randombytes_buf(addr nonce[0], csize_t(NonceBytes))
  var m = @plaintext
  var k = key
  var ct = newSeq[byte](m.len + MacBytes)
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_secretbox_easy(addr ct[0], mp, culonglong(m.len), addr nonce[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretbox seal failed")
  result = @nonce & ct

proc secretboxOpen*(key: array[32, byte], sealed: openArray[byte]): seq[byte] =
  ## AEAD decrypt + verify. Raises if the key is wrong or the bytes were tampered
  ## (Poly1305 authentication) — the caller treats a raise as "not for me".
  if sealed.len < NonceBytes + MacBytes:
    raise newException(SodiumError, "sealed payload too short")
  var nonce: array[NonceBytes, byte]
  for i in 0 ..< NonceBytes: nonce[i] = sealed[i]
  let ctLen = sealed.len - NonceBytes
  var ct = newSeq[byte](ctLen)
  for i in 0 ..< ctLen: ct[i] = sealed[NonceBytes + i]
  var k = key
  var m = newSeq[byte](ctLen - MacBytes)
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_secretbox_open_easy(mp, addr ct[0], culonglong(ctLen), addr nonce[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretbox open failed (wrong key or tampered)")
  m

# ── Streaming AEAD: crypto_secretstream_xchacha20poly1305 ────────────────────────────
const
  StreamHeaderBytes* = 24
  StreamAbytes* = 17         ## per message: a 1-byte tag + a 16-byte MAC
  StreamTagMessage* = 0'u8
  StreamTagFinal* = 3'u8

type
  StreamPush* = object
    st: seq[byte]
  StreamPull* = object
    st: seq[byte]

proc initStreamPush*(key: array[32, byte]): (StreamPush, array[StreamHeaderBytes, byte]) =
  ## Start sealing a stream; the header (24 random bytes) goes first in the output.
  var p = StreamPush(st: newSeq[byte](int crypto_secretstream_xchacha20poly1305_statebytes()))
  var h: array[StreamHeaderBytes, byte]
  var k = key
  if crypto_secretstream_xchacha20poly1305_init_push(addr p.st[0], addr h[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretstream init_push failed")
  (p, h)

proc push*(p: var StreamPush, m: openArray[byte], tag: uint8): seq[byte] =
  ## Seal one message of the stream: m.len + StreamAbytes bytes out.
  result = newSeq[byte](m.len + StreamAbytes)
  let mp = if m.len > 0: unsafeAddr m[0] else: nil
  if crypto_secretstream_xchacha20poly1305_push(addr p.st[0], addr result[0], nil, mp,
      culonglong(m.len), nil, 0, tag) != 0:
    raise newException(SodiumError, "secretstream push failed")

proc initStreamPull*(key: array[32, byte], header: openArray[byte]): StreamPull =
  ## Start opening a stream from its header. Raises on a malformed header.
  if header.len != StreamHeaderBytes:
    raise newException(SodiumError, "secretstream header must be 24 bytes")
  result = StreamPull(st: newSeq[byte](int crypto_secretstream_xchacha20poly1305_statebytes()))
  var h = @header
  var k = key
  if crypto_secretstream_xchacha20poly1305_init_pull(addr result.st[0], addr h[0], addr k[0]) != 0:
    raise newException(SodiumError, "secretstream init_pull failed")

proc pull*(p: var StreamPull, c: openArray[byte]): (seq[byte], uint8) =
  ## Open one message: its plaintext and its tag. Raises if it does not authenticate
  ## (wrong key, tampered, out of order) — the caller treats that as a refusal.
  if c.len < StreamAbytes:
    raise newException(SodiumError, "secretstream message too short")
  var m = newSeq[byte](c.len - StreamAbytes)
  var tag: uint8
  let mp = if m.len > 0: addr m[0] else: nil
  if crypto_secretstream_xchacha20poly1305_pull(addr p.st[0], mp, nil, addr tag,
      unsafeAddr c[0], culonglong(c.len), nil, 0) != 0:
    raise newException(SodiumError, "secretstream pull failed (wrong key or tampered)")
  (m, tag)

# ── Streaming SHA-256 (libsodium's), for a file's plaintext digest ──────────────────
type Sha256Stream* = object
  st: seq[byte]

proc initSha256Stream*(): Sha256Stream =
  result = Sha256Stream(st: newSeq[byte](int crypto_hash_sha256_statebytes()))
  if crypto_hash_sha256_init(addr result.st[0]) != 0:
    raise newException(SodiumError, "sha256 init failed")

proc update*(h: var Sha256Stream, m: openArray[byte]) =
  if m.len == 0: return
  if crypto_hash_sha256_update(addr h.st[0], unsafeAddr m[0], culonglong(m.len)) != 0:
    raise newException(SodiumError, "sha256 update failed")

proc finish*(h: var Sha256Stream): array[32, byte] =
  if crypto_hash_sha256_final(addr h.st[0], addr result[0]) != 0:
    raise newException(SodiumError, "sha256 final failed")
