## What the Wallet page shows (exo-f37): the wallets this instance has been GIVEN, and
## nothing it has not. Pure — a function of what the host answered — so the rules are held
## by wallet_summary_test, and muster_module only gathers the inputs.
##
##   * Ethereum, under the platform: only the keystore_module account the person chose for
##     Muster. Muster's own secp key is an internal identity there, never shown as a wallet
##     the person holds. In the standalone runner (no platform) the instance's own key on
##     its configured chain IS the development wallet, and is marked as such.
##   * Monero: the wallet open in Monero Wallet (monero_wallet_backend), with its primary
##     address and account 0's balance, asked only when the host reports the backend
##     running. A read not answered yet is "checking" or "pending", never a zero and never
##     "no wallet".
##   * The LEZ and the runner's demo chain: as the wallet aggregate read them.
##   * Everything not connected is a line in `connect` saying how, never a default account.

import std/[json, strutils]
import ./types
import ./monero_backend

type
  MoneroView* = object
    module*: string            ## monero_wallet_backend's state on this host: ready | starting |
                               ## installed | not-installed | error | unknown (readiness.ModuleState)
    status*: WalletStatus      ## wallet_status, when the module is ready
    receive*: ReceiveInfo      ## receive_info(0)
    balances*: Balances        ## balances(0)

  SummaryInputs* = object
    platform*: bool            ## keystore_module attests Muster: Basecamp or logoscore
    evmAccount*: string        ## platform: the keystore account chosen for Muster ("" = none);
                               ## runner: this instance's own address
    keystoreAccounts*: int     ## how many accounts keystore_module lists (platform)
    rows*: JsonNode            ## the wallet aggregate's balance rows ({chain, account, asset, …})
    lezDemo*: bool             ## the LEZ rows come from the in-process fake, not a real lez_core wallet
    monero*: MoneroView

proc group(chain: string): string =
  if chain.startsWith("evm:"): "ethereum"
  elif chain.startsWith("lez:"): "lez"
  else: "demo"

proc rowsOf(rows: JsonNode, g: string): JsonNode =
  result = newJArray()
  if rows == nil or rows.kind != JArray: return
  for r in rows:
    if r.kind == JObject and group(r{"chain"}.getStr()) == g: result.add r

proc xmr(atomic: string): string = formatUnits(atomic, XmrDecimals) & " XMR"

proc walletSummary*(i: SummaryInputs): JsonNode =
  ## {wallets: [{id, name, account, via, dev?, network?, wallet?, state?, balances: [...]}],
  ##  connect: [{id, name, how, action, package?}], checking: [name]}
  var wallets = newJArray()
  var connect = newJArray()
  var checking = newJArray()

  # ── Ethereum ────────────────────────────────────────────────────────────────
  if i.evmAccount.len > 0:
    wallets.add %*{"id": "ethereum", "name": "Ethereum", "account": i.evmAccount.toLowerAscii(),
                   "via": (if i.platform: "your Logos Keystore account" else: "this instance's own key"),
                   "dev": not i.platform, "balances": rowsOf(i.rows, "ethereum")}
  elif i.platform:
    connect.add (if i.keystoreAccounts > 0:
      %*{"id": "ethereum", "name": "Ethereum", "action": "settings",
         "how": "Choose one of your Logos Keystore accounts for Muster, in Settings"}
    else:
      %*{"id": "ethereum", "name": "Ethereum", "action": "accounts",
         "how": "Create or import an account in Logos Keystore"})

  # ── Monero ──────────────────────────────────────────────────────────────────
  let m = i.monero
  case m.module
  of "ready":
    if m.status.read != rsAnswered:
      checking.add %"Monero"
    elif m.status.wallet.len > 0 and m.status.state in ["ready", "syncing", "opening"]:
      var bal = %*{"chain": "monero:" & m.status.network, "asset": "XMR", "grade": "attested",
                   "account": m.receive.primary}
      if m.balances.read == rsAnswered:
        bal["display"] = %xmr(m.balances.balance)
        bal["raw"] = %m.balances.balance
        if m.balances.unlocked.len > 0: bal["unlocked"] = %xmr(m.balances.unlocked)
      else:
        bal["pending"] = %true
      wallets.add %*{"id": "monero", "name": "Monero", "account": m.receive.primary,
                     "wallet": m.status.wallet, "network": m.status.network,
                     "state": m.status.state, "watchOnly": m.status.watchOnly,
                     "via": "Monero Wallet", "balances": [bal]}
    else:
      connect.add %*{"id": "monero", "name": "Monero", "action": "monero",
                     "how": "Open a wallet in Monero Wallet"}
  of "starting", "installed", "error":
    connect.add %*{"id": "monero", "name": "Monero", "action": "monero",
                   "how": "Open Monero Wallet to connect a wallet"}
  of "not-installed":
    connect.add %*{"id": "monero", "name": "Monero", "action": "install",
                   "package": MoneroWalletApp,
                   "how": "Install Monero Wallet to request and receive XMR"}
  else: discard        # a host that cannot say (the standalone runner): nothing to offer

  # ── the LEZ, and the runner's demo chain ────────────────────────────────────
  let lez = rowsOf(i.rows, "lez")
  if lez.len > 0:
    wallets.add %*{"id": "lez", "name": "Logos Execution Zone",
                   "via": (if i.lezDemo: "an in-process LEZ, for trying the flows" else: "your LEZ wallet"),
                   "dev": i.lezDemo, "balances": lez}
  let demo = rowsOf(i.rows, "demo")
  if demo.len > 0 and not i.platform:
    wallets.add %*{"id": "demo", "name": "Demo chain", "via": "an in-process chain, for trying the flows",
                   "dev": true, "balances": demo}

  %*{"wallets": wallets, "connect": connect, "checking": checking}
