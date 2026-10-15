## The storage seam's in-process stand-in (exo-4d0.2, docs/design/room-swarm.md §5.1). The
## room swarm's tests run on LocalBlobStore, never a mock, so it behaves as storage_module
## 3.0.2 did at runtime in S0 (docs/labbook/storage-from-muster.md): content-addressed; a
## dataset that is not served is answered for by nobody, and its provider record outlives
## the stop; a download asks only the providers the DHT lists, a connection only making an
## unreachable one dialable; a private download dials nobody and hides the fetcher from the
## server. It records what a server and the DHT observed, so the swarm's disclosure rows
## can be checked against it.

import std/[os, strutils]
import ../src/storage/blob_store
import ../src/crypto/sodium

let dir = getTempDir() / ("muster-blob-store-" & $getCurrentProcessId())
createDir(dir)

proc bytesFile(path: string, n: int): string =
  let b = randomBytes(n)
  var s = newString(n)
  for i, x in b: s[i] = char(x)
  writeFile(path, s)
  s

proc done(b: BlobStore, id: string): BlobJob =
  b.poll()
  result = b.job(id)
  doAssert result.state == jsDone, "job " & id & ": " & $result.state & " " & result.error

let net = newLocalStorageNet("logos.dev")
let a = newLocalBlobStore(net, dir / "a")
let b = newLocalBlobStore(net, dir / "b")
let c = newLocalBlobStore(net, dir / "c")
let other = newLocalBlobStore(newLocalStorageNet("logos.test"), dir / "o")

# 1. Upload: content-addressed, the same bytes give the same CID; the node knows how to be
#    reached; the manifest carries the upload's file name as Storage's does.
let srcA = dir / "4f2a.bin"
let content = bytesFile(srcA, 200_000)
let up = a.done(a.upload(srcA))
doAssert up.cid.len > 0 and a.has(up.cid)
writeFile(dir / "copy.bin", content)
doAssert a.done(a.upload(dir / "copy.bin")).cid == up.cid, "same bytes, same CID"
doAssert a.manifestName(up.cid) in ["4f2a.bin", "copy.bin"], "the manifest names the uploaded file"
let ra = a.reach()
doAssert ra.peerId.len > 0 and ra.addrs.len > 0 and ra.network == "logos.dev"
doAssert ra.peerId != b.reach().peerId
echo "1. upload, CID, reach OK"

# 2. Download from a connected peer that serves it: the bytes arrive at the destination.
b.connect(ra)
let dl = b.done(b.download(up.cid, dir / "b.out", private = false, serve = true))
doAssert readFile(dir / "b.out") == content and dl.bytes == uint64(content.len)
doAssert b.has(up.cid) and b.serving(up.cid), "a download kept with serve=true is served onward"
echo "2. download from a connected seeder OK"

# 2b. Reachability (S0 Q1, Q4): a seeder behind a NAT with no mapping is listed by the DHT
#     but cannot be dialled — until the fetcher is connected to it. A private fetch never
#     dials, so it cannot reach such a seeder at all.
block:
  let n2 = newLocalStorageNet("logos.dev")
  let s = newLocalBlobStore(n2, dir / "nat-s")
  let f = newLocalBlobStore(n2, dir / "nat-f")
  s.setReachable(false)
  discard bytesFile(dir / "nat.bin", 1000)
  let cid = s.done(s.upload(dir / "nat.bin")).cid
  let j1 = f.download(cid, dir / "nat1.out", private = false, serve = false)
  f.poll()
  doAssert f.job(j1).state == jsFailed, "listed, but not dialable"
  let j2 = f.download(cid, dir / "nat2.out", private = true, serve = false)
  f.poll()
  doAssert f.job(j2).state == jsFailed, "a private fetch cannot reach an unreachable seeder"
  f.connect(s.reach())
  doAssert s.reach().peerId in f.connected() and f.reach().peerId in s.connected(), "a connection has two ends"
  discard f.done(f.download(cid, dir / "nat3.out", private = false, serve = false))
  # a connection without a provider record is not enough (Q1): another network's node
  # cannot even connect, and a CID nobody announced is not found by a connected peer
  let g = newLocalBlobStore(n2, dir / "nat-g")
  g.connect(s.reach())
  let j4 = g.download("zLocalNeverAnnounced", dir / "nat4.out", private = false, serve = false)
  g.poll()
  doAssert g.job(j4).state == jsFailed
echo "2b. only DHT providers serve; a connection makes an unreachable one dialable OK"

# 3. Not served means not answered: A stops serving, and C — connected to A only — fails;
#    a missing CID fails; a store on another network finds nothing.
a.setServing(up.cid, false)
c.connect(ra)
block:
  b.setServing(up.cid, false)
  let j = c.download(up.cid, dir / "c.out", private = false, serve = false)
  c.poll()
  doAssert c.job(j).state == jsFailed and not fileExists(dir / "c.out")
  b.setServing(up.cid, true)
  let j2 = c.download("zNoSuchCid", dir / "c2.out", private = false, serve = false)
  c.poll()
  doAssert c.job(j2).state == jsFailed
  other.connect(ra)
  let j3 = other.download(up.cid, dir / "o.out", private = false, serve = false)
  other.poll()
  doAssert other.job(j3).state == jsFailed, "another network's store does not reach this one"
echo "3. not served, missing, other network: all fail, nothing written OK"

# 4. The DHT: a served dataset is announced; C, connected to nobody serving it, still finds
#    B through the DHT. What the DHT shows is the CID and its providers' peer ids.
block:
  # A stopped at step 3, but its record outlives the stop (S0 Q2): the DHT still names it
  doAssert net.providers(up.cid) == @[a.reach().peerId, b.reach().peerId], $net.providers(up.cid)
  let c2 = newLocalBlobStore(net, dir / "c2")
  discard c2.done(c2.download(up.cid, dir / "c2dht.out", private = false, serve = false))
  doAssert readFile(dir / "c2dht.out") == content
  doAssert not c2.serving(up.cid), "serve=false: kept, neither served nor announced"
  doAssert c2.reach().peerId notin net.providers(up.cid), "serve=false announces nothing"
echo "4. served datasets are announced and found through the DHT; stale records stay OK"

# 5. What a server sees: the fetcher's peer id and the CID — or, for a private download,
#    only that a mix path asked.
block:
  let d = newLocalBlobStore(net, dir / "d")
  discard d.done(d.download(up.cid, dir / "d.out", private = false, serve = false))
  discard d.done(d.download(up.cid, dir / "d2.out", private = true, serve = false))
  var sawPeer, sawMix = false
  for s in b.servedLog():
    doAssert s.cid == up.cid
    if s.to == d.reach().peerId: sawPeer = true
    if s.to == MixRequester: sawMix = true
  doAssert sawPeer and sawMix, $b.servedLog()
echo "5. a server sees the fetcher, or a mix path for a private download OK"

# 6. Remove: gone locally and no longer served, though the DHT still names the node.
b.remove(up.cid)
doAssert not b.has(up.cid) and not b.serving(up.cid)
doAssert b.reach().peerId in net.providers(up.cid), "the record outlives the blob"
block:
  let e = newLocalBlobStore(net, dir / "e")
  let j = e.download(up.cid, dir / "e.out", private = false, serve = false)
  e.poll()
  doAssert e.job(j).state == jsFailed, "every listed provider refuses: nothing is fetched"
echo "6. remove OK"

removeDir(dir)
echo "blob_store_test: all OK"
