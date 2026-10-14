## exo-607: muster's UI as a standalone seaqt app (ADR-019, option B). The real QML
## (ui/src/qml/Main.qml) runs in a Nim host, with no Basecamp, no ui-host and no QtRO.
## The backend is the contract object (repContract, from ui/src/muster_ui.rep) with
## every SLOT implemented in ./backend.nim (T5), exposed to QML the way the Logos host
## exposes its bridge: a `logos` context property whose `module("muster_ui")`
## returns the backend.
##
## The host starts logos-core itself (liblogos's C API, as logos-standalone-app
## does), registers the view's token with capability_module, and calls muster_module
## as muster_ui through the client generated from muster.lidl (nix/muster-client.nix),
## always through its async twins: a result lands on the Qt main thread, where the
## client lives, so a callback sets a PROP directly and the view never blocks.
##
##   muster-app [--modules <dir> --user-dir <dir>]   a window on a display; with
##                                                    --modules, backed by logos-core
##   muster-app --self-test                           offscreen: the view loads; the
##                                                    backend records calls, sends none
##   muster-app --self-test-core --modules <dir> --user-dir <dir>
##                                                    offscreen: + muster_module.health()

import std/[os, strutils, json, sysrand, times]
import nimside, seaqt/[qguiapplication, qcoreapplication, qquickview, qqmlengine,
  qqmlcontext, qqmlerror, qurl, qvariant, qwindow]
import logos_sdk, logos_sdk/ffi
import muster_client          # generated at build time from muster.lidl (nix/muster-client.nix)
import ../contract/repcontract, ./logos_core

const
  musterRep {.strdefine.} = ""        ## ui/src/muster_ui.rep, the view contract
  musterQml {.strdefine.} = ""        ## ui/src/qml, the view itself
  logosQmlImports {.strdefine.} = ""  ## where Logos/Theme and Logos/Controls live
  musterMetadata {.strdefine.} = ""   ## ui/metadata.json: the modules the view depends on
when musterRep.len == 0 or musterQml.len == 0 or musterMetadata.len == 0:
  {.error: "build with -d:musterRep=<muster_ui.rep> -d:musterQml=<ui/src/qml> " &
           "-d:musterMetadata=<ui/metadata.json>".}

const uiDependencies = block:
  ## What logos-standalone-app loads for muster_ui, from the same metadata.json the
  ## C++ build ships: each with its own dependencies, after capability_module.
  var deps: seq[string]
  for d in parseJson(staticRead(musterMetadata))["dependencies"]: deps.add d.getStr()
  deps

var
  calls: seq[string]   ## every SLOT the view called, in order (the self-tests read it)
  coreUp = false       ## logos-core is running and muster_module answers to us
let mm = newMusterClient("muster_ui")   ## muster_module, called as muster_ui over lp_*

proc onSlot[T](o: T, name: string) = calls.add name   ## repContract calls it first in every SLOT
repContract(MusterUi, musterRep)
include ./backend

proc startCore(modulesDir, userDir: string): string =
  ## Start logos-core in this process and connect as muster_ui. "" on success, else why not.
  logos_core_add_modules_dir(modulesDir.cstring)
  logos_core_set_persistence_base_path(cstring(userDir / "module_data"))
  logos_core_start()
  if logos_core_load_module("capability_module", false) == 0:
    return "capability_module did not load"
  # As logos-standalone-app does for a ui_qml module: every dependency the view's
  # metadata.json declares, with its own, in order. A failure warns; only
  # muster_module is required.
  for dep in uiDependencies:
    if logos_core_load_module(dep.cstring, true) != 0:
      info "Loaded dependency (with transitive deps): " & dep
    elif dep == "muster_module":
      return "muster_module did not load"
    else:
      info "Failed to load dependency: " & dep
  let capToken = hostToken("capability_module")
  if capToken.len == 0:
    return "the core holds no capability_module token"
  # Register this view with capability_module, as the Logos host does for a view
  # module (logos-standalone-app's informModuleToken): the core's capability
  # token vouches for a fresh token that this process then presents as muster_ui.
  discard lp_token_save("capability_module", capToken.cstring)
  let cap = lp_client_create("capability_module", "core", nil, nil)
  if cap == nil:
    return "no capability_module client"
  var uiToken = ""
  for b in urandom(16): uiToken.add b.toHex(2).toLowerAscii
  if lp_inform_module_token(cap, capToken.cstring, "muster_ui", uiToken.cstring) != LP_OK:
    return "capability_module refused the view's token"
  discard lp_token_save("core", uiToken.cstring)
  discard lp_token_save("capability_module", uiToken.cstring)
  if mm.proxy.client() == nil:
    return "no muster_module client"
  coreUp = true
  ""

# ── the Logos host's QML bridge, as much of it as muster's QML uses ─────────────
qobject:
  type LogosShim = ref object of VirtualQObject
    backend: MusterUi

  proc viewModuleReadyChanged(o: LogosShim, moduleName: string, isReady: bool) {.signal.}

  proc module(o: LogosShim, name: string): QObject {.slot, raises: [].} =
    if name == "muster_ui":
      result = QObject(h: o.backend[].h, owned: false)

  proc isViewModuleReady(o: LogosShim, name: string): bool {.slot, raises: [].} =
    name == "muster_ui"

  proc create(T: type LogosShim, backend: MusterUi): LogosShim =
    let res = T(backend: backend)
    QObject.create(res)
    res

# ── main ────────────────────────────────────────────────────────────────────────
proc arg(name: string): string =
  let ps = commandLineParams()
  let i = ps.find(name)
  if i >= 0 and i + 1 < ps.len: ps[i + 1] else: ""

proc pumpUntil(cond: proc(): bool, seconds: float) =
  let deadline = epochTime() + seconds
  while not cond() and epochTime() < deadline:
    QCoreApplication.processEvents()
    sleep(10)

proc main(): int =
  let
    ps = commandLineParams()
    selfTest = "--self-test" in ps
    selfTestCore = "--self-test-core" in ps
    modulesDir = arg("--modules")
  # As logos-standalone-app: --user-dir, else LOGOS_USER_DIR, else the platform's app
  # data location. Everything this run persists lives below it.
  var userDir = arg("--user-dir")
  if userDir.len == 0: userDir = getEnv("LOGOS_USER_DIR")
  if userDir.len > 0: userDir = absolutePath(userDir)
  # Before the application exists: the Basic Quick Controls style, which Basecamp and
  # logos-standalone-app set and the design system assumes, and Qt's logging on stderr
  # (else it may go to the journal), where the self-tests read it. Either can be
  # overridden from the environment.
  if not existsEnv("QT_QUICK_CONTROLS_STYLE"): putEnv("QT_QUICK_CONTROLS_STYLE", "Basic")
  if not existsEnv("QT_FORCE_STDERR_LOGGING"): putEnv("QT_FORCE_STDERR_LOGGING", "1")
  let
    _ = QGuiApplication.create()
    backend = MusterUi.create()
    logos = LogosShim.create(backend)
  # QML's Settings (the view's prefs) refuse to open without these on Qt 6.11, and then
  # persist nothing. The organization is the one logos-standalone-app sets.
  QCoreApplication.setOrganizationName("Logos")
  QCoreApplication.setOrganizationDomain("logos.co")
  QCoreApplication.setApplicationName("muster")

  var failed = 0
  template check(ok: bool, what: string) =
    echo (if ok: "PASS: " else: "FAIL: "), what
    if not ok: inc failed

  if modulesDir.len > 0:
    if userDir.len == 0:
      userDir = QStandardPaths.writableLocation(17)   # QStandardPaths::AppDataLocation
    if fileExists(userDir):
      quit "Session directory exists but is not a directory: " & userDir, 1
    createDir(userDir)
    info "Session directory: " & qs(userDir)
    let err = startCore(modulesDir, userDir)
    check err.len == 0, "logos-core started in this process; muster_module loaded; " &
      "the view's token registered with capability_module" & (if err.len > 0: " (" & err & ")" else: "")
    if err.len > 0:
      logos_core_cleanup()
      return 1

  let
    view = QQuickView.create()
    imports = getEnv("MUSTER_QML_IMPORT", logosQmlImports)
  for dir in imports.split(':'):
    if dir.len > 0: view.engine().addImportPath(dir)
  view.rootContext().setContextProperty("logos", logos[])
  view.setResizeMode(1) # SizeRootObjectToView
  view.setSource(QUrl.fromLocalFile(musterQml / "Main.qml"))
  let errs = view.errors()
  for e in errs: echo "QML: ", e.toString()
  check view.status() == 1 and errs.len == 0,
    "Main.qml loaded in a seaqt host: status Ready, no QML errors"
  if failed > 0:
    if modulesDir.len > 0: logos_core_cleanup()
    return 1

  # What the C++ backend's onContextReady did once ui-host wired its modules: the
  # startup reads, the inbox, and the MUSTER_AUTO* autopilot.
  if coreUp: backend.contextReady()

  if not (selfTest or selfTestCore):
    view.resize(1024, 768)   # logos-standalone-app's default
    view.show()
    let rc = QGuiApplication.exec().int
    if modulesDir.len > 0: logos_core_cleanup()
    return rc

  let root = view.rootObject()
  check root.property("ready").toBool(),
    "the view is ready: logos.module(\"muster_ui\") returned the Nim backend"
  check calls.len > 0, "QML called the backend while loading (" & $calls.len & " call(s))"
  for c in calls: echo "  ", c

  if selfTestCore:
    pumpUntil(proc(): bool = backend.health != "unknown", 60)
    check backend.health == "ok",
      "muster_module.health() over lp_*, from this Nim host, set the health PROP to '" &
      backend.health & "'"
    logos_core_cleanup()

  echo if failed == 0: "SUCCESS: muster's real QML runs in a Nim host" &
         (if selfTestCore: ", backed by muster_module through logos-core" else: " against the contract")
       else: "FAILED: " & $failed & " check(s)"
  failed

quit main()
