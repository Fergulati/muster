# What Muster would ask of Logos Storage

**For:** the Logos Storage team (`logos-storage-nim`, `logos-storage-module`), through Corey and Jarrad.
**Status:** written 2026-10-16. On Muster's side the S0 spike is done; sealed blobs, the room as tracker and the in-process share/fetch/seed flow have landed on branch `feat/room-swarm`, and the typed spec `derived-exo-4d0.4` grades 5/5. The real `storage_module` binding and the UI are in progress.
**Reads with:** `docs/design/room-swarm.md` (the design; §6 is the asks in short), `docs/labbook/storage-from-muster.md` (the S0 spike, Q1–Q8, with every command and result).

## The short version

Jarrad, asked what he wanted to see in Muster:

> I know Storage (Logos storage) was thinking of providing a simple storage peer network
> using delivery, because it offered a trusted bound, muster would actually be ideal for
> that, kinda like a mini private torrent tracker.

So we are building it. We call it FileShare; the code calls the mechanism the *room swarm*. A Muster room is a group of members who talk over Logos Delivery, under keys that only members hold. A private BitTorrent tracker is three things: who may take part, which files exist, and who holds each one. A room already is the first two, with no server. The swarm adds the third as signed events in the room's log, and lets Logos Storage move the bytes. Storage only ever sees ciphertext.

It works today, with one catch: every fetch goes through the storage DHT. A seeder we have dialled directly is never asked for a manifest unless the DHT names it. So the ciphertext CID, its providers, and every lookup are public DHT traffic, even though the room already knows exactly who to ask.

What would help, roughly by how much:

1. **U1 + U6: serve to named peers, and fetch from named peers.** Split `advertise` into *announce* and *serve*, let *serve* take a peer allowlist, and let a download ask peers the caller names (or take a manifest the caller supplies). Together they make the room the trusted bound: no CID or provider record ever leaves the room. These two matter most.
2. **U2: a node, or a namespace, per consumer.** Today there is one shared node and one config file, and `init` rewrites it for everyone.
3. **U3: events addressed to their caller.** A download's session id is its CID, so two consumers fetching the same CID cannot tell their events apart.
4. **U4: a `fetch` completion event, and `uploadChunk` as `bstr`.**
5. **U5: a manifest with no filename or mimetype, or caller-set ones.**

We are not asking for encryption. Muster seals every file before Storage sees it (below).

## What was run

All runs were on 2026-10-15, on one Linux host. Every node had its own scratch data dir; `~/.logos_storage` was only read.

| Piece | Version |
|---|---|
| Engine | `logos-storage-nim` v0.5.3 (release binary, REST API on) |
| Module | `storage_module` 3.0.2 (`logos-storage-module` @`7548f41`), hosted by `logoscore` |
| Basecamp | 0.3.2, which pins the same module and engine |
| Code read | `logos-storage-nim` @`d1f4f42` (v0.5.3 plus four commits, none in the paths below) |

Each finding below says whether it was **observed at runtime** or **read in code**, as the labbook does.

## What works today

- **A private network of the room's own nodes.** Every node bootstraps from one member's SPR, so the seeder's provider record is one hop away. 10 MB arrived in 0.93 s and 100 MB in 10.5 s on loopback, byte-identical. *Observed* (Q1).
- **`logos.dev`.** Upload on one node, fetch by CID on another: 1.4–4.5 s for 10 MB, most of it the public DHT lookup (0.5–3.5 s). A fresh node took about 2 minutes to become Reachable (PCP, then AutoNAT). *Observed* (Q4).
- **Mix (`isPrivate`).** On `logos.dev` the manifest came in 7.0 s and 1 MB in 70.7 s, about 15 KB/s, and the two nodes never connected. *Observed* (Q3).
- **Events over `lp_*`.** `logoscore watch storage_module` showed `storageUploadDone` on the host bus, its payload a JSON document in `arg0`. Muster's Nim plugin already subscribes to `delivery_module` the same way. *Observed on the bus; the subscribe from Muster's plugin is read in code* (Q7).
- **The serve gate holds.** With `advertise=false` a seeder answers NotFound for the manifest and sends no blocks, even to a connected peer that knows the CID. *Observed* (Q2).

## What Muster already does on its side

So you can see what we are not asking for:

- **Sealed blobs** (`module/src/crypto/blob_seal.nim`). A fresh 32-byte key per file, libsodium's `crypto_secretstream_xchacha20poly1305` in 64 KiB chunks. After a download Muster checks the plaintext against a digest the sharer committed (a domain-separated record, `muster.blob.plaintext.v1`) and refuses the file on a mismatch, whatever Storage's own Merkle tree said.
- **A neutral upload name.** The ciphertext goes up as `<32 random hex>.bin`, so the manifest says only "an opaque binary blob of N bytes" (Q5).
- **The room log is the index and the peer list.** `file/<fid>` carries the name, size, digest, ciphertext CID and file key, sealed to the room. `file/<fid>/seed/<who>` is signed by the seeder and carries their storage peer id, addresses and network. A seeder is listed only by their own signed announce; Muster never infers a holder from the node's peer table. A member who joins later holds no key to an earlier file.
- **Private fetch** is a per-file choice: `isPrivate=true`, `advertise=false`, no direct dial (a dial would hand the seeder this node's address), and no seed event afterwards.
- **We name the observers.** `storage-peer` and `storage-dht` are observer classes in Muster's disclosure table (`intents/disclosure.nim`). The room's flow view and room map name them beside each shared file: the DHT sees the ciphertext CID and the peer ids providing it, and a peer that fetches sees the ciphertext and the serving node's address. The design adds what the log cannot show: each lookup tells the DHT nodes asked which peer wants which CID.

## The asks

Each ask gives what we would want, what we observed, what Muster does without it, and a possible shape. The shapes are suggestions. You know the engine; we only know what we ran and read.

### U1. Serve without announcing, to an allowlist of peers

**What we'd want.** Announce to the DHT and serve as two separate switches, with *serve* able to take a list of peer ids (or SPRs). Muster would fill the list from the room's seed events.

**Why.** `advertise` is one bit for both, and the gate is all-or-nothing. *Read in code:* `handleManifestRequest` returns NotFound when a dataset is not advertised (`storage/manifest/protocol.nim:126`), and the block engine skips both presence (`storage/blockexchange/engine/engine.nim:1021`) and block requests (`:1227`). *Observed* (Q2): C fetched a manifest with A's record in its DHT after A set `advertise=false`, and got `Manifest not found on peer …`. A stream of a dataset whose manifest C already held sat at 0 bytes for 90 s.

**Without it.** A member who seeds must advertise, so the CID and their peer id go into the public DHT, and anyone holding the CID can fetch the ciphertext. They cannot read it, but "only room members can fetch the ciphertext" stays a *gap* in Muster's claims registry. A record also outlives a stop until it expires, so the DHT keeps naming a past seeder (*observed*, Q2).

**A possible shape.** `uploadUrl(path, chunkSize, announce, serve)` with `serve: none | all | peers`, and a call to set a dataset's peer list after upload, e.g. `setServing(cid, peers: [peerId])`. Or a node-wide `serve-allow` list in the config, if per-dataset is too fine.

### U6. Fetch from named peers, or accept a caller-supplied manifest

**What we'd want.** A download (or manifest) call that takes peer ids or SPRs and asks them directly. Or a way to import a manifest block the caller already has; the room could carry the manifest bytes in `file/<fid>`.

**Why.** *Observed* (Q1): two nodes on `--no-bootstrap-node`, connected (`Successfully connected to peer`, both listing the connection, both routing tables empty). The downloader streamed the CID and got `404 … (Key doesn't exist)` after 27.0 s, ten DHT lookups. *Read in code:* `fetchManifest` asks only the providers `self.discovery.find(cid, …)` returns (`storage/manifest/protocol.nim:192–241`, the lookup at `:216`). A libp2p `connect` does not put the peer in the downloader's Kademlia table. The block engine would use the connection, since it sends want-have to connected peers (`selectInitialPresencePeers`, `engine.nim:521`), but the download cannot start until the manifest arrives.

**Without it.** Muster dials each seeder the room names, then downloads by CID, and the DHT finds the provider. The dial still helps: on one host the provider record carried only the public address, the router did not hairpin, and the fetch succeeded only over the connection we had made (*observed*, Q4). But on Basecamp's shared node the lookup is on the public `logos.test` DHT every time. A private network bootstrapped from a member's SPR would avoid that, but it needs a node Muster controls (U2).

**A possible shape.** `downloadToUrl(cid, path, isPrivate, advertise, peers?)` and `downloadManifest(cid, peers?)`, where `peers` skips discovery and asks those providers. Or `importManifest(bytes) → cid` after which the block engine's connected-peer broadcast does the rest.

**U1 and U6 together** let a delivery-bounded group share content with no DHT exposure at all: the room says who holds what, the seeders serve only the room, and nothing about the file leaves it. That is the private tracker done properly, and, we think, the trusted bound Jarrad described.

### U2. A node, or a namespace, per consumer

**What we'd want.** A consumer gets its own node, or its own namespace on the shared one, with its own network, quota and Mix settings, without touching anyone else's.

**Why.** In Basecamp 0.3.2 the package downloader inits the shared node as soon as `storage_module` is ready, on `logos.test` with Mix on, and downloads packages with `advertise=false` (*read in code* at the pinned commits, and matching this host's `~/.logos_storage/config.json`, Q8). `init` writes the caller's normalized config back to `~/.logos_storage/config.json` (*observed* with `HOME` redirected). And `network()` on a node started with `no-bootstrap-node: true` answered `"logos.test"`, the default preset's name, not the network it was on (*observed*, Q8).

**Without it.** Under Basecamp, Muster only ever attaches to the shared node and never inits, stops or destroys it; only in its own standalone runner, where nothing else starts a node, does it init one. Its network and Mix settings are whatever the downloader picked. It cannot run a private network for a room. It records a network per share and per seed event, but `network()` cannot say which network a node is on, so that field is only as good as the preset name.

**A possible shape.** `init(config, namespace)` that keeps a namespace's data and settings apart and never writes the shared file; or a second node per consumer, at its own data dir and ports. And `network()` returning the bootstrap set, or `"custom"`, on a non-preset network.

### U3. Events addressed to their caller

**What we'd want.** Each event delivered only to the module whose call started it, or at least carrying a caller id.

**Why.** Events are host-wide. *Observed* (Q7): an upload's session id is a node-wide counter (`"0"`, `"1"`, …), and `downloadToUrl` returned the CID as its session id, with every `storageDownloadProgress`/`Done` carrying `"sessionId":"<cid>"`.

**Without it.** Muster matches downloads by CID and expects foreign events on the same CID. If the downloader and Muster, or two rooms, fetch one CID at once, they share one event stream and cannot tell whose download finished.

**A possible shape.** A per-call session id for downloads, as uploads have; or a `caller` field set from the calling module's identity in every event.

### U4. A fetch completion event, and `uploadChunk` as `bstr`

**What we'd want.** `fetch` signals when it is done. `uploadChunk(sessionId, chunk)` takes `bstr`.

**Why.** `fetch` has no completion event: the contract says so (`storage_module.lidl` 3.0.2: "no event is emitted when the background download completes"). `uploadChunk` declares its chunk as `tstr`, which crosses the host as a JSON string, and non-UTF-8 bytes have no JSON-string form (*read in code*, Q6; the module itself returns `downloadChunks` as base64). We could not test it at runtime: `logoscore`'s CLI rejects ill-formed UTF-8 before the call.

**Without it.** Muster uploads with `uploadUrl` from a temp file and does not use `fetch`.

**A possible shape.** `storageFetchDone {cid, sessionId, success}`; `uploadChunk(sessionId, chunk: bstr)`; the JSON transport already carries a `bstr` as a tagged `{"_bytes": …}` object (`logos_sdk/bytes.nim`).

### U5. A manifest without filename or mimetype, or caller-set

**What we'd want.** An upload whose manifest names nothing, or names what the caller says.

**Why.** *Observed* (Q5): after `uploadUrl("…/67f313dcf4ec83fc.bin", 65536, true)`, the uploader's `manifests()`, another peer's manifest fetch and the downloader's `Content-Disposition` all carried `"filename":"67f313dcf4ec83fc.bin","mimetype":"application/octet-stream"`. The mimetype comes from the extension.

**Without it.** Muster seals to a temp file anyway and names it `<random>.bin`, so this costs us little. A consumer that uploads a file as it is has no such workaround: its file name and type go to every peer that fetches the manifest.

**A possible shape.** `uploadUrl(path, chunkSize, advertise, filename?, mimetype?)`, where an empty value stores none.

## Smaller things we hit

- **A Mix sender in its own pool fails.** With the sender in its own pool, a manifest took 104 s and the stream then sat at 0 bytes for 10 minutes; its log has 126 `internalConnect can't dial self!`. Without it, 1 MB arrived in 62.8 s. Path selection does not leave out the sender (*observed*, Q3).
- **Mix on a custom network is off, and needs a hand-built pool.** `storage_module` builds a relay pool and DHT proxies only for the presets and sets `mix-enabled = !hasCustomBootstrap` (*read in code*). Passing them through `init` should work; we have not run it.
- **`-b <spr>` fails to parse;** `--bootstrap-node=<spr>` works (*observed*).
- **A provider record carries only the public address,** not the LAN or loopback listen address, so two nodes behind one router that does not hairpin cannot use it (*observed*, Q4).

## What we're happy to help with

- **Test a branch.** Muster's S0 rig runs a private network and `logos.dev` nodes from one host, and the swarm's planned self-test runs two app instances on a private storage network of their own. We can run U1 or U6 against them and report back.
- **The room as a membership oracle.** For an allowlist (U1), Muster can hand the node the peer ids of the room's current seeders, each one signed by its owner and updated as members seed and stop.
- **A second consumer.** If you want a consumer other than the package downloader to shape the per-consumer API (U2, U3), we are one.

## Open questions for you

1. **Is a peer allowlist, or announce/serve as separate switches, on your roadmap?** If something like U1 is planned, we would rather shape the swarm to it now.
2. **How do provider records expire?** After a seeder withdraws, other DHT nodes keep naming it until the record expires. How long is that, and can a provider withdraw a record?
3. **Can Mix reach an unreachable seeder?** Our private fetch reaches only a seeder whose address is reachable. Could Mix-routed serving let a seeder behind a NAT serve without being dialled?
4. **Two members behind two home NATs.** We have not tested it. Our router offered PCP, so our seeder became Reachable. Without PCP or UPnP, is circuit relay (`--nat-max-relays`) the intended path, and does it carry a block exchange at useful speed?
5. **Was "a simple storage peer network using delivery" meant to look like this?** If you had a different shape in mind for the delivery-bounded network, we would like to hear it before we build further.
