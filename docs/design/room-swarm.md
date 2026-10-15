# The room swarm: a private file swarm on Logos Storage, with the room as its tracker

Status: **planned 2026-10-15. Nothing built.** Epic `exo-4d0`: S0–S7 are `exo-4d0.1`–`.8` in the order of §7, and the upstream asks are
`exo-4d0.9`. `pb dep tree exo-4d0` shows live status; S0, S3 and the asks can start now.

## 1. Where this comes from

Asked what he wanted to see in Muster, Jarrad (Logos) said:

> I know Storage (Logos storage) was thinking of providing a simple storage peer network
> using delivery, because it offered a trusted bound, muster would actually be ideal for
> that, kinda like a mini private torrent tracker.

Muster has not used Logos Storage yet. F-17 has asked for it since the start ("artifacts …
content-addressed in Logos Storage, behind a storage interface"), and exo-dcc.14 (a room
outlives the fleet's store) needs somewhere durable to keep a room's log. This epic makes
Storage the first new platform stack Muster takes on since Monero, and makes it useful to
people on day one: **a room's members share files with each other, and seed them for each
other, and nobody outside the room can read them or tell what they are.**

## 2. The idea in one paragraph

A private BitTorrent tracker is three things: a membership list (who may take part), an
index (which files exist), and a peer list (who holds each one). The tracker is a server
that sees all three, and every member's IP besides. A Muster room already is the first
two, without a server: membership is the room's, epoch-keyed (invariant 7), and the room
log is an index nobody outside can read. So the room swarm adds the third, as log events,
and lets Logos Storage move the bytes. A member **shares** a file: Muster encrypts it
under a fresh key, uploads the ciphertext to their own storage node, and posts the CID and
the key into the room. Members who want it **fetch** it: Muster dials the storage peers
the room says hold it, downloads the ciphertext, decrypts it and checks it against the
digest the sharer committed. Anyone may then **seed** it, and says so in the room.
Storage moves opaque blobs; the room decides who can read them and who to ask for them.

## 3. What the platform gives us

`storage_module` 3.0.2 (atlas `stacks/storage.md`; source `logos-co/logos-storage-module`
@`7548f41`, engine `logos-storage/logos-storage-nim`). Bundled in Basecamp 0.3.2, in the
default catalogue, on all four platforms.

- **One node per host, shared.** In Basecamp the package downloader inits and starts it;
  `storage_ui` attaches to it. Config and data live in `~/.logos_storage/`, per OS user,
  not per Logos instance. A consumer must attach-or-create and **never stop or destroy a
  node it did not create**.
- **Upload** a file by path (`uploadUrl(path, chunkSize, advertise)`) and get a manifest
  CID from `storageUploadDone`. The manifest carries the **filename and mimetype in the
  clear**.
- **Download** by CID (`downloadManifest`, `downloadToUrl`, `downloadChunks`), with two
  flags: `isPrivate` tunnels the download and DHT lookups over Mix (KB/s), and `advertise`.
- **`advertise` is one bit for two things.** Read in `logos-storage-nim` @`d1f4f42`: when a
  dataset is not advertised, the node neither announces it to the DHT **nor answers for it**
  — `manifest/protocol.nim` returns NotFound and `blockexchange/engine/engine.nim` skips
  its presence in a peer's want-list. There is no "serve to these peers only".
- **Direct dialing.** `connect(peerId, addresses)` dials a peer without the DHT;
  `peerId()`, `spr()` and `debug().addrs` say how to reach this node. A connected peer
  receives want-list presence for advertised datasets, so in principle a room's seeders
  can serve each other with no DHT lookup at all (read in code, **unverified at runtime**:
  S0 answers it).
- **Events are host-wide.** Every subscriber sees every session's events (the
  downloader's, `storage_ui`'s); correlate by `sessionId` / `cid`. `fetch` has no
  completion event. `uploadChunk` declares its chunk as `tstr`; binary safety over IPC is
  unverified, so prefer `uploadUrl` with a file on disk.
- **Networks.** Presets `logos.test` (default) and `logos.dev`, or a private network from a
  first node's SPR (`no-bootstrap-node`). The storage network is independent of the
  delivery fleet Muster's room rides.

## 4. Private tracker, piece by piece

| | A private BitTorrent tracker | The room swarm |
|---|---|---|
| Who may take part | an account on the tracker's site | the room's members, admitted by a member, epoch-keyed |
| The index | the tracker's database, readable by its operator | `file/…` events in the room log, sealed to the room |
| Who holds what | the tracker's peer list, built from every client's announce: IP, port, infohash, bytes up and down | `seed/…` events, each signed by the member who seeds (invariant 9): their storage peer id and addresses |
| The secret | a passkey in every announce URL; it leaks with the `.torrent` | the room's epoch keys and a key per file; the file names no secret |
| Peer discovery | the tracker only; DHT and PEX off by the private flag | the room's seed events, then a direct `connect`; the storage DHT still sees the ciphertext CID while `advertise` is one bit (§6, ask U1) |
| What a stranger with the hash gets | the plaintext pieces, if they reach a peer | ciphertext; the key is only in the room |
| A late joiner | the whole catalogue | files shared from their epoch on; earlier ones only if a member shares them again (invariant 7) |
| Ratio | enforced by the tracker from self-reported stats | not enforced. Muster cannot see bytes served. Pledges (S7) are motivational and say so |
| The server | the tracker, a single point to seize or subpoena | none (invariant 8). The delivery store node and storage peers are untrusted infrastructure |

The education angle writes itself: every row of this table is a step the walkthrough can
show truthfully, with the observer who sees it.

## 5. The design

### 5.1 The storage seam (F-17)

`module/src/storage/` gets a seam in the shape of `Transport`:

- `BlobStore` — `put(path): Cid` (async), `get(cid, dest, private)` (async, with
  progress), `has(cid)`, `setServing(cid, on)`, `remove(cid)`, `reach(): PeerReach`
  (peer id, addresses, network), `connect(PeerReach)`.
- `LocalBlobStore` — a content-addressed directory, and a pair of them that serve each
  other in process. It is the stub every integration test uses ("never mock `Transport`"
  applies here too: tests run on the local store, not a mock).
- `LpStorage` — `storage_module` over `lp_*`, compiled only into the plugin (like
  `monero_backend_lp.nim`). Attach-or-create exactly as the atlas says; events through the
  `inbound_queue` seam, matched by `sessionId`; the module thread never waits on storage
  (the cmPump / cmNow split `monero_backend_lp` uses).
- `storage_module` becomes an **optional** dependency of `muster_module`, graded by
  `module_registry` in three states, with Basecamp's `packages.install` as the remedy,
  exactly as `monero_wallet_backend` is (exo-dcc.10). The room works without it; the
  Files panel says what is missing.

### 5.2 Sealed blobs

`module/src/crypto/blob_seal.nim`, on the libsodium Muster already links:

- A fresh 32-byte key per file; `crypto_secretstream_xchacha20poly1305`, so a large file
  is sealed and opened in chunks without holding it in memory.
- The plaintext digest is a domain-separated hash-input record (`muster.blob.plaintext.v1`,
  invariant 5). After a download Muster opens the ciphertext and **refuses the file if the
  digest differs**, whatever the storage layer said about its own Merkle tree.
- The ciphertext is uploaded from a temp file with a **neutral name** (`<random>.bin`), so
  the storage manifest's cleartext filename and mimetype say nothing.
- Optional padding to a size bucket (Padmé), off by default, because ciphertext size is
  otherwise plaintext size plus a constant (a disclosure row says so).

### 5.3 The room is the tracker (log events)

All sealed to the room under the epoch key like every event; the author-bearing ones join
the `authorship.nim` list, so a forgery is dropped from the room's view (exo-f76).

| Key | Author-signed | Body |
|---|---|---|
| `file/<fid>` | the sharer | name, size, mime, plaintext digest, ciphertext CID, file key, storage network |
| `file/<fid>/seed/<who>` | the seeder | storage peer id, addresses, network, until (optional) |
| `file/<fid>/unseed/<who>` | the seeder | — |
| `file/<fid>/retract` | the sharer only | — (hides it from the panel; it cannot unshare what members already hold, and says so) |

`fid` is the content id of the share event. `reduceSwarm(roomEvents(s))` folds them into
files and their seeders: order-free, idempotent (invariant 4), and a seeder appears only
because they announced (invariant 9). Muster never infers a holder from the storage node's
own peer table.

A late joiner (invariant 7) sees no `file/…` event from an earlier epoch, so they have
neither the CID nor the key. A member may share an earlier file again into the current
epoch; that is a new `file/…` event carrying the same CID and key, the member disclosing
what they legitimately hold. Removing a member re-keys forward but cannot take back keys
they already had; the panel says so.

Nothing here is signed for a chain, so invariants 1, 2 and 10 do not bind a plain share.
When a file is attached to an intent (an invoice on a split, §7 S8), its digest enters the
effect and F-20 classes it as an external read at its log position.

### 5.4 Fetching and seeding

1. Read the file's seeders from the fold. `connect` to each (direct dial, the room as
   PEX), then `downloadToUrl` the ciphertext into the instance's temp directory.
2. Open it, check the digest, write the plaintext where the person chose. A mismatch is a
   refusal naming the sharer and the CID, never a partial file.
3. If the person keeps seeding (the default, §9), post `seed/<me>` and leave
   the dataset advertised. "Private fetch" (a per-file choice): `isPrivate=true`,
   `advertise=false`, no seed event — the fetch goes over Mix and this member serves
   nothing afterwards.
4. A pump on the intents tick drives progress, retries other seeders, and re-announces
   when this node's addresses change.

### 5.5 Who sees what

Two new observer classes in `intents/disclosure.nim`, and the rows `flow.nim` shows:

| Observer | Sees | Never sees |
|---|---|---|
| room member | file name, size, sharer; each seeder by name with their storage peer id and **addresses (IP)** | — |
| store node (delivery) | that the room's topic carried an envelope, when, and its size (FS-9) | the file, its CID, who shared it |
| storage peer (new) | the peer id and IP of a node fetching or serving a ciphertext CID, and when | the plaintext, the name, the room |
| storage DHT (new) | the ciphertext CID and the set of peer ids providing it (while `advertise` is one bit) — so the seeders of one blob are linkable to each other, by peer id | the plaintext, the name, the room, who in the room they are |
| mix node | with private fetch, a hop of a tunnelled download | the endpoints together |

The claims registry (ADR-012) gets the matching entries with credibility: content
confidentiality **imperative**; seeder IPs to room members and to storage peers
**exposed**; "only room members can fetch the ciphertext" a **gap** until ask U1 lands.

## 6. Asks of the Storage team

Jarrad says Storage was already thinking about a delivery-bounded peer network. These are
what would make the room swarm the thing they had in mind rather than a workaround. U1 is
the one that matters.

- **U1 — serve without announcing, to a set of peers.** Split `advertise` into *announce*
  (DHT) and *serve*, and let *serve* take an allowlist of peer ids (or an SPR set).
  Muster fills the list from the room's seed events. Then a room's blobs never touch the
  DHT, and a stranger with the CID gets NotFound. This is the private tracker's private
  flag, done properly.
- **U2 — a node per consumer, or a namespace.** One shared node and one
  `~/.logos_storage/config.json` mean Muster's choices (network, quota, Mix) are whatever
  the downloader picked, and Muster's `init` would rewrite everyone's config.
- **U3 — events addressed to their caller**, or at least a caller id on each, so a module
  does not parse other modules' sessions.
- **U4 — `fetch` completion**, and `uploadChunk` as `bstr`.
- **U5 — a manifest with no filename/mimetype** (or caller-set), so an upload does not
  need a temp-file rename to stay quiet.

## 7. Order of work

Each slice's acceptance criteria become a test before its implementation (working
agreement). S3's spec goes through `discuss-issue` first.

- **S0 — Ground truth (spike, no Muster code).** Two storage nodes on a private network and
  on `logos.dev`: does a directly connected seeder serve a fresh downloader with no DHT
  provider record, and how fast; does `isPrivate` work against a `connect`ed peer; what
  happens across two home NATs; what network the downloader inits the shared node on in
  Basecamp 0.3.2; does `uploadChunk` carry binary intact; can a Nim module subscribe to
  `storageUploadDone` over `lp_*`. Labbook `docs/labbook/storage-from-muster.md`.
- **S1 — The storage seam.** `BlobStore`, `LocalBlobStore`, `LpStorage`; optional
  dependency, three-state readiness, install remedy. **Needs a runner rebuild** to bundle
  `storage_module` (ask first: `make build` is memory-capped and froze a workstation once).
- **S2 — Sealed blobs.** `blob_seal.nim` with a round-trip test, a tamper test, a probe
  that the uploaded manifest names nothing.
- **S3 — The room as tracker.** The four event kinds, `reduceSwarm`, authorship. Spec
  `derived-exo-4d0.4` with probes: the fold is order-free and idempotent; a seeder is listed
  only by their own signed announce; a forged announce is dropped; a later-epoch member
  holds no key to an earlier file; a digest mismatch refuses.
- **S4 — Hosted surface.** `muster.lidl`: `swarm_share`, `swarm_files`, `swarm_fetch`,
  `swarm_seed`, `swarm_status`; the pump; the disclosure rows and observers.
  `swarm_local_test` over two `LocalBlobStore`s and `LocalTransport`.
- **S5 — The Files panel** (a placeholder name, §9). In the room: share (file picker), the list (sharer, size,
  seeders by name), Fetch / Private fetch / Seed, progress, a mismatch refusal; the
  who-sees-what box from §5.5. `scripts/swarm-self-test.sh`: two runners offscreen, a
  private storage network of their own, share → fetch → seed → a third fetches from the
  second with the first gone. Then on display in Basecamp 0.3.2 against the bundled node.
- **S6 — The lesson.** Walkthrough steps and claims-registry entries built from §4 and
  §5.5: what a private tracker's operator sees, what the room's infrastructure sees.
- **S7 — Pledges (decide after S5).** "Keep this available until T" as an intent with a
  no-chain driver (locus `each`): each pledger agrees with their room key; any member who
  holds the file can spot-check a pledger by asking for the hash of a random range. Graded
  motivational in the claims registry: Muster cannot make anyone keep bytes.
- **S8 — Later, each its own decision.** (a) Room log backup: members upload the room's
  sealed envelopes (already per-epoch ciphertext) as a dataset and keep its CID beside
  `joined_rooms`, so a room outlives the fleet's store (exo-dcc.14). (b) Files on cards:
  an invoice attached to a split, its digest in the effect, F-20's external read. (c) Ask
  U1 adopted once Storage ships it: the DHT rows in §5.5 go away.

## 8. Invariants, checked

| # | How the swarm keeps it |
|---|---|
| 3 | No plugin involvement; the core seals and fetches. |
| 4 | Files and seeders are `reduceSwarm(log)`. Blobs are referenced by CID + key in the log; a local copy is a cache, rebuilt by fetching. |
| 5 | Every event body is dCBOR; the plaintext digest is a hash-input record. |
| 7 | File keys travel in events sealed to the epoch they were shared in. |
| 8 | Storage nodes, the DHT and Mix are untrusted infrastructure; no server of ours. |
| 9 | A seeder is named only by their own signed announce; the panel grades only your own holdings. |
| 10 | A plain share signs nothing for a chain; an attachment enters an effect as an external read (S8b). |

## 9. Decisions

Decided 2026-10-15 by the operator:

- **Seeding after a fetch is on by default.** A member can choose a private fetch instead
  (§5.4 step 3): over Mix, nothing served afterwards, no seed event.
- **Seed events carry the seeder's network addresses** for now. Storage's own privacy
  features (Mix-routed serving, ask U1) come later and change the §5.5 rows when they do.

Still open:

- **Feature name** in the UI. "Files" is a placeholder; the operator wants something
  better. The code says *swarm* (the mechanism), so renaming the panel costs nothing.
- **Storage network**: whatever the shared node is on, recorded per share and per seed
  event so a mismatch is shown, not guessed (proposed until U2).
