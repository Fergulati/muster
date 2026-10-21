# Logos Storage from Muster: ground truth for the room swarm (2026-10-15)

S0 of the room swarm (`exo-4d0.1`, `docs/design/room-swarm.md` §7) asked eight
questions about Logos Storage before Muster builds on it. This page answers them, and
says for each one whether the answer was **observed at runtime** or **read in code**.

Short answer:

- **A direct `connect` is not enough.** A downloader that has dialed the seeder still
  finds the dataset only through a DHT provider record. The manifest is asked only of
  peers the DHT names. On a private network of the room's own nodes this works, and
  10 MB arrives in under a second.
- **`advertise=false` really refuses.** The seeder answers NotFound for the manifest and
  sends no blocks, even to a connected peer that knows the CID.
- **Mix (`isPrivate`) works but is slow.** On `logos.dev`, 1 MB took 71 s (about
  15 KB/s). On a private network it works only with a hand-built pool of at least four
  mix nodes, one of which is a DHT proxy. `storage_module` never builds such a pool.
- **Basecamp 0.3.2's shared node is on `logos.test`, with Mix on.** It downloads
  packages with `advertise=false`.

## What was run

| Piece | Version | Where it came from |
|---|---|---|
| Storage engine | `logos-storage-nim` **v0.5.3** (`56854f4`) | the release binary `logos-storage-linux-amd64-v0.5.3` from GitHub releases; no build |
| `storage_module` | **3.0.2**, `logos-storage-module` @`7548f41` | `storage_module-3.0.2.lgx` from `logos-modules-release`; its `flake.nix` pins `logos-storage-nim` `refs/tags/v0.5.3` |
| Host for the module | `logoscore` pre-release-`a3d7507` (portable bundle) | already in this machine's `/nix/store`; no evaluation |
| Basecamp | **0.3.2**, tag → `f2fae63` | its `flake.lock` pins `logos-storage-module` `7548f41`, `logos-storage` v0.5.3 and `logos-package-downloader-module` `7b0ca8b` |
| Code read | `logos-storage-nim` @`d1f4f42` (v0.5.3 + 4 commits, of which only the nim-ffi C bindings and a 5-line `conf.nim`/`storage.nim` change differ in the engine) and @v0.5.3; `nim-libp2p-mix` @`0883587`; `libp2p-mix-transport` @`653bcd6`; `logos-nim-sdk` @`6077eb7` (muster's pin) | |

Basecamp 0.3.2, `storage_module` 3.0.2 and the CLI binary all run the **same engine**,
v0.5.3. The module is a thin C++ plugin over `libstorage` from that engine
(`storage_upload_init`, `storage_download_manifest` and the rest). Questions 1–4 were
run against the CLI binary's REST API, which is enabled by the hidden
`--api-bindaddr`/`--api-port` flags. The REST routes call the same `StorageNodeRef`
procs as `libstorage`. The REST transport `direct|mix` is the module's `isPrivate`:
`node_download_request.nim` maps `isPrivate` to `DownloadTransport.Mix`. Questions 5,
6 and 8 were also run through `storage_module` 3.0.2 itself, hosted by `logoscore`.

Every node had its own data dir under the session scratchpad and explicit ports
(471xx). The `logoscore` daemon ran with `HOME` and `--config-dir` pointed at a
scratch directory, because `storage_module.init()` writes `$HOME/.logos_storage/config.json`
(see Q8). `~/.logos_storage` was only read, never written: its mtime stayed
2026-10-14 21:47. Every process started was killed at the end.

Launcher used for every CLI node:

```sh
logos-storage-linux-amd64-v0.5.3 --data-dir=<scratch>/N/data --listen-port=<P> \
  --api-bindaddr=127.0.0.1 --api-port=<A> --log-format=nocolors --metrics=false <extra>
# private network: first node   --no-bootstrap-node --nat=extip:127.0.0.1 --listen-ip=127.0.0.1
#                  others        --bootstrap-node=<first node's SPR> (the `-b <spr>` short form fails to parse)
# public:                        --network=logos.dev
```

## Q1. Does a `connect`ed seeder serve a downloader with no DHT provider record?

**No. Observed at runtime, and the code says why.**

Two nodes, D and E, both ran `--no-bootstrap-node`, so each had a DHT of one. D uploaded
10 MB. E called `connect(D, /ip4/127.0.0.1/tcp/47104)` and got "Successfully connected
to peer". Fifteen seconds later both nodes listed the connection, and **both routing
tables were empty**. E then streamed the CID:

```
404  "The requested CID could not be retrieved (Key doesn't exist)."   27.0 s
```

An earlier pair, A and B, failed the same way: `Failed to fetch manifest … after 10
attempts: Key doesn't exist`. The 27 s is ten DHT lookups with a retry delay between
them.

In the code (`storage/manifest/protocol.nim`, `fetchManifest`), the manifest is
requested **only** from `self.discovery.find(cid)`, a Kademlia `getProviders`. A
connected peer is never asked. A libp2p `connect` does not put the peer in the
downloader's Kademlia routing table. A later inbound Kademlia query does: once C
bootstrapped and queried B, B's table listed A and C. The block engine *would* use the
connection: `engine.nim` broadcasts want-have to every connected peer
(`selectInitialPresencePeers` returns all of them). But the download cannot start until
the manifest has been fetched.

**What works.** On a private network where every node bootstraps from one node's SPR,
the DHT is the room's own nodes, and the seeder's provider record is one hop away.

| Setup | 10 MB | 100 MB |
|---|---|---|
| F bootstrapped from seeder D's SPR (2 nodes, loopback), cold node, manifest + stream | **0.93 s**, sha256 equal | **10.5 s** (~10 MB/s, loopback) |
| C bootstrapped from seeder A (3 nodes) | 0.94 s, manifest 21 ms | — |

So the room swarm cannot be "connect, then download". Either the downloader shares a
DHT with the seeder (a preset network, or a private network bootstrapped from a
member's SPR), or Storage adds a fetch from named peers (ask U6 below).

## Q2. With `advertise=false`, does a connected downloader get nothing?

**Yes, it gets nothing. Observed at runtime, confirming the code.**

- **Uploaded with `advertise=false`.** C was on A's private network and connected. Its
  manifest fetch failed after 27 s with `Key doesn't exist`: nothing was announced, so
  there is no provider to ask.
- **The serve gate, isolated.** A uploaded with `advertise=true` and waited 8 s, so the
  provider record reached C's DHT. Then A set `advertise=false` and C fetched the
  manifest:

  ```
  Failed to fetch manifest … after 10 attempts: Manifest not found on peer 16Uiu2HAkz2tD…9D7p9a
  ```

  The DHT still named A after A withdrew. A answered the manifest request with NotFound
  (`handleManifestRequest`, `not advertised`).
- **Blocks, isolated.** C first fetched the manifest of a third, advertised dataset with
  `advertise=false` on C's side. Then A withdrew, and C streamed the dataset. The
  response stayed at **0 bytes for 90 s**, so A served no blocks either
  (`engine.nim` skips presence for non-advertised trees).

A side finding: **a provider record outlives the withdrawal.** Other DHT nodes keep
naming the old seeder until the record expires. The old seeder only refuses.

## Q3. Does `isPrivate=true` (Mix) work against a directly connected peer on a private network?

**On a preset network it works. Observed on `logos.dev`.** On a private network it works
only with a Mix pool built by hand, which `storage_module` never builds. **Observed, with
a 5-node network on loopback.**

- **What Mix needs (code).**
  - `--mix-enabled`, plus a relay pool (`--mix-pool[-json]`: `peerId`, `mixPubKey`,
    `libp2pPubKey`, `multiAddr` per relay).
  - `--dht-mix-proxy` SPRs: with Mix, provider lookups go through a proxy
    (`discovery.findViaMix`).
  - A seeder with a `/mix-transport/` address.
  - A path of three hops (`PathLength = 3`, `mix_protocol.nim`). The pool needs at least
    three usable nodes besides the sender.

  `storage_module` reads the pool and proxies only from its `mix-config.json` presets
  (`logos.test`, `logos.dev`). For a custom bootstrap it **turns Mix off by default**
  (`migrateV1toV2`: `mix-enabled = !hasCustomBootstrap`), and `syncMixConfig` leaves a
  custom-bootstrap config alone. A caller that passes its own `mix-enabled`,
  `mix-pool-json` and `dht-mix-proxy` to `init` should get them through to libstorage.
  That is read in code, not run through the module.
- **Public, observed.** I and J ran on `logos.dev` with `--mix-enabled` and the preset's
  pool and proxies, copied from the module's `mix-config.json`.
  - I uploaded 1 MB. Once AutoNAT and PCP had made it Reachable (about 2 min), its
    addresses included `/ip4/<public>/tcp/47113/mix-transport/…`.
  - J fetched the manifest with `transport=mix` in **7.0 s**, and streamed **1 MB in
    70.7 s** (~15 KB/s), byte-identical.
  - J was never directly connected to I (`debug().connections` did not list I). On one
    host J could not have reached I directly anyway, because the router does not
    hairpin (Q4).
- **Private, observed.** Five nodes, P1–P5, all `--mix-enabled`, on loopback. P2–P5
  bootstrapped from P1 and used P1 as the DHT proxy, with a pool built from the nodes'
  own `debug()` output. P5 connected to the seeder P2, then fetched over Mix.
  - **With P5 in its own pool:** the manifest took 104 s, then the stream sat at 0 bytes
    for 10 min. P5's log has 126 `internalConnect can't dial self!`: path selection does
    not leave out the sender.
  - **With a pool without P5:** the manifest took **2.8 s**, and **1 MB streamed in
    62.8 s** (~16.7 KB/s), byte-identical.
- **Speed is the protocol.** About 16 KB/s on loopback and about 15 KB/s through the
  public relays, so 10 MB takes roughly 10–11 minutes either way.
- **The direct connection does not shortcut Mix.** Data goes over the Mix path whether
  or not the peers are connected.

## Q4. Two nodes on `logos.dev`: upload on one, download by CID on the other

**It works. Observed at runtime, both nodes on this host.**

G and H started with `--network=logos.dev` and found 7 bootstrap peers each.

- **The first fetches failed.** For about 2 minutes G reported reachability
  `NotReachable`, then `Reachable` once a **PCP port mapping** and AutoNAT confirmed its
  public address `/ip4/<this host's public IP>/tcp/47111`. H's fetches in that time ended in
  `Key doesn't exist`.
- **Then the hairpin.** After G re-advertised, H's DHT lookup **found G as provider**
  (trace: `reply for GetProviders`). But dialing G's announced public address failed:
  the home router does not hairpin. The provider record and `debug().addrs` carry only
  the public address, not the LAN or loopback listen address.
- **With a direct connect first.** H called `connect(G, /ip4/127.0.0.1/tcp/47111)`.
  The DHT-found provider was then dialed over that existing connection, and the stream
  succeeded:

| Fetch on H (connected to G; record found through the public DHT) | manifest | 10 MB stream | total |
|---|---|---|---|
| `cidG`, record a few minutes old | — | — | 2.52 s |
| fresh upload, fetched at once, run 1 | 3.49 s | 0.93 s | 4.45 s |
| fresh upload, fetched at once, run 2 | 0.49 s | 0.91 s | 1.43 s |

So most of the time is the public DHT lookup, 0.5–3.5 s. The transfer itself was local.

**Not tested: two members behind two different home NATs.** It stays an open question.
This host's router offered PCP, so G became reachable. A NAT without PCP, UPnP or a
relay would leave a seeder `NotReachable`, and `--nat-max-relays` (circuit relay) was
not exercised.

## Q5. Does the manifest's filename and mimetype reach the downloader in clear?

**Yes. Observed at runtime, through `storage_module` 3.0.2.**

`storage_module.uploadUrl("<scratch>/67f313dcf4ec83fc.bin", 65536, true)` →
`storageUploadDone {cid: zDvZRwzkvrf…}`; `manifests()` on the uploader, and a separate
peer's `GET …/network/manifest`, both show:

```json
"filename":"67f313dcf4ec83fc.bin","mimetype":"application/octet-stream"
```

The downloader's stream response also carries `Content-Disposition: attachment;
filename="67f313dcf4ec83fc.bin"`. The mimetype comes from the extension
(`node_upload_request.nim` `init`: `std/mimetypes`; Nim's table maps `bin` to
`application/octet-stream` and, for example, `dat` to nothing). The module's
`downloadManifest` event carries the same fields to the downloader
(`storageDownloadManifestDone` … `"filename":"6a3fffce7271e52e.bin"`). An upload over
REST with no Content-Type stores `"mimetype": null` instead.

§5.2's neutral `<random>.bin` therefore discloses exactly "an opaque binary blob of N
bytes".

## Q6. Does `uploadChunk(sessionId, chunk: tstr)` carry arbitrary binary intact?

**Not tested at runtime. Read in code: no.**

- **Through `logoscore`:** `uploadInit` worked and returned session id `"1"`. But the
  CLI turns a numeric argument into an integer, so `uploadChunk 1 …` matched no
  signature and returned `success:false`. A quoted `"\"2\""` reached libstorage as the
  literal `"2"` (`session is not found: "2"`). No byte comparison was possible from the
  CLI. The CLI's own parser rejects `ill-formed UTF-8` (a string in the binary).
- **In code:** the plugin copies `std::string` data+size into `storage_upload_chunk`,
  which is binary-safe at the C ABI. But a `tstr` reaches the plugin as a JSON string:
  - `logos_sdk/bytes.nim`: "the JSON transport is text, so bytes travel as a tagged
    object `{"_bytes": …}`", and that tagging applies to `bstr` only.
  - Non-UTF-8 bytes have no JSON-string form.
  - `\u0000` is valid JSON, but whether every host hop keeps it was not checked.

  `downloadChunks` sends chunks back **base64**, which is the module's own admission.
- **Do this:** keep `uploadUrl` from a temp file (§5.2, §5.1). U4 (`uploadChunk` as
  `bstr`) stands.

## Q7. Can a Nim module subscribe to `storage_module` events over `lp_*`?

**Yes. Read in code, plus the event bus observed through `logoscore watch`.**

- **The call.** `delivery.nim` calls
  `lp_subscribe(lp_client_create("delivery_module", "muster_module", nil, nil),
  "messageReceived", onMessageReceived, self)`.
  - `lp_subscribe(client, eventName, cb, userData)` (`logos_sdk/ffi.nim` @`6077eb7`) is
    keyed by **target module + event name**, with nothing specific to delivery.
  - The callback runs on the provider's thread, with `dataJson` a JSON array of the
    event's arguments.
  - The same seam works for `lp_client_create("storage_module", …)` +
    `"storageUploadDone"`. The foreign-thread `InboundQueue` pattern carries over as-is.
- **The events (`storage_module.lidl` 3.0.2).** `storageStart`, `storageStop`,
  `storageConnect`, `storageUploadProgress`, `storageUploadDone`,
  `storageDownloadProgress`, `storageDownloadDone`, `storageDownloadManifestDone`,
  `storageRemoveDone`. Each carries **one `tstr` argument that is itself a JSON
  document**, emitted through the codegen'd `emitEventImpl_`. `logoscore watch
  storage_module` showed them on the host bus:

  ```
  {"data":{"arg0":"{\"cid\":\"zDvZRwzkvrf…\",\"sessionId\":\"0\",\"success\":true}"},"event":"storageUploadDone",…}
  ```

  So Muster parses `args[0]` as JSON, as `received.nim` does for delivery.
- **Correlation (observed):**
  - An upload session id is a **node-wide counter** (`"0"`, `"1"`, `"2"`…).
  - A **download's session id is the CID itself**. `downloadToUrl` returned the CID, and
    every `storageDownloadProgress`/`Done` carried `"sessionId":"<cid>"`. Two consumers
    downloading the same CID at once (the package downloader and Muster, or two rooms)
    cannot tell their events apart. That makes U3 more pressing.

Not run: an actual `lp_subscribe` from a Nim plugin against `storage_module` (needs a
runner rebuild; S1).

## Q8. Which network does Basecamp 0.3.2's downloader start the shared node on?

**`logos.test`, with Mix on. Read in code at the pinned commits, and matched against
this machine's `~/.logos_storage/config.json` (read only).**

- **When the node starts.** `logos-package-downloader-module` @`7b0ca8b` has
  `storage_module` as an *optional* dependency. Its `start()` watches
  `modules_state`, and when `storage_module` is `ready` it calls `startStorageNode`
  (`src/storage_node.cpp`): `isRunning` → `loadConfigOrDefault` → `init(config)` →
  `start`. A failed `init` is read as "another consumer created the context". So the
  node starts as soon as the downloader runs, not on the first package.
- **The config.** `loadConfigOrDefault` (plugin @`7548f41`) is the persisted
  `~/.logos_storage/config.json`, or `{}` on a fresh install, put through the config
  migrations and `normalizeConfig`. From `{}` that gives:
  - `mix-enabled: true` (not a custom bootstrap);
  - `nat-schedule-interval: "60s"`;
  - no `network` key, so libstorage takes its `DefaultNetworkPreset = presets[0]` =
    **`logos.test`**;
  - `dht-mix-proxy` and `mix-pool-json` copied from the `logos.test` preset;
  - `data-dir: ~/.logos_storage/data`;
  - no listen port, so a **random** one;
  - `config-version: 3`.

  `init` then **writes the normalized config back** to `config.json`
  (`persistConfig`). That was observed with `HOME` redirected: the scratch
  `config.json` was rewritten with the caller's config.
- **On this machine.** `~/.logos_storage/config.json` holds exactly the defaults above:
  keys `config-version 3`, `data-dir`, `dht-mix-proxy` (the `logos.test` SPRs),
  `mix-enabled true`, `mix-pool-json` (`logos.test` relays, the first
  `16Uiu2HAm3xPbYz…` at 178.128.140.206:8070), `nat-schedule-interval 60s`. There is no
  `network` key, so `logos.test`.
- **How packages are downloaded.** `isPrivate = false` ("Packages never go over Mix")
  and `advertise = false` ("The node neither announces nor serves the packages it
  downloaded"). A Basecamp node seeds nothing by default, and a package URL is
  `logos:<network>:<cid>`, refused for another network (`StorageFetcher::canHandle`).
- **`network()` misleads on a private network (observed).** The module node started
  with `no-bootstrap-node: true` still answered `network()` → `"logos.test"`: the
  default preset's name, not the network it is on. Muster cannot record "the storage
  network" from `network()` alone (§9 "Storage network").

## What this changes in `docs/design/room-swarm.md`

1. **§3 "Direct dialing" is wrong as written.** A connected peer is never asked for a
   manifest. Only DHT providers are. "a room's seeders can serve each other with no DHT
   lookup at all" is false at v0.5.3. A fetch needs a DHT shared with the seeder. A seed
   event's `connect` still earns its place: it makes a DHT-found provider dialable when
   its announced address is not (hairpin, same LAN), because the dial reuses the
   connection.
2. **§5.4 step 1** becomes: connect to each seeder from the fold, *then* `downloadToUrl`.
   The download looks the CID up in the node's DHT, so on the shared Basecamp node the
   **CID is looked up on the public `logos.test` DHT every time**. Both the downloader's
   lookup and the seeders' provider records are public DHT traffic. A private network
   bootstrapped from a member's SPR would avoid that, but it needs a node Muster
   controls (U2).
3. **§5.5 "storage DHT" row** stands, and gets two additions:
   - provider records **outlive `unseed`** (`advertise=false`) until they expire, so the
     DHT keeps naming a past seeder;
   - the DHT lookup itself tells the DHT node(s) asked that this peer wants this CID.
4. **§5.4 step 3, "Private fetch":**
   - It works on the preset (`logos.test`/`logos.dev`) with the shared node's preset Mix
     config.
   - It runs at about **15 KB/s** (10 MB in ~11 min), so the UI must say so.
   - The CID goes through the preset's DHT-proxy nodes, not the room.
   - On a private network Muster would have to build a pool of at least four nodes and
     name a proxy, excluding the local node from its own pool. `storage_module` does
     neither.
5. **§5.5 / seed events (§5.3).** A seed event carrying `debug().addrs` carries only the
   **announced public address**. Two members behind one NAT cannot reach each other with
   it (no hairpin was observed here). Two members behind different home NATs: untested.
   A seeder is only useful once `debug().nat.reachability` is `Reachable` (2 min here),
   so `seed/<me>` should wait for it or say so.
6. **§5.1 `LpStorage`.**
   - Event payloads are a JSON string in `args[0]`.
   - A download's session id **is the CID**, so the package downloader and Muster, or
     two rooms, fetching the same CID at once share one event stream. Correlate by CID
     and expect foreign events (U3).
   - `init` rewrites `~/.logos_storage/config.json`. Muster must only ever attach to the
     shared node (U2).
7. **§6 asks.**
   - **U1** is confirmed necessary: the serve gate exists and is all-or-nothing.
   - **Add U6, fetch from named peers:** a download/manifest call that takes peer ids or
     SPRs and asks them directly (the block engine already broadcasts to connected
     peers; only `fetchManifest` insists on the DHT). Alternatively, a way to import a
     manifest block the caller supplies, since the room could carry the manifest bytes
     in `file/<fid>`.

     With U1 + U6 the room swarm needs no DHT at all, which is the private tracker done
     properly.
   - **U2** gains evidence: `network()` reports the default preset on a custom network.
   - **U4** stands: `tstr` is not a binary channel.
8. **§9 "Storage network" (open).** Recording "whatever the shared node is on" needs
   more than `network()`: the bootstrap set, or the SPRs a seed event carries, is what
   actually places a node.

## Open

- Two homes, two NATs: a seeder whose router offers no PCP/UPnP, a relay
  (`--nat-max-relays`), and a fetch between two members' houses.
- `uploadChunk` through a real `lp_invoke` from a Nim module (S1's runner), with a
  NUL and non-ASCII UTF-8 chunk, to pin down what `tstr` actually does carry.
- An `lp_subscribe` from Muster's plugin to `storageUploadDone` (S1).
- `storage_module.init` with a custom bootstrap plus an explicit Mix pool and proxy, to
  confirm the pass-through read in `syncMixConfig`.
