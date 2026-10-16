# Monero multisig, coordinated in the room (exo-dcc.34)

Status: **candidate, 2026-10-16. Not built; a decision (a new ADR) comes first.** The atlas lists it as family `monero.multisig-coordinated`, with declared actions `setup` and `spend` (`contracts/actions/family/monero.multisig-coordinated.json`).

## 1. Why this note exists

`monero.multisig` stays `reject`. ADR-018 gives four reasons:
- Upstream calls the scheme experimental and warns a malicious member can steal funds.
- Basecamp's Monero wallet stack exposes no multisig, so Muster would have to run its own wallet2 as a second key holder.
- It fights invariant 2: a signature has no expiry.
- It fights invariant 4: each wallet keeps secret sync state.

We re-assessed on 2026-10-16 against three sources: Monero's multisig docs, the Multisig Messaging System (MMS) guide, and monero-multisig-gui. The rejection holds; the docs' warning is unchanged since the 2022 fixes (PR 8149).

The two tools point at a different role for Muster. The hard part of Monero multisig is coordination: passing setup data, sync blobs and partly signed transaction sets between people, in order and privately.
- **MMS** (2018) carries them over PyBitmessage.
- **monero-multisig-gui** (2025) embeds wallet2, so it holds the keys itself, and runs one HTTP API per peer over Tor onion services.

A Muster room is already an end-to-end encrypted channel among authenticated members. This note is the case for **the room as the coordination layer, with each member's own multisig wallet holding the keys.**

## 2. The shape

The on-chain scheme is the same as `monero.multisig`; only Muster's role differs. It mirrors seam S8, the Bitcoin "sign outside Muster" PSBT path.

- **Keys.** Each member runs their own Monero multisig wallet: `monero-wallet-cli` or `monero-wallet-rpc`, monero-multisig-gui, or the platform's once `monero_wallet_backend` exposes multisig (§5).
  - Muster holds no key and no multisig state.
  - That is why this variant does not hit ADR-018's second-key-holder objection.
- **Setup.** The room agrees on the network, M and the N members. Each wallet then runs:
  - `prepare_multisig`;
  - `make_multisig`;
  - `exchange_multisig_keys`, once or twice.

  The room carries each round's output to the others, in order, and records who sent it. Setup ends when all N wallets show, and disclose, the same address.
- **Spend.**
  1. The room agrees the payment first: recipients, amounts and a fee cap.
  2. The signers' wallets re-sync with `export_multisig_info` and `import_multisig_info`, with the room carrying the blobs.
  3. One wallet builds the transaction set (`transfer`).
  4. Each signer's wallet runs `describe_transfer` on the set and signs with `sign_multisig` only if the recipients and amounts are the agreed ones. `describe_transfer` takes a `multisig_txset`, per the wallet RPC docs.
  5. Any wallet submits it with `submit_multisig`.
  6. One spend at a time.
- **Invariant 1** moves into the member's wallet. Muster cannot decode a Monero transaction set without view keys, so each member's own wallet does the "re-derive and refuse on mismatch" check. This is the same way the payee's wallet confirms receipt in `monero.split`.

## 3. What it cannot fix

- **The warning.** A malicious member may be able to steal funds. Stagenet only, with the warning on the card, until upstream drops it.
- **Serial spends.** Every spend needs a fresh sync, and the docs say "only do it for 1 transaction at a time". The card shows one spend in flight.
- **No expiry.** This is invariant 2: a collected partial signature stays usable until the inputs are spent. The room can only bound it socially: an agreed deadline, and re-syncing after a cancel invalidates stale sets.
- **Membership change** means a new wallet and moving the funds.

## 4. Open questions for the ADR

1. ~~Does `describe_transfer` on a part-signed `multisig_txset` report what the signers will sign?~~ **Answered 2026-10-16: yes.** On a regtest 2-of-3 with monero-wallet-rpc v0.18.5.1, both co-signers' wallets reported exactly the agreed recipient, amount, fee and change, unsigned and signed, and the chain paid exactly that. From the source, a co-signer signs a transaction rebuilt from the same construction data `describe_transfer` reads (`docs/labbook/monero-multisig-describe-transfer.md`, `infra/monero/multisig-regtest.py`). Still untested: monero-multisig-gui's sets, and a deliberately tampered set.
2. What file and blob sizes and timings does the room carry? The room is a store-backed log, and the sync blobs grow with the number of outputs.
3. The members run their own wallet software, outside Basecamp, until the platform exposes multisig. Is that acceptable for the campaign?
4. Does FCMP++ change the multisig steps enough to wait for it?

## 5. Upstream

A feature request ([logos-co/logos-monero-wallet-backend#8](https://github.com/logos-co/logos-monero-wallet-backend/issues/8), filed 2026-10-16) asks Logos to expose multisig in `monero_wallet_backend`, gated like sends: the approver role, with a review in the wallet app. Muster would then use the platform's wallet, as it does for `monero.split`, and would not need people to bring their own.
