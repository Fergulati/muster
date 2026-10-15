## derived-exo-4d0.4 s5: a file's name is the sharer's word and carries no path. Whatever
## name a share gives — separators, '..', control characters, empty — the name shown and
## the file a fetch writes stay inside the folder the member chose, and a fetch never
## overwrites a file already there.
##
## STEPPER: one state per case, chained case -> case+1. Each case runs the REAL path: Alice
## seals a file, uploads it to her storage node (LocalBlobStore), and posts a genuine
## share under a hostile name plus her seed; Bob's SwarmNode fetches it into a chosen
## folder. Cases are twelve names —
##   ../../escape.txt · <absolute path outside the folder> · a/../../b.txt ·
##   C:\Windows\x.txt · .. · . · (empty) · x<NUL>y.txt · a name with a newline · dir/ ·
##   ~/.bashrc · notes.txt (the control)
## — times four states of the folder: empty; a file under the name the room shows; that
## and its "(1)" sibling; a dangling symlink under the name the room shows, pointing
## outside the folder. The whole test root is snapshotted (lstat: kind, size, bytes, link
## target) before and after. Correct iff:
##   * the shown name holds no '/', no '\', no control character, and is not "", "." or "..";
##   * the fetch finished, and the only differences in the tree are ONE new entry directly
##     inside the chosen folder — a regular file holding exactly the plaintext — and the
##     blob in Bob's own storage repo;
##   * every entry that was there before is unchanged, and nothing appears outside the
##     folder (the symlink's target included).
## Run by hand (no argv), it checks every case with doAssert.

import std/[os, tables, strutils, sequtils]
import ./swarm_room
import ./oracle_emit
import ../../src/transport/transport
import ../../src/crypto/epoch_crypto
import ../../src/crypto/sodium
import ../../src/storage/blob_store
import ../../src/coordination/session
import ../../src/coordination/swarm_live

let root0 = getTempDir() / ("muster-probe-swarm-name-" & $getCurrentProcessId())

proc names(root: string): seq[string] =
  @["../../escape.txt", root / "outside" / "abs.txt", "a/../../b.txt", "C:\\Windows\\x.txt",
    "..", ".", "", "x\0y.txt", "line\nbreak.txt", "dir/", "~/.bashrc", "notes.txt"]
const FolderStates = 4
const caseCount = 12 * FolderStates

type Entry = tuple[kind: string, size: int64, body: string, target: string]

proc snapshot(root: string): Table[string, Entry] =
  for p in walkDirRec(root, yieldFilter = {pcFile, pcLinkToFile, pcDir, pcLinkToDir},
                      followFilter = {pcDir}, relative = true):
    let full = root / p
    if symlinkExists(full):
      result[p] = ("link", 0'i64, "", expandSymlink(full))
    elif dirExists(full):
      result[p] = ("dir", 0'i64, "", "")
    else:
      result[p] = ("file", getFileSize(full), readFile(full), "")

proc shownOk(n: string): bool =
  if n.len == 0 or n == "." or n == "..": return false
  for ch in n:
    if ch in {'/', '\\'} or ord(ch) < 0x20 or ord(ch) == 0x7f: return false
  true

proc correct(c: int): bool =
  let root = root0 / $c
  removeDir(root)
  for d in ["outside", "home/bob/Downloads", "stores", "work"]: createDir(root / d)
  let name = names(root)[c div FolderStates]
  let folderState = c mod FolderStates
  let dest = root / "home/bob/Downloads"

  let net = newLocalNetwork()
  let founder = newEpochCrypto(aliceKs, Room, @[bobKs.encIdentity()])
  let bobC = newEpochJoiner(bobKs)
  bobC.ingestGrant(founder.grantFor(0, bobKs.encIdentity()))
  let aliceS = newCoordinationSession(newLocalTransport(net), founder, Room)
  let bobS = newCoordinationSession(newLocalTransport(net), bobC, Room)
  let storage = newLocalStorageNet(Net)
  var clock = 100'i64
  let tick = proc(): int64 = (inc clock; clock)
  let aliceStore = newLocalBlobStore(storage, root / "stores/alice")
  let bobNode = newSwarmNode(newLocalBlobStore(storage, root / "stores/bob"), bobKs, root / "work/bob", tick)

  # Alice's file, sealed and uploaded by hand so the share can carry any name
  let plain = randomBytes(5000)
  var plainStr = newString(plain.len)
  for i, x in plain: plainStr[i] = char(x)
  writeFile(root / "work/plain", plainStr)
  let sealed = sealFile(root / "work/plain", root / "work/sealed.bin")
  let job = aliceStore.upload(root / "work/sealed.bin")
  aliceStore.poll()
  let cid = aliceStore.job(job).cid
  removeFile(root / "work/plain")
  removeFile(root / "work/sealed.bin")
  let (fid, e) = shareEvent(alice, name, "application/octet-stream", cid, Net, sealed, 100)
  aliceS.publishAuthored(aliceKs, e)
  let r = aliceStore.reach()
  aliceS.publishAuthored(aliceKs, seedEvent(fid, alice, true, r.peerId, r.addrs, r.network, 101))

  let (found, f) = fileById(reduceSwarm(bobS.roomEvents()), fid)
  if not found or not shownOk(f.name): return false

  case folderState
  of 1: writeFile(dest / f.name, "mine")
  of 2:
    writeFile(dest / f.name, "mine")
    let (_, stem, ext) = splitFile(f.name)
    writeFile(dest / (stem & " (1)" & ext), "mine too")
  of 3: createSymlink(root / "outside/target.txt", dest / f.name)
  else: discard

  let before = snapshot(root)
  let op = bobNode.fetch(bobS, fid, dest, private = false)
  for _ in 0 .. 3: bobNode.pump(bobS)
  var done = false
  for o in bobNode.ops():
    if o.id == op: done = o.state == opDone
  let after = snapshot(root)
  if not done: return false

  for p, ent in before:
    if p notin after or after[p] != ent: return false
  var added: seq[string]
  for p, ent in after:
    if p in before: continue
    if p.startsWith("stores/bob"): continue            # Bob's own storage repo: the blob
    if p == "work" or p.startsWith("work/"): continue   # nothing should remain; checked below
    added.add p
  if toSeq(walkDir(root / "work/bob")).len != 0: return false
  if added.len != 1: return false
  let p = added[0]
  if parentDir(root / p) != dest: return false
  if after[p].kind != "file" or after[p].body != plainStr: return false
  true

proc state(c: int): JsonNode =
  let ok = correct(c)
  removeDir(root0 / $c)
  %*{"case": c, "decision_correct": ok}

let arg = oracleStateArg()
if arg == nil:
  for c in 0 ..< caseCount:
    doAssert correct(c), "case " & $c & ": name " & names(root0 / $c)[c div FolderStates].escape &
                         ", folder state " & $(c mod FolderStates)
  removeDir(root0)
let here = oracleStateInt(arg, "case", 0)
emitSuccessors(@[state((here + 1) mod caseCount)])
