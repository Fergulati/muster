## FileShare's readiness (exo-4d0.2): where storage_module stands, graded as readiness grades
## any module (coordination/module_registry.nim, exo-dcc.10), and then how the node is doing.
##
## The host's registry is asked FIRST, and the node only once the host says storage_module is
## ready, or cannot say (the standalone runner bundles no registry): over lp a call to a module
## installed but not loaded blocks for the caller's whole deadline. Not installed names the
## package to install, which the FileShare tab offers through Basecamp's Package Manager on
## the person's confirmation; Muster installs nothing. Pure: the probes are the host's.

import std/strutils
import ../coordination/module_registry

const StoragePackage* = "storage_module"   ## what Package Manager installs: the catalogue's own

type
  FileShareState* = enum
    fsReady = "ready"                 ## the node runs: share and fetch
    fsStarting = "starting"           ## the node is coming up
    fsNotInstalled = "not-installed"  ## the host does not have storage_module
    fsNotRunning = "not-running"      ## installed, not running (yet)
    fsFailed = "failed"               ## the module is in error, or its node would not start
  NodeStatus* = object
    usable*: bool
    failed*: bool
    note*: string
  FileShareReadiness* = object
    state*: FileShareState
    note*: string
    install*: string                  ## the package to request when not installed, else ""

proc ready*(r: FileShareReadiness): bool = r.state == fsReady

proc fileShareReadiness*(rec: ModuleRecordAnswer, node: proc(): NodeStatus): FileShareReadiness =
  if rec.answered and not rec.known:
    return FileShareReadiness(state: fsNotInstalled, install: StoragePackage,
      note: "Logos Storage (storage_module) is not installed. Install it to share files in this room.")
  if rec.answered and rec.known:
    case rec.state.toLowerAscii()
    of "ready": discard
    of "error":
      return FileShareReadiness(state: fsFailed,
        note: "Logos Storage is in error" & (if rec.reason.len > 0: ": " & rec.reason else: "."))
    else:
      return FileShareReadiness(state: fsNotRunning,
        note: "Logos Storage is installed but not running yet (" & rec.state & ").")
  let n = node()
  if n.usable: FileShareReadiness(state: fsReady)
  elif n.failed: FileShareReadiness(state: fsFailed, note: n.note)
  else: FileShareReadiness(state: fsStarting, note: n.note)
