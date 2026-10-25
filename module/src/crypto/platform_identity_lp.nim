## The ManagerPort over lp_* (exo-833): PlatformIdentityKeystore's calls to
## signer_manager_module. Not pure, so like wallet/keystore_probe.nim it is compiled only into
## the plugin.
##
## Every call is a short synchronous lp_invoke. Inside the unlock the person granted muster,
## the manager settles a request as it arrives (its own request_approval signs before it
## answers), so nothing here waits on a person; a request the manager would show instead
## comes back unsettled and PlatformIdentityKeystore cancels it.

import std/json
import logos_sdk/ffi
import ../wallet/keystore_status   # ksReply: a reply in whichever envelope lp_* delivers it; Ours
import ./platform_identity

const
  SignerManager* = "signer_manager_module"
  CallMs = 5_000.cint      ## the manager signs inside the call when unlocked; well under this

var gClient: ptr LpClient = nil

proc reached(): bool =
  ## Created on first use, origin muster_module: the manager attributes our requests to us,
  ## from the runtime's caller, and derives our identity key for `muster_module/<context>`.
  if gClient == nil:
    gClient = lp_client_create(SignerManager.cstring, Ours.cstring, nil, nil)
  gClient != nil

proc lpCall*(meth: string, args: JsonNode): JsonNode =
  ## One call: its parsed reply, or nil when the manager is not loaded or did not answer.
  if not reached(): return nil
  var res, err: cstring
  let rc = lp_invoke(gClient, meth.cstring, ($args).cstring, CallMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil: return nil
  ksReply($res)

proc managerPort*(): ManagerPort =
  result = proc(meth: string, args: JsonNode): JsonNode = lpCall(meth, args)
