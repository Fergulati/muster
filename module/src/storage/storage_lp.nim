## LpStorage — the BlobStore seam over storage_module (exo-4d0.2, docs/design/room-swarm.md
## §5.1). Not pure, so like monero_backend_lp.nim it is compiled only into the plugin; its
## reading of replies and events, and its jobs, are storage_events.nim (unit-tested).
##
## In Basecamp the package downloader starts the host's storage node as soon as
## storage_module is ready (S0 Q8), so Muster ATTACHES to it, and never stops or destroys a
## node. Only where no node is running and none has been initialised — the standalone
## runner, where nothing else starts one — does Muster init its own, and then it keeps that
## node to THIS instance (2026-10-16, on the operator's machine): Basecamp's node, or another
## runner's, holds ~/.logos_storage/data, and a second node on it fails ("Should create
## metadata store!": LevelDB's lock). So it inits with loadConfigOrDefault()'s config but a
## data dir of this instance's (`dataDir`) and a free port, MUSTER_STORAGE_CONFIG merged over
## both (the self-tests). `init` also rewrites the shared ~/.logos_storage/config.json, which
## is Basecamp's: Muster puts it back exactly as it was. A failed start is not tried again for
## RetryS, and a start that never comes up counts as failed after StartWaitS.
##
## Events are host-wide (S0 Q7). One subscription per event name lands in its own queue on
## the callee's thread; `poll` drains them on the module thread into the jobs. Every call is
## bounded (CallMs); the module thread never waits on a transfer — those are jobs.

import std/[json, os, times, net]
import logos_sdk/ffi
import ../transport/inbound_queue
import ./blob_store
import ./storage_events
import ./storage_readiness

const
  Ours = "muster_module"
  Target* = "storage_module"
  CallMs = 5_000.cint
  ChunkSize = 65536
  ReachEveryS = 10.0
  RetryS = 30.0
  StartWaitS = 60.0
  EventNames = ["storageUploadProgress", "storageUploadDone",
                "storageDownloadProgress", "storageDownloadDone"]

type
  EventQueue = ref object
    q: InboundQueue
  LpStorage* = ref object of BlobStore
    client: ptr LpClient
    queues: seq[EventQueue]
    subs: seq[ptr LpSubscription]
    jobs: StorageJobs
    attached: bool
    note*: string            ## why the node is not usable yet ("" when it is)
    failed: bool             ## the last start failed (or never came up)
    retryAt: float           ## not before this, after a failure
    startedAt: float         ## when this instance asked its own node to start (0 = it did not)
    dataDir: string          ## this instance's storage folder, for a node it inits itself
    listenPort: int          ## the port of a node this instance inited (0 = not ours)
    reachCache: PeerReach
    reachAt: float

proc newLpStorage*(dataDir: string): LpStorage =
  ## `dataDir`: where a node this instance has to start itself keeps its data.
  result = LpStorage(jobs: initStorageJobs(), dataDir: dataDir)
  GC_ref(result)

proc freePort(): int =
  let sock = newSocket()
  defer: sock.close()
  sock.bindAddr(Port(0), "127.0.0.1")
  int(sock.getLocalAddr()[1])

proc sharedConfigPath(): string = getHomeDir() / ".logos_storage" / "config.json"

proc onEvent(eventName, dataJson: cstring, userData: pointer) {.cdecl, gcsafe.} =
  ## On storage_module's thread: copy the event into its queue (no Nim GC), nothing more.
  if userData == nil or dataJson == nil: return
  cast[EventQueue](userData).q.enqueue(dataJson)

proc call(s: LpStorage, meth: string, args: JsonNode): tuple[ok: bool, value: JsonNode, error: string] =
  if s.client == nil: return (false, nil, Target & " is not reachable")
  var res, err: cstring
  let rc = lp_invoke(s.client, meth.cstring, ($args).cstring, CallMs, addr res, addr err)
  defer:
    if res != nil: lp_string_free(res)
    if err != nil: lp_string_free(err)
  if rc != LP_OK or res == nil:
    return (false, nil, meth & " failed" & (if err != nil: ": " & $err else: ""))
  unwrapReply($res)

proc ensure*(s: LpStorage): bool =
  ## Reach storage_module and make sure a node is running: attach to the host's, or — only
  ## when no node was ever initialised — init and start this instance's own. Returns whether
  ## it is usable; `note` says why not.
  if s.attached: return true
  let now = epochTime()
  if now < s.retryAt: return false
  if s.client == nil:
    s.client = lp_client_create(Target.cstring, Ours.cstring, nil, nil)
    if s.client == nil:
      s.note = Target & " is not installed or not running"
      s.retryAt = now + RetryS
      return false
    for name in EventNames:
      let eq = EventQueue()
      initInboundQueue(eq.q)
      GC_ref(eq)
      s.queues.add eq
      s.subs.add lp_subscribe(s.client, name.cstring, onEvent, cast[pointer](eq))
  let running = s.call("isRunning", newJArray())
  if running.ok and running.value != nil and running.value.kind == JBool and running.value.getBool():
    s.attached = true
    s.failed = false
    s.note = ""
    return true
  if s.startedAt > 0:
    # this instance asked its own node to start: give it StartWaitS
    if now - s.startedAt < StartWaitS:
      s.note = "the storage node is starting"
      return false
    s.startedAt = 0
    s.failed = true
    s.retryAt = now + RetryS
    s.note = "the storage node did not come up; storage_module's log says why"
    return false
  # No node is running. Init one for this instance (if another consumer already has, init
  # answers false and start brings that one up), and keep Basecamp's config file as it was.
  var cfg = newJObject()
  let loaded = s.call("loadConfigOrDefault", newJArray())
  if loaded.ok:
    let j = valueJson(loaded.value)
    if j != nil and j.kind == JObject: cfg = j
  if s.dataDir.len > 0:
    createDir(s.dataDir)
    cfg["data-dir"] = %s.dataDir
  try: cfg["listen-port"] = %freePort()
  except CatchableError: discard
  let extra = getEnv("MUSTER_STORAGE_CONFIG")
  if extra.len > 0:
    try:
      for k, v in parseJson(extra): cfg[k] = v
    except CatchableError: discard
  s.listenPort = cfg{"listen-port"}.getInt(0)
  let shared = sharedConfigPath()
  let hadShared = fileExists(shared)
  let before = (if hadShared: readFile(shared) else: "")
  let inited = s.call("init", %*[$cfg])
  try:
    if hadShared:
      if readFile(shared) != before: writeFile(shared, before)
    elif fileExists(shared): removeFile(shared)
  except CatchableError: discard
  let started = s.call("start", newJArray())
  if not started.ok or (started.value != nil and started.value.kind == JBool and not started.value.getBool()):
    s.failed = true
    s.retryAt = now + RetryS
    s.note = "the storage node did not start" &
             (if inited.ok and inited.value != nil and inited.value.kind == JBool and not inited.value.getBool():
                " (storage_module refused to create it; its log says why)" else: "") &
             "; trying again in " & $int(RetryS) & " s"
    return false
  s.startedAt = now
  s.note = "the storage node is starting"
  false

proc status*(s: LpStorage): NodeStatus =
  ## How the node is doing, for storage_readiness.
  let ok = s.ensure()
  NodeStatus(usable: ok, failed: not ok and s.failed, note: s.note)

method reach*(s: LpStorage): PeerReach =
  if not s.ensure(): return PeerReach()
  let now = epochTime()
  if s.reachCache.peerId.len > 0 and now - s.reachAt < ReachEveryS: return s.reachCache
  var r = PeerReach()
  let p = s.call("peerId", newJArray())
  if p.ok and p.value != nil and p.value.kind == JString: r.peerId = p.value.getStr()
  let d = s.call("debug", newJArray())
  if d.ok:
    let j = valueJson(d.value)
    if j != nil and j.kind == JObject and j{"addrs"} != nil and j{"addrs"}.kind == JArray:
      for a in j["addrs"]:
        if a.kind == JString: r.addrs.add a.getStr()
  let n = s.call("network", newJArray())
  if n.ok and n.value != nil and n.value.kind == JString: r.network = n.value.getStr()
  # a node of this instance's own also answers on loopback: another instance on this host
  # reaches it there, where the announced address may not route back in (S0 Q4)
  if s.listenPort > 0:
    let lo = "/ip4/127.0.0.1/tcp/" & $s.listenPort
    if lo notin r.addrs: r.addrs.add lo
  s.reachCache = r
  s.reachAt = now
  r

proc spr*(s: LpStorage): string =
  ## This node's signed peer record: what another node bootstraps from to join its network.
  if not s.ensure(): return ""
  let r = s.call("spr", newJArray())
  if r.ok and r.value != nil and r.value.kind == JString: r.value.getStr() else: ""

method upload*(s: LpStorage, path: string): string =
  if not s.ensure(): return s.jobs.failed(s.note)
  let r = s.call("uploadUrl", %*[path, ChunkSize, true])
  if not r.ok or r.value == nil: return s.jobs.failed("uploadUrl: " & r.error)
  s.jobs.startUpload(if r.value.kind == JString: r.value.getStr() else: $r.value)

method download*(s: LpStorage, cid, dest: string, private, serve: bool): string =
  if not s.ensure(): return s.jobs.failed(s.note)
  let r = s.call("downloadToUrl", %*[cid, dest, false, ChunkSize, private, serve])
  if not r.ok: return s.jobs.failed("downloadToUrl: " & r.error)
  s.jobs.startDownload(cid, dest)

method job*(s: LpStorage, id: string): BlobJob =
  result = s.jobs.job(id)
  # a download whose CID finished for another consumer, with nothing at OUR destination
  if result.state == jsDone and result.cid.len > 0 and s.jobs.destOf(id).len > 0 and
     not fileExists(s.jobs.destOf(id)):
    result.state = jsFailed
    result.error = "the download finished without writing here (another consumer's session on the same CID)"

method poll*(s: LpStorage) =
  for i, eq in s.queues:
    for raw in eq.q.drain():
      var str = newString(raw.len)
      if raw.len > 0: copyMem(addr str[0], unsafeAddr raw[0], raw.len)
      s.jobs.onEvent(EventNames[i], eventPayload(str))

proc boolCall(s: LpStorage, meth, cid: string): bool =
  if not s.ensure(): return false
  let r = s.call(meth, %*[cid])
  r.ok and r.value != nil and r.value.kind == JBool and r.value.getBool()

method has*(s: LpStorage, cid: string): bool = s.boolCall("exists", cid)
method serving*(s: LpStorage, cid: string): bool = s.boolCall("getAdvertise", cid)

method setServing*(s: LpStorage, cid: string, on: bool) =
  if s.ensure(): discard s.call("setAdvertise", %*[cid, on])

method connect*(s: LpStorage, peer: PeerReach) =
  if s.ensure() and peer.peerId.len > 0: discard s.call("connect", %*[peer.peerId, peer.addrs])

method remove*(s: LpStorage, cid: string) =
  if s.ensure(): discard s.call("remove", %*[cid])
