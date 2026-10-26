# lez-msig benchmarks (RFP-005 P.1, P.2)

Real proving only: `msig_bench` refuses `RISC0_DEV_MODE`. Reproduce with:

```
cd programs/lez-msig
cargo run --release -p msig_host --bin msig_bench -- 1 3 5 10
```

For each M, it runs these steps on LEE's own v0.3 state machine (LEZ v0.3.0, risc0-zkvm 3.0.5,
the local CPU prover):

- create a multisig of max(M, 3) members with threshold M, over a group-owned **private** PDA;
- fund it with a shield from a public account;
- pay a public recipient with exactly M BIP-340 approvals. That is ONE privacy-preserving
  transaction, and the program verifies all M signatures inside its proof.

Every transaction below was accepted by the state machine.

## 2026-10-23: AMD EPYC, 64 cores, 503 GB. The guest uses RISC Zero's accelerated k256

The machine was shared: Nim builds and a local sequencer ran alongside. Treat these as upper
bounds.

| M | step | prove (s) | tx size (bytes) |
|---|---|---|---|
| 1 | create (3 members) | 129.6 | 227,751 |
| 1 | fund (shield, native only) | 91.9 | 227,976 |
| 1 | **execute: pay, 1 signature** | **150.7** | 228,010 |
| 3 | **execute: pay, 3 signatures** | **171.5** | 228,010 |
| 5 | create (5 members) | 128.6 | 227,751 |
| 5 | **execute: pay, 5 signatures** | **208.5** | 228,010 |
| 10 | create (10 members) | 140.1 | 227,751 |
| 10 | **execute: pay, 10 signatures** | **288.1** | 228,010 |

Peak resident memory: 9.6 GB. The whole run took 28 min 40 s.

The same 1-signature payment with stock (unaccelerated) k256 took **439.0 s**. Acceleration
cuts it by 2.9×.

## What the numbers say

- **P.2 (approval verification as a function of M).**
  - Each further approval adds about 15 s of proving. A fit through M = 1–10 gives roughly
    136 s + 15 s · M.
  - **M ≥ 5 is viable:** M = 5 proves in 3.5 minutes.
  - A private transaction has no cycle cap, and the transaction does not grow with M (below),
    so the ceiling is the members limit (32), not the block. At about 15 s per signature,
    M = 32 is extrapolated at about 10.5 minutes; it has not been measured.
- **P.1 (transaction size).** Every private transaction is about 228 KB: the succinct proof,
  plus notes padded to a fixed size. It does not grow with M, because the approvals are
  inside the proof. About 4 fit in a 1 MiB block (LEZ PR #949's own count).
- **Compute.** Private transactions are not metered on v0.3, and are fee-exempt there; PR #949
  would charge them.
- **The public posture.** These figures do not apply to it: the sequencer executes the program
  without proving.
