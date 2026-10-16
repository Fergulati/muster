# infra/monero/

A private Monero regtest chain for experiments that need XMR but no real funds. Coins are mined locally (`monerod --regtest --offline --fixed-difficulty 1`), so nothing is funded from outside.

- `multisig-regtest.py` runs a 2-of-3 multisig end to end with monero-wallet-rpc (exo-dcc.34): make, fund, sync, build, `describe_transfer`, sign, submit. It writes `report.json` into `$XMRMS_DIR`. Binaries come from `nix build nixpkgs#monero-cli`.

Rules:
- This is a lab, not Muster's runtime. Muster holds no Monero key (ADR-018). The wallets here belong to the experiment and are wiped on every run.
- Ports are 38080–38094 on 127.0.0.1. The chain and wallets go under `$XMRMS_DIR`, which defaults to `/tmp/muster-xmr-multisig-regtest`.
