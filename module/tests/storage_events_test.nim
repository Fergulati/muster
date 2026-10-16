## The pure half of the storage_module binding (exo-4d0.2, docs/labbook/storage-from-muster.md
## Q7): a reply is a StdLogosResult or a bare value; an event's one argument is a JSON
## document, delivered as an array of arguments or as {"arg0": …}; an upload is matched by its
## session id (a node-wide counter), a download by its CID (its session id IS the CID), and
## another consumer's events never move a job of ours.

import std/json
import ../src/storage/storage_events

# 1. Replies: a StdLogosResult envelope, or a bare value; an error is never a value.
block:
  let a = unwrapReply("""{"success":true,"value":"7","error":""}""")
  doAssert a.ok and a.value.getStr() == "7"
  let b = unwrapReply("""{"success":false,"value":"","error":"session is not found"}""")
  doAssert not b.ok and b.error == "session is not found"
  doAssert unwrapReply("true").ok and unwrapReply("true").value.getBool()
  doAssert unwrapReply("\"16Uiu2HAm\"").value.getStr() == "16Uiu2HAm"
  doAssert not unwrapReply("").ok and not unwrapReply("not json").ok
  # a value that is itself a JSON document in a string (debug(), space()) reads as JSON
  let d = unwrapReply("""{"success":true,"value":"{\"id\":\"16U\",\"addrs\":[\"/ip4/1.2.3.4/tcp/1\"]}"}""")
  doAssert valueJson(d.value){"addrs"}[0].getStr() == "/ip4/1.2.3.4/tcp/1"
echo "1. replies OK"

# 2. Event payloads, in each shape the host delivers them.
block:
  let inner = """{"success":true,"sessionId":"0","cid":"zDvZ1"}"""
  for raw in [ $(%*[inner]), $(%*{"arg0": inner}), $(%*{"data": {"arg0": inner}}), inner ]:
    let p = eventPayload(raw)
    doAssert p != nil and p{"cid"}.getStr() == "zDvZ1", raw
  doAssert eventPayload("[]") == nil and eventPayload("nonsense") == nil
echo "2. event payloads OK"

# 3. Jobs: an upload by session id, a download by CID; progress, done, failure; a stranger's
#    session moves nothing.
block:
  var j = initStorageJobs()
  let up = j.startUpload("3")
  let dn = j.startDownload("zDvZcid", "/tmp/x")
  doAssert j.job(up).state == jsRunning and j.job(dn).state == jsRunning
  j.onEvent("storageUploadDone", %*{"success": true, "sessionId": "9", "cid": "zOther"})
  doAssert j.job(up).state == jsRunning, "another consumer's upload is not ours"
  j.onEvent("storageUploadProgress", %*{"success": true, "sessionId": "3", "bytes": 10, "total": 40})
  doAssert j.job(up).bytes == 10 and j.job(up).total == 40
  j.onEvent("storageUploadDone", %*{"success": true, "sessionId": "3", "cid": "zDvZnew"})
  doAssert j.job(up).state == jsDone and j.job(up).cid == "zDvZnew"
  j.onEvent("storageDownloadProgress", %*{"success": true, "sessionId": "zDvZcid", "bytes": 5, "total": 50})
  doAssert j.job(dn).bytes == 5 and j.job(dn).total == 50
  j.onEvent("storageDownloadDone", %*{"success": true, "sessionId": "zDvZcid"})
  doAssert j.job(dn).state == jsDone and j.job(dn).cid == "zDvZcid"
  let bad = j.startDownload("zDvZgone", "/tmp/y")
  j.onEvent("storageDownloadDone", %*{"success": false, "sessionId": "zDvZgone", "error": "Key doesn't exist"})
  doAssert j.job(bad).state == jsFailed and j.job(bad).error == "Key doesn't exist"
  let badUp = j.startUpload("4")
  j.onEvent("storageUploadDone", %*{"success": false, "sessionId": "4", "error": "no space"})
  doAssert j.job(badUp).state == jsFailed
  # a done job is not reopened by a late or repeated event
  j.onEvent("storageUploadDone", %*{"success": false, "sessionId": "3", "error": "late"})
  doAssert j.job(up).state == jsDone
  doAssert j.job("no-such").state == jsFailed
  # two of our downloads of one CID both finish on its one event
  let d1 = j.startDownload("zDvZtwice", "/tmp/a")
  let d2 = j.startDownload("zDvZtwice", "/tmp/b")
  j.onEvent("storageDownloadDone", %*{"success": true, "sessionId": "zDvZtwice"})
  doAssert j.job(d1).state == jsDone and j.job(d2).state == jsDone
  # a job that failed before it reached the node
  let early = j.failed("uploadUrl refused: not running")
  doAssert j.job(early).state == jsFailed and j.job(early).error == "uploadUrl refused: not running"
  doAssert j.destOf(dn) == "/tmp/x"
echo "3. jobs follow their own sessions only OK"

echo "storage_events_test: all OK"
