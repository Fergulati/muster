## FileShare's readiness (exo-4d0.2): where storage_module stands, graded the way the card
## grades a module (module_registry.nim, exo-dcc.10) before Muster calls it, then — only once
## the host says it is ready, or cannot say — how the storage node itself is doing.

import std/strutils
import ../src/coordination/module_registry
import ../src/storage/storage_readiness

proc rec(state: string, reason = ""): ModuleRecordAnswer =
  ModuleRecordAnswer(answered: true, known: true, state: state, reason: reason)
let notInstalled = ModuleRecordAnswer(answered: true, known: false)
let cannotSay = unanswered("no registry here")
let usable = NodeStatus(usable: true)
let starting = NodeStatus(note: "the storage node is starting")
let failed = NodeStatus(failed: true, note: "the storage node did not start")

# 1. Not installed: say so and name the package to install; never ask the node.
block:
  let r = fileShareReadiness(notInstalled, proc(): NodeStatus = doAssert false, "never asked"; usable)
  doAssert r.state == fsNotInstalled and r.install == StoragePackage and not r.ready
  doAssert r.note.len > 0
echo "1. not installed: names the package, asks nothing else OK"

# 2. Installed but not loaded, loading, or stopping: wait for it; never call it (a call to a
#    module that is not loaded blocks for the caller's whole deadline).
for st in ["unloaded", "loading", "loaded", "stopping", "something-new"]:
  let r = fileShareReadiness(rec(st), proc(): NodeStatus = doAssert false, "never asked"; usable)
  doAssert r.state == fsNotRunning and r.install.len == 0 and not r.ready, st
echo "2. installed, not running: wait, never call OK"

# 3. In error: failed, with the host's reason.
block:
  let r = fileShareReadiness(rec("error", "libstorage missing"), proc(): NodeStatus = usable)
  doAssert r.state == fsFailed and "libstorage missing" in r.note
echo "3. in error: failed with the reason OK"

# 4. Ready, or the host cannot say (the standalone runner has no registry): the node decides.
for a in [rec("ready"), cannotSay]:
  doAssert fileShareReadiness(a, proc(): NodeStatus = usable).state == fsReady
  let s = fileShareReadiness(a, proc(): NodeStatus = starting)
  doAssert s.state == fsStarting and s.note == "the storage node is starting" and not s.ready
  let f = fileShareReadiness(a, proc(): NodeStatus = failed)
  doAssert f.state == fsFailed and f.note == "the storage node did not start"
doAssert fileShareReadiness(rec("ready"), proc(): NodeStatus = usable).ready
echo "4. ready or unknown: the node's own state decides OK"

echo "storage_readiness_test: all OK"
