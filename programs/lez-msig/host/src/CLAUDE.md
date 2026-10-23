# programs/lez-msig/host/src/

`msig_host`: the client on LEZ v0.3.
- `lib.rs`: `Msig`, one multisig at its placement (a public PDA, or a private PDA whose keys come
  from the group's master secret). It builds rows and envelopes from the core instruction, so host
  and guest agree by construction. It builds public and privacy-preserving transactions, and
  decrypts the multisig's new note.
- `bin/msig_bench.rs`: RFP P.1/P.2 with real proving (it refuses `RISC0_DEV_MODE`).
- `bin/msig_vectors.rs`: ground truth for muster's Nim port (`module/tests/vectors/lez-msig`).
