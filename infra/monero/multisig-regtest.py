#!/usr/bin/env python3
"""A 2-of-3 Monero multisig on a private regtest chain, end to end (exo-dcc.34).

Answers the design note's first open question (docs/design/monero-multisig-coordination.md
§4): does describe_transfer on a multisig transaction set report what the co-signers will
sign? It starts monerod --regtest --offline and four monero-wallet-rpc (a funder, A, B, C),
mines coins, makes the 2-of-3 (prepare, make, exchange until ready), funds it, syncs the
members' multisig info, has A build a transfer, has B and C describe it unsigned, B sign,
C describe the signed set and submit it, and checks the destination received exactly the
amount. Writes report.json into $XMRMS_DIR. No funds: regtest coins are mined locally.

  P=$(nix build nixpkgs#monero-cli --no-link --print-out-paths)
  python3 infra/monero/multisig-regtest.py "$P"

Ports 38080-38094 on 127.0.0.1. Labbook: docs/labbook/monero-multisig-describe-transfer.md.
"""
import json, os, subprocess, sys, time, urllib.request, shutil
P = sys.argv[1]; W = os.environ.get("XMRMS_DIR", "/tmp/muster-xmr-multisig-regtest")
for d in ["chain", "wallets"]: shutil.rmtree(f"{W}/{d}", ignore_errors=True); os.makedirs(f"{W}/{d}")
procs = []
def start(args, log):
    procs.append(subprocess.Popen(args, stdout=open(f"{W}/{log}", "w"), stderr=subprocess.STDOUT))
def rpc(port, method, params=None, path="json_rpc"):
    body = json.dumps({"jsonrpc": "2.0", "id": "0", "method": method, "params": params or {}}).encode()
    for _ in range(60):
        try:
            r = json.loads(urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}/{path}", body,
                            {"Content-Type": "application/json"}), timeout=120).read())
            return r
        except Exception as e:
            time.sleep(1)
    raise SystemExit(f"rpc {port} {method} unreachable")
def ok(r, what):
    if "error" in r: raise SystemExit(f"{what}: {r['error']}")
    return r["result"]
try:
    start([f"{P}/bin/monerod", "--regtest", "--offline", "--fixed-difficulty", "1", "--data-dir", f"{W}/chain",
           "--rpc-bind-port", "38081", "--p2p-bind-port", "38080", "--no-zmq", "--non-interactive", "--log-level", "0"], "monerod.log")
    ports = {"F": 38091, "A": 38092, "B": 38093, "C": 38094}
    for n, port in ports.items():
        start([f"{P}/bin/monero-wallet-rpc", "--daemon-address", "127.0.0.1:38081", "--rpc-bind-port", str(port),
               "--disable-rpc-login", "--wallet-dir", f"{W}/wallets", "--allow-mismatched-daemon-version",
               "--trusted-daemon", "--log-level", "0"], f"wallet-{n}.log")
    time.sleep(3)
    for n, port in ports.items():
        ok(rpc(port, "create_wallet", {"filename": n, "language": "English"}), f"create {n}")
    F = ok(rpc(ports["F"], "get_address"), "F addr")["address"]
    ok(rpc(38081, "generateblocks", {"amount_of_blocks": 120, "wallet_address": F}), "mine")
    # multisig 2-of-3: prepare, make, exchange until ready
    infos = {n: ok(rpc(ports[n], "prepare_multisig", {"enable_multisig_experimental": True}), f"prepare {n}")["multisig_info"] for n in "ABC"}
    print("prepare ok")
    stage = {}
    for n in "ABC":
        others = [infos[m] for m in "ABC" if m != n]
        stage[n] = ok(rpc(ports[n], "make_multisig", {"multisig_info": others, "threshold": 2, "password": ""}), f"make {n}")
    rnd = {n: stage[n]["multisig_info"] for n in "ABC"}
    for k in range(4):
        st = {n: ok(rpc(ports[n], "is_multisig"), "is_multisig") for n in "ABC"}
        if all(s.get("ready") for s in st.values()): break
        nxt = {}
        for n in "ABC":
            others = [rnd[m] for m in "ABC" if m != n]
            r = ok(rpc(ports[n], "exchange_multisig_keys", {"multisig_info": others, "password": ""}), f"exchange {n} round {k}")
            nxt[n] = r.get("multisig_info", "")
        rnd = nxt
    st = {n: ok(rpc(ports[n], "is_multisig"), "is_multisig") for n in "ABC"}
    print("multisig:", {n: (s["multisig"], s["ready"], s["threshold"], s["total"]) for n, s in st.items()})
    addrs = {n: ok(rpc(ports[n], "get_address"), "addr")["address"] for n in "ABC"}
    assert len(set(addrs.values())) == 1, addrs
    MS = addrs["A"]; print("multisig address", MS[:16] + "…")
    # fund it
    ok(rpc(ports["F"], "refresh"), "F refresh")
    ok(rpc(ports["F"], "transfer", {"destinations": [{"amount": 5_000_000_000_000, "address": MS}]}), "fund")
    ok(rpc(38081, "generateblocks", {"amount_of_blocks": 12, "wallet_address": F}), "confirm fund")
    for n in "ABC": ok(rpc(ports[n], "refresh"), f"refresh {n}")
    print("balances:", {n: ok(rpc(ports[n], "get_balance"), "bal")["unlocked_balance"] for n in "ABC"})
    # sync partial key images
    ex = {n: ok(rpc(ports[n], "export_multisig_info"), f"export {n}")["info"] for n in "ABC"}
    for n in "ABC":
        ok(rpc(ports[n], "import_multisig_info", {"info": [ex[m] for m in "ABC" if m != n]}), f"import {n}")
    # a destination: a fresh wallet address of F's
    D = ok(rpc(ports["F"], "create_address", {"account_index": 0}), "dest")["address"]
    AMT = 1_234_567_890_000
    t = ok(rpc(ports["A"], "transfer", {"destinations": [{"amount": AMT, "address": D}], "get_tx_metadata": True}), "A transfer")
    txset = t["multisig_txset"]; print("A built: amount", t.get("amount"), "fee", t.get("fee"), "txset bytes", len(txset) // 2)
    report = {}
    for n in "BC":
        d = rpc(ports[n], "describe_transfer", {"multisig_txset": txset})
        report[f"describe_by_{n}_unsigned"] = d.get("result", d.get("error"))
    s = ok(rpc(ports["B"], "sign_multisig", {"tx_data_hex": txset}), "B sign")
    print("B signed; tx_hash_list", s.get("tx_hash_list"))
    signed = s["tx_data_hex"]
    d = rpc(ports["C"], "describe_transfer", {"multisig_txset": signed})
    report["describe_by_C_signed"] = d.get("result", d.get("error"))
    sub = ok(rpc(ports["C"], "submit_multisig", {"tx_data_hex": signed}), "C submit")
    print("submitted", sub["tx_hash_list"])
    ok(rpc(38081, "generateblocks", {"amount_of_blocks": 2, "wallet_address": F}), "mine")
    ok(rpc(ports["F"], "refresh"), "F refresh")
    inc = ok(rpc(ports["F"], "get_transfers", {"in": True}), "F transfers")
    got = [x for x in inc.get("in", []) if x["txid"] in sub["tx_hash_list"]]
    report["destination_received"] = [(x["amount"], x["address"] == D) for x in got]
    report["expected"] = {"address": D, "amount": AMT}
    json.dump(report, open(f"{W}/report.json", "w"), indent=1)
    print("REPORT written")
finally:
    for p in procs: p.terminate()
    time.sleep(2)
    for p in procs:
        try: p.kill()
        except Exception: pass
