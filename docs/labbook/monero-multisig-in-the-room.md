# Monero multisig in the room: traps found building it (exo-dcc.34)

**2026-10-16.** ADR-020's S1–S3, built against Monero v0.18.5.1 `monero-wallet-rpc` on a private regtest chain (`infra/monero/regtest.sh`). Design: `docs/design/monero-multisig-coordination.md`.

## 1. The room lowercased the account's address

`coordination/accounts.nim` keyed every disclosed account by its address in lowercase, from the EVM era, where that is harmless. Monero's base58 is case-sensitive, so the lowercased string is a different address, or no address at all. Its checksum fails, so the account folded as nothing.

**Fix:** `normAddress` keeps the case on a `monero:` chain and lowercases every other chain as before, so existing disclosures keep their bytes. Held by `xmr_msig_setup_test` §3.

## 2. A wallet that ran a round the room never saw cannot be resumed

If a member's client crashes between the wallet call (`make_multisig`, `exchange_multisig_keys`) and publishing its output, the wallet has advanced and the room has not. wallet-rpc has no call that re-exports a past round's message.

**Fix:** the step reads the wallet's state first and refuses ("the wallet advanced past the room; use a fresh wallet"). It never re-runs the call. The member starts again with a fresh, empty wallet. `prepare_multisig` is the exception: it is safe to repeat.

## 3. "Earlier" is the log's canonical order, not the order things were sent

One spend per wallet is in flight at a time, so a second agreed spend waits. Which one goes first is decided by the log's canonical order, the same for every member. That is not the order the proposals were published in. The first version of the test assumed publish order, and failed.

## 4. The intents tick would have sent round 2 as a plain signature

`liveNextRounds` contributes a member's later rounds for them, re-signing the materialization in-app as their first approval was. For xmr-msig, round 2 must be signed under the round-2 tag, and only after the member's wallet has signed. A plain re-signature would be rejected by every fold, or, if the tag were dropped, would let anyone replay a member's public round-1 signature as round 2.

**Fix:** `Driver.laterRoundsInApp` defaults to true. The xmr-msig driver says false, and its round 2 is published only by the spend's own step (`xmr_msig_spend.roundTwo`).

## 5. Fakes need real curve points

`monero/address.parseAddress` checks that both keys are valid Ed25519 points, as wallet2's `check_address` does. A fake wallet that hashes a seed straight into "keys" makes addresses that every check refuses. Like `fake_monero.nim`, `fake_xmr_msig.nim` derives its keys as Ed25519 public keys from a hashed seed.

## 6. Numbers from the regtest runs

- **Setup:** a 2-of-3 is ready after `prepare`, `make` and two `exchange` rounds. Over the room that took five steps of every member (`xmr_msig_setup_regtest_e2e`).
- **A spend:** agreeing, syncing, building, checking, signing and submitting took four to five steps, then 10 blocks to final.
- **The experimental flag:** wallet-rpc v0.18.5.1 refuses `prepare_multisig` unless it is called with `enable_multisig_experimental: true`. Muster passes it explicitly, and the room says why.
