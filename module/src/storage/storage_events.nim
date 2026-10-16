## The pure half of the storage_module binding (exo-4d0.2): reading its replies and events,
## and keeping Muster's jobs. No lp_*, so it is unit-tested directly; storage_lp.nim is the
## platform half. What it reads is what S0 saw (docs/labbook/storage-from-muster.md Q7):
##
##   * a method answers a StdLogosResult {success, value, error} or a bare value; a value may
##     itself be a JSON document carried in a string (debug(), space());
##   * an event carries ONE argument, a JSON document in a string, delivered as an array of
##     arguments (lp_subscribe) or under "arg0" (the host's event bus);
##   * events are host-wide: every consumer sees every session's. An upload is matched by its
##     session id (a node-wide counter); a download's session id IS its CID, so every one of
##     Muster's downloads of a CID finishes on that CID's event, and anyone else's session
##     moves nothing of ours.

import std/[json, tables]
import ./blob_store
export blob_store.BlobJob, blob_store.BlobJobState

proc unwrapReply*(raw: string): tuple[ok: bool, value: JsonNode, error: string] =
  ## A method's reply: (true, value, "") or (false, nil, why). Never raises.
  if raw.len == 0: return (false, nil, "no reply")
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return (false, nil, "unreadable reply: " & raw)
  if j.kind == JObject and j.hasKey("success"):
    if j["success"].kind == JBool and j["success"].getBool():
      return (true, (if j.hasKey("value"): j["value"] else: newJNull()), "")
    return (false, nil, j{"error"}.getStr("refused"))
  (true, j, "")

proc valueJson*(v: JsonNode): JsonNode =
  ## A reply's value as JSON: itself, or the document a string carries; nil when neither.
  if v == nil: return nil
  if v.kind != JString: return v
  try: parseJson(v.getStr()) except CatchableError: nil

proc eventPayload*(raw: string): JsonNode =
  ## An event's one argument, parsed: the JSON object it carries, or nil.
  var j: JsonNode
  try: j = parseJson(raw)
  except CatchableError: return nil
  for _ in 0 .. 3:
    case j.kind
    of JArray:
      if j.len == 0: return nil
      j = j[0]
    of JObject:
      if j.hasKey("data"): j = j["data"]
      elif j.hasKey("arg0"): j = j["arg0"]
      else: return j
    of JString:
      try: j = parseJson(j.getStr()) except CatchableError: return nil
    else: return nil
  if j.kind == JObject: j else: nil

type StorageJobs* = object
  jobs: Table[string, BlobJob]
  dests: Table[string, string]
  uploads: Table[string, string]           ## storage session id -> our job id
  downloads: Table[string, seq[string]]    ## CID -> our job ids
  next: int

proc initStorageJobs*(): StorageJobs = StorageJobs()

proc add(j: var StorageJobs, job: BlobJob): string =
  inc j.next
  result = "storage-" & $j.next
  var k = job
  k.id = result
  j.jobs[result] = k

proc startUpload*(j: var StorageJobs, session: string): string =
  result = j.add(BlobJob(state: jsRunning))
  j.uploads[session] = result

proc startDownload*(j: var StorageJobs, cid, dest: string): string =
  result = j.add(BlobJob(state: jsRunning, cid: cid))
  j.dests[result] = dest
  j.downloads.mgetOrPut(cid, @[]).add result

proc failed*(j: var StorageJobs, why: string): string =
  ## A job that failed before it reached the node.
  j.add(BlobJob(state: jsFailed, error: why))

proc job*(j: StorageJobs, id: string): BlobJob =
  if id in j.jobs: j.jobs[id] else: BlobJob(id: id, state: jsFailed, error: "no such job")

proc destOf*(j: StorageJobs, id: string): string = j.dests.getOrDefault(id)

proc move(j: var StorageJobs, id: string, p: JsonNode, finish: bool, cid = "") =
  if id notin j.jobs or j.jobs[id].state != jsRunning: return
  var k = j.jobs[id]
  if p{"bytes"} != nil and p{"bytes"}.kind == JInt: k.bytes = uint64(max(0, p{"bytes"}.getInt()))
  if p{"total"} != nil and p{"total"}.kind == JInt: k.total = uint64(max(0, p{"total"}.getInt()))
  if finish:
    if p{"success"}.getBool(false):
      k.state = jsDone
      if cid.len > 0: k.cid = cid
    else:
      k.state = jsFailed
      k.error = p{"error"}.getStr("failed")
  j.jobs[id] = k

proc onEvent*(j: var StorageJobs, name: string, p: JsonNode) =
  ## Apply one storage_module event. One that is not about a job of ours changes nothing.
  if p == nil or p.kind != JObject: return
  let session = p{"sessionId"}.getStr()
  case name
  of "storageUploadProgress", "storageUploadDone":
    if session in j.uploads:
      j.move(j.uploads[session], p, name == "storageUploadDone", p{"cid"}.getStr())
  of "storageDownloadProgress", "storageDownloadDone":
    for id in j.downloads.getOrDefault(session):
      j.move(id, p, name == "storageDownloadDone")
  else: discard
