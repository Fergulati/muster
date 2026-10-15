## The storage seam (F-17; exo-4d0.2, docs/design/room-swarm.md §5.1).
##
## Muster codes against BlobStore, never against storage_module. The platform binding
## (LpStorage, next) drives the host's shared storage node over lp_*; LocalBlobStore below
## is the in-process stand-in the integration tests run on — tests use a real local store,
## never a mock, as with Transport.
##
## The shape follows storage_module 3.0.2 (engine logos-storage v0.5.3) where the room
## swarm depends on it, as S0 observed it at runtime (docs/labbook/storage-from-muster.md):
##   * upload a file by path → a manifest CID; the manifest names the uploaded file;
##   * a dataset is SERVED or not, and served means announced to the network's DHT too —
##     one bit, as `advertise` is; one not served is answered for by nobody, and its
##     provider record stays in the DHT after it stops (until it expires);
##   * a download asks only the providers the DHT lists for the CID — a connected peer is
##     never asked unless the DHT names it (Q1). A connection makes a listed provider
##     dialable when its announced address is not (no hairpin, same LAN; Q4). `private`
##     tunnels the download over Mix: no dial, the server sees a mix path, not the
##     fetcher, and only a provider reachable on the network serves it (Q3);
##   * uploads and downloads are jobs: started, then read after `poll` — the module thread
##     never waits on storage.
## Bytes here are opaque: the swarm seals them first (crypto/blob_seal.nim).

import std/[os, tables]
import ../hashing/sha256
import ../crypto/sodium

type
  PeerReach* = object
    peerId*: string
    addrs*: seq[string]
    network*: string

  BlobJobState* = enum jsRunning = "running", jsDone = "done", jsFailed = "failed"
  BlobJob* = object
    id*: string
    state*: BlobJobState
    cid*: string
    bytes*, total*: uint64
    error*: string

  BlobStore* = ref object of RootObj

method reach*(b: BlobStore): PeerReach {.base.} =
  ## How to reach this store's node: peer id, addresses, network.
  raise newException(CatchableError, "BlobStore.reach is abstract")
method upload*(b: BlobStore, path: string): string {.base.} =
  ## Start uploading the file at `path` (served and announced); returns the job id.
  raise newException(CatchableError, "BlobStore.upload is abstract")
method download*(b: BlobStore, cid, dest: string, private, serve: bool): string {.base.} =
  ## Start fetching `cid` into `dest`; keep it served onward when `serve`. Returns the job id.
  raise newException(CatchableError, "BlobStore.download is abstract")
method job*(b: BlobStore, id: string): BlobJob {.base.} =
  raise newException(CatchableError, "BlobStore.job is abstract")
method poll*(b: BlobStore) {.base.} =
  ## Advance jobs from what the node reported since the last poll.
  discard
method has*(b: BlobStore, cid: string): bool {.base.} =
  raise newException(CatchableError, "BlobStore.has is abstract")
method serving*(b: BlobStore, cid: string): bool {.base.} =
  raise newException(CatchableError, "BlobStore.serving is abstract")
method setServing*(b: BlobStore, cid: string, on: bool) {.base.} =
  raise newException(CatchableError, "BlobStore.setServing is abstract")
method connect*(b: BlobStore, peer: PeerReach) {.base.} =
  ## Dial a peer directly (the room's seed events say how), without the DHT.
  raise newException(CatchableError, "BlobStore.connect is abstract")
method remove*(b: BlobStore, cid: string) {.base.} =
  raise newException(CatchableError, "BlobStore.remove is abstract")

# ── LocalBlobStore ─────────────────────────────────────────────────────────────

const MixRequester* = "mix"   ## who a server sees ask, for a private download

type
  Served* = object
    cid*: string
    to*: string               ## the fetcher's peer id, or MixRequester

  LocalStorageNet* = ref object
    ## One storage network: its stores, and the DHT's provider records.
    network: string
    stores: Table[string, LocalBlobStore]
    dht: Table[string, seq[string]]

  LocalBlobStore* = ref object of BlobStore
    net: LocalStorageNet
    dir: string
    peerId: string
    reachable: bool                     ## its announced address can be dialled (AutoNAT says Reachable)
    blobs: Table[string, string]        ## cid -> path in dir
    names: Table[string, string]        ## cid -> the manifest's file name
    served: Table[string, bool]
    peers: seq[string]
    jobs: Table[string, BlobJob]
    log: seq[Served]
    nextJob: int

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc newLocalStorageNet*(network: string): LocalStorageNet =
  LocalStorageNet(network: network)

proc providers*(n: LocalStorageNet, cid: string): seq[string] =
  ## What the DHT shows anyone who asks: the peer ids providing `cid`.
  n.dht.getOrDefault(cid)

proc newLocalBlobStore*(net: LocalStorageNet, dir: string): LocalBlobStore =
  createDir(dir)
  result = LocalBlobStore(net: net, dir: dir, reachable: true,
                          peerId: "16UiuLocal" & hexOf(randomBytes(8)))
  net.stores[result.peerId] = result

proc servedLog*(b: LocalBlobStore): seq[Served] = b.log
proc manifestName*(b: LocalBlobStore, cid: string): string = b.names.getOrDefault(cid)
proc connected*(b: LocalBlobStore): seq[string] = b.peers   ## the peers this node is connected to
proc setReachable*(b: LocalBlobStore, on: bool) = b.reachable = on
  ## Whether others can dial this node's announced address (behind a NAT with no mapping: not).

proc announce(b: LocalBlobStore, cid: string) =
  ## A provider record. Stopping never withdraws one: the DHT keeps naming this node until
  ## the record expires, and the node then refuses (Q2).
  var ps = b.net.dht.getOrDefault(cid)
  if b.peerId notin ps: (ps.add b.peerId; b.net.dht[cid] = ps)

proc newJob(b: LocalBlobStore, j: BlobJob): string =
  inc b.nextJob
  result = b.peerId & "-" & $b.nextJob
  var k = j
  k.id = result
  b.jobs[result] = k

proc keep(b: LocalBlobStore, cid, bytes, name: string, serve: bool) =
  let p = b.dir / cid
  writeFile(p, bytes)
  b.blobs[cid] = p
  if cid notin b.names: b.names[cid] = name
  b.served[cid] = serve
  if serve: b.announce(cid)

method reach*(b: LocalBlobStore): PeerReach =
  PeerReach(peerId: b.peerId, addrs: @["/memory/" & b.peerId], network: b.net.network)

method upload*(b: LocalBlobStore, path: string): string =
  try:
    let bytes = readFile(path)
    var raw = newSeq[byte](bytes.len)
    for i, c in bytes: raw[i] = byte(c)
    let cid = "zLocal" & hexOf(sha256(raw))
    b.keep(cid, bytes, extractFilename(path), true)
    b.newJob(BlobJob(state: jsDone, cid: cid, bytes: uint64(bytes.len), total: uint64(bytes.len)))
  except CatchableError as e:
    b.newJob(BlobJob(state: jsFailed, error: e.msg))

proc source(b: LocalBlobStore, cid: string, private: bool): LocalBlobStore =
  ## A provider the DHT lists that serves `cid` and can be reached: over Mix only if its
  ## address is reachable; directly if it is, or if this node is connected to it.
  for p in b.net.providers(cid):
    let s = b.net.stores.getOrDefault(p)
    if s == nil or s == b or not s.served.getOrDefault(cid): continue
    if s.reachable or (not private and p in b.peers): return s

method download*(b: LocalBlobStore, cid, dest: string, private, serve: bool): string =
  let src = b.source(cid, private)
  if src == nil:
    return b.newJob(BlobJob(state: jsFailed, cid: cid, error: "no peer serves " & cid))
  let bytes = readFile(src.blobs[cid])
  src.log.add Served(cid: cid, to: (if private: MixRequester else: b.peerId))
  try:
    writeFile(dest, bytes)
  except CatchableError as e:
    return b.newJob(BlobJob(state: jsFailed, cid: cid, error: e.msg))
  b.keep(cid, bytes, src.names.getOrDefault(cid), serve)
  b.newJob(BlobJob(state: jsDone, cid: cid, bytes: uint64(bytes.len), total: uint64(bytes.len)))

method job*(b: LocalBlobStore, id: string): BlobJob =
  if id in b.jobs: b.jobs[id]
  else: BlobJob(id: id, state: jsFailed, error: "no such job")

method has*(b: LocalBlobStore, cid: string): bool = cid in b.blobs
method serving*(b: LocalBlobStore, cid: string): bool = b.served.getOrDefault(cid)

method setServing*(b: LocalBlobStore, cid: string, on: bool) =
  if cid notin b.blobs: return
  b.served[cid] = on
  if on: b.announce(cid)

method connect*(b: LocalBlobStore, peer: PeerReach) =
  ## A libp2p connection: both ends hold it.
  let other = b.net.stores.getOrDefault(peer.peerId)
  if peer.network != b.net.network or other == nil or other == b: return
  if peer.peerId notin b.peers: b.peers.add peer.peerId
  if b.peerId notin other.peers: other.peers.add b.peerId

method remove*(b: LocalBlobStore, cid: string) =
  if cid in b.blobs:
    removeFile(b.blobs[cid])
    b.blobs.del cid
  b.served.del cid
