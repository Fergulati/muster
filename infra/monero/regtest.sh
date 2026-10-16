#!/usr/bin/env bash
# A private Monero regtest chain and wallet RPCs for the xmr-msig e2e test (exo-dcc.34).
#   infra/monero/regtest.sh up [N]   # monerod on :38081, N monero-wallet-rpc on :38091.. (default 4)
#   infra/monero/regtest.sh down
# A FRESH chain each `up` (the data dir is wiped). Coins are mined locally with the daemon's
# generateblocks; nothing is funded from outside. Binaries from nixpkgs#monero-cli.
set -uo pipefail
D="${XMR_REGTEST_DIR:-/tmp/muster-xmr-regtest}"
P="${MONERO_CLI:-$(nix build nixpkgs#monero-cli --no-link --print-out-paths 2>/dev/null)}"
case "${1:-}" in
  up)
    N="${2:-4}"
    "$0" down >/dev/null 2>&1
    rm -rf "$D"; mkdir -p "$D/chain" "$D/wallets"
    setsid "$P/bin/monerod" --regtest --offline --fixed-difficulty 1 --data-dir "$D/chain" \
      --rpc-bind-port 38081 --p2p-bind-port 38080 --no-zmq --non-interactive --log-level 0 \
      > "$D/monerod.log" 2>&1 < /dev/null & echo $! > "$D/pids"
    for i in $(seq 1 "$N"); do
      setsid "$P/bin/monero-wallet-rpc" --daemon-address 127.0.0.1:38081 --rpc-bind-port $((38090 + i)) \
        --disable-rpc-login --wallet-dir "$D/wallets" --allow-mismatched-daemon-version --trusted-daemon \
        --log-level 0 > "$D/wallet-$i.log" 2>&1 < /dev/null & echo $! >> "$D/pids"
    done
    for i in $(seq 1 60); do
      curl -s -m 2 -o /dev/null -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' http://127.0.0.1:38081/json_rpc && break
      sleep 1
    done
    echo "monerod :38081, wallet RPCs :38091..:$((38090 + N)) in $D" ;;
  down)
    [ -f "$D/pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$D/pids"
    rm -f "$D/pids"; echo "stopped" ;;
  *) echo "usage: $0 up [N] | down"; exit 2 ;;
esac
