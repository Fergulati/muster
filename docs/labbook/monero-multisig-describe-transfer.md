# Monero multisig: does `describe_transfer` show what the co-signers sign? (exo-dcc.34)

**2026-10-16, monero-cli v0.18.5.1, a private regtest chain.** This answers question 1 of `docs/design/monero-multisig-coordination.md` §4. Rerun it with `infra/monero/multisig-regtest.py`.

## What ran

1. `monerod --regtest --offline --fixed-difficulty 1`, plus four `monero-wallet-rpc`: a funder, A, B and C.
2. Mine 120 blocks to the funder.
3. Make a 2-of-3:
   - `prepare_multisig {enable_multisig_experimental: true}` on each wallet;
   - `make_multisig` with threshold 2;
   - `exchange_multisig_keys` until `is_multisig` reads ready.
4. All three show the same address. Fund it with 5 XMR and mine 12 blocks.
5. Sync: each wallet runs `export_multisig_info`, and each imports the other two.
6. A builds `transfer` 1.23456789 XMR to a fresh address of the funder's, which returns a `multisig_txset`.
7. B and C each run `describe_transfer {multisig_txset}` on it, unsigned.
8. B runs `sign_multisig`. C runs `describe_transfer` on the signed set, then `submit_multisig`.
9. Mine 2 blocks, and read the destination's incoming transfers.

## What it showed

- **B's and C's wallets, on A's unsigned set,** both report:
  - one recipient, exactly the destination, at exactly 1 234 567 890 000 atomic units;
  - a fee of 1 808 400 000 and change of 3 763 623 710 000, with `amount_in` 5 XMR.
- **C's wallet, on B's signed set,** reports the same.
- **On chain:** the destination received exactly 1 234 567 890 000, in the submitted transaction.
- **The experimental flag:** `prepare_multisig` needs `enable_multisig_experimental: true` over RPC. Upstream's experimental flag is still live in v0.18.5.1.

## Why what it shows is what gets signed (from the source)

- **What `describe_transfer` reads:** for a `multisig_txset`, it reports from each pending transaction's `construction_data`: the sources, `splitted_dsts` and `change_dts` (`wallet_rpc_server.cpp`, `on_describe_transfer`).
- **What the co-signer signs:** `wallet2::sign_multisig_tx` does not sign the proposer's transaction as given. It rebuilds it from that same `construction_data`, through `multisig::signing::tx_builder_ringct_t::init` with `reconstruction = true` (`multisig_tx_builder_ringct.cpp`):
  - the output keys and amount commitments are recomputed from the destinations;
  - the proposer's range proofs must verify against those rebuilt commitments;
  - the inputs and outputs must balance with the fee;
  - the tx secret keys must re-derive from the proposer's seed.
- **So the two can't disagree:** a builder who put different destinations in the construction data would only get a signature on a transaction matching that data, which `describe_transfer` shows. A transaction set that doesn't match fails to rebuild.
- **wallet2 says the check is the caller's to make.** Its own comment: "the caller should further verify that the tx details are acceptable (inputs/outputs/memos/tx type)". That check is the room's design: each member's wallet compares the description with the agreed payment before signing.

**Not tested:** a deliberately tampered transaction set. The finding above rests on the source, read at master and v0.18. The scheme's experimental warning still stands.
