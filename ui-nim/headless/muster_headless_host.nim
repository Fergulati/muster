## muster-headless-host: logos-core in this process, muster_module (and its
## dependencies) loaded, and a stdin REPL that calls any loaded module. No display, no
## view, no daemon: the owned host for driving muster headless (exo-607 T7, the Nim
## port of module/tools/headless-host/muster_headless_host.cpp).
##
##   stdin:  one call per line, tab-separated: <module>\t<method>\t<arg1>\t<arg2>…
##           (`quit` or end of input stops it)
##   replies: OK\t<result> or ERR\t<why>, one line each, as each reply arrives — on
##           stdout, or on --reply-file, away from the modules' own logs on stdout
##
##   muster-headless-host --modules-dir <dir> --persistence <dir>
##                        [--instance <id>] [--load <module>] [--reply-file <path>]
##
## The C++ host drove raw QtRemoteObjects replicas with the capability gate off. This
## one starts the core as the app does (app/logos_core.nim): it registers itself with
## capability_module as `muster_headless` and calls over lp_*, asynchronously, so the
## event loop keeps running and delivery's transport pumps between calls (a
## two-instance run needs that). Arguments go as strings, as the C++ host sent them.

import std/[json, os, strutils, tables]
import seaqt/[qcoreapplication, qsocketnotifier]
import logos_sdk
import ../app/logos_core

const origin = "muster_headless"

var
  reply: File = stdout
  proxies: Table[string, PluginProxy]

proc say(msg: string) =
  try: stderr.writeLine "[host] " & msg
  except IOError: discard

proc answer(line: string) =
  try:
    reply.writeLine line
    reply.flushFile()
  except IOError: discard

proc oneLine(s: string): string = s.replace("\n", "\\n")

proc handle(line: string) =
  let t = line.strip()
  if t.len == 0: return
  let parts = t.split('\t')
  if parts.len < 2:
    answer "ERR\tbad-line"
    return
  let module = parts[0]
  if module notin proxies: proxies[module] = newPluginProxy(module, origin)
  var args = newJArray()
  for a in parts[2 .. ^1]: args.add %a
  discard proxies[module].callAsyncThen(parts[1], args, proc (r: CallResult) =
    if r.ok:
      let v = (if r.value != nil and r.value.kind == JString: r.value.getStr() else: $r.value)
      answer "OK\t" & oneLine(v)
    else:
      answer "ERR\t" & oneLine(if r.error != nil: $r.error else: r.raw))

proc arg(name, default: string): string =
  let ps = commandLineParams()
  let i = ps.find(name)
  if i >= 0 and i + 1 < ps.len: ps[i + 1] else: default

proc main(): int =
  putEnv("LOGOS_INSTANCE_ID", arg("--instance", "muster-headless"))
  let
    modulesDir = arg("--modules-dir", "")
    persistence = arg("--persistence", "")
    load = arg("--load", "muster_module")
    replyFile = arg("--reply-file", "")
  if modulesDir.len == 0 or persistence.len == 0:
    quit "usage: muster-headless-host --modules-dir <dir> --persistence <dir> " &
         "[--instance <id>] [--load <module>] [--reply-file <path>]", 2
  if replyFile.len > 0:
    try: reply = open(replyFile, fmWrite)
    except IOError: quit "cannot write " & replyFile, 1
  if not existsEnv("QT_FORCE_STDERR_LOGGING"): putEnv("QT_FORCE_STDERR_LOGGING", "1")
  let app = QCoreApplication.create()
  createDir(persistence)
  let err = startCore(modulesDir, persistence, origin, [load], load, say)
  if err.len > 0:
    say "FAILED: " & err
    logos_core_cleanup()
    return 1
  say "ready"
  # stdin, read on the event loop: a line is handled when it arrives, and its reply
  # when the module answers, while delivery keeps pumping in between.
  let notifier = QSocketNotifier.create(0'u, QSocketNotifierTypeEnum.Read.cint)
  notifier.onActivated(proc (socket: QSocketDescriptor, ev: cint) {.closure, raises: [].} =
    try:
      var line: string
      if not stdin.readLine(line) or line.strip() in ["quit", "exit"]:
        QCoreApplication.quit()
      else:
        handle(line)
    except Exception:
      QCoreApplication.quit())
  let rc = QCoreApplication.exec().int
  logos_core_cleanup()
  discard app
  rc

quit main()
