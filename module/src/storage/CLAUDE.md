# module/src/storage/

The storage seam (F-17), for the room swarm (epic exo-4d0, `docs/design/room-swarm.md`).
Muster codes against `BlobStore`, never against `storage_module`.

- `blob_store.nim`: the `BlobStore` seam and `LocalBlobStore`, the in-process stand-in every
  integration test runs on (never a mock). It behaves as `storage_module` 3.0.2 does where
  the swarm depends on it: one bit for served-and-announced, connected peers then the DHT,
  a private download hides the fetcher. It records what a server and the DHT observed, so
  disclosure rows can be checked against it.
- `LpStorage` (next, exo-4d0.2): `storage_module` over `lp_*`, compiled only into the plugin.

Rules:
- Bytes here are opaque. The swarm seals a file before it is uploaded
  (`crypto/blob_seal.nim`); nothing in this directory sees a key or a plaintext.
- The host's storage node is shared (the package downloader starts it). Attach to it;
  never stop or destroy a node Muster did not create.
- Every call that waits on the network is a job read after `poll`; the module thread
  never waits on storage.
- Where `LocalBlobStore` and the platform differ, the platform wins: fix the stand-in, and
  record the finding in `docs/labbook/storage-from-muster.md`.
