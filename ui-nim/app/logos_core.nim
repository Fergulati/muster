## The host side of logos-core for a Nim program (ADR-019, option B): liblogos's C API,
## the functions logos-standalone-app itself calls (its app/main.cpp), bound with
## importc, and `startCore`, what a host does with them. Link against liblogos_core,
## built on the program's own Qt (ui-nim#logos-core). It spawns each core module in a
## `logos_host` process, found via LOGOS_HOST_PATH or next to the executable.
##
## Two programs use it: the app (muster-app, as muster_ui) and the headless host
## (muster-headless-host, as muster_headless).

import std/[strutils, sysrand]
import logos_sdk/ffi

proc logos_core_add_modules_dir*(modulesDir: cstring) {.importc, cdecl.}
proc logos_core_set_persistence_base_path*(path: cstring) {.importc, cdecl.}
proc logos_core_start*() {.importc, cdecl.}
proc logos_core_cleanup*() {.importc, cdecl.}
proc logos_core_load_module*(name: cstring, withDependencies: bool): cint {.importc, cdecl.}
proc logos_core_get_token*(key: cstring): cstring {.importc, cdecl.}
  ## The host's token for `key` (NULL if absent). The caller frees it with free().

proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

proc hostToken*(key: string): string =
  ## The core's token for `key`, copied and freed; "" when the core has none.
  let t = logos_core_get_token(key.cstring)
  if t != nil:
    result = $t
    c_free(t)

proc startCore*(modulesDir, persistence, origin: string, modules: openArray[string],
                required: string, say: proc (msg: string) = nil): string =
  ## Start logos-core in this process, load `modules`, and register this process with
  ## capability_module as `origin`, so its lp_* clients authenticate. "" on success,
  ## else why not.
  ##
  ## As logos-standalone-app does: the modules dir and the persistence base first,
  ## then capability_module, then each of `modules` with its own dependencies, in
  ## order. A module that fails to load is reported; only `required` is fatal.
  logos_core_add_modules_dir(modulesDir.cstring)
  logos_core_set_persistence_base_path(persistence.cstring)
  logos_core_start()
  if logos_core_load_module("capability_module", false) == 0:
    return "capability_module did not load"
  for m in modules:
    if logos_core_load_module(m.cstring, true) != 0:
      if say != nil: say("Loaded dependency (with transitive deps): " & m)
    elif m == required:
      return required & " did not load"
    elif say != nil:
      say("Failed to load dependency: " & m)
  let capToken = hostToken("capability_module")
  if capToken.len == 0:
    return "the core holds no capability_module token"
  # Register this process with capability_module, as the Logos host does for a view
  # module (logos-standalone-app's informModuleToken): the core's capability token
  # vouches for a fresh token that this process then presents as `origin`.
  discard lp_token_save("capability_module", capToken.cstring)
  let cap = lp_client_create("capability_module", "core", nil, nil)
  if cap == nil:
    return "no capability_module client"
  var token = ""
  for b in urandom(16): token.add b.toHex(2).toLowerAscii
  if lp_inform_module_token(cap, capToken.cstring, origin.cstring, token.cstring) != LP_OK:
    return "capability_module refused the token for " & origin
  discard lp_token_save("core", token.cstring)
  discard lp_token_save("capability_module", token.cstring)
  ""
