## The Bitcoin address a member pays a split from (exo-408 item 12): wpkh(<their muster
## key>) on each network, the address their own node must hold coins at. Before this no
## screen showed it, only the key.
##   1. the address per network, pinned to BIP-173's own vectors for the generator key
##   2. one row per network, each with its own CAIP-2 chain and bech32 prefix
## Pure: no keystore, no node.

import std/[strutils, sequtils]
import ../src/bitcoin/script
import ../src/bitcoin/network

proc unhex(h: string): seq[byte] =
  for i in countup(0, h.len - 1, 2): result.add byte(parseHexInt(h[i .. i + 1]))

let g = unhex("0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")

block:
  let rows = payerAddresses(g)
  let byName = proc(n: string): string =
    for r in rows: (if r.network == n: return r.address)
  doAssert byName("mainnet") == "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4", byName("mainnet")
  doAssert byName("testnet") == "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", byName("testnet")
  echo "1. the payer address per network matches BIP-173's vectors OK"

block:
  let rows = payerAddresses(g)
  doAssert rows.len == Networks.len
  for n in Networks:
    let r = rows.filterIt(it.network == n.name)
    doAssert r.len == 1 and r[0].chain == n.caip2 and r[0].address.startsWith(n.hrp & "1"), $r
  echo "2. one row per network, its own chain and prefix OK"

echo "btc_payer_address_test: all OK"
