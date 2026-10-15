## The storage seam's in-process stand-in (exo-4d0.2, docs/design/room-swarm.md §5.1). The
## room swarm's tests run on LocalBlobStore, never a mock, so it behaves as storage_module
## does where the swarm depends on it (read in logos-storage-nim, docs/design/room-swarm.md
## §3): content-addressed; a dataset that is not served is neither announced nor answered
## for; a download reaches a connected peer that serves it, or any provider the network's
## DHT lists; a private download hides the fetcher from the server. It also records what a
## server and the DHT observed, so the swarm's disclosure rows can be checked against it.

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
  doAssert net.providers(up.cid) == @[b.reach().peerId], $net.providers(up.cid)
  let c2 = newLocalBlobStore(net, dir / "c2")
  discard c2.done(c2.download(up.cid, dir / "c2dht.out", private = false, serve = false))
  doAssert readFile(dir / "c2dht.out") == content
  doAssert not c2.serving(up.cid), "serve=false: kept, neither served nor announced"
  doAssert net.providers(up.cid) == @[b.reach().peerId]
echo "4. served datasets are announced and found through the DHT OK"

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

# 6. Remove: gone locally, unannounced.
b.remove(up.cid)
doAssert not b.has(up.cid) and b.reach().peerId notin net.providers(up.cid)
echo "6. remove OK"

removeDir(dir)
echo "blob_store_test: all OK"
