## Voice notes in the room (docs/design/voice-notes.md §3.3, §6, §7): a note as two log
## events, folded by `reduceVoice` into notes, and merged with the room's messages into the
## thread's rows by `threadRows`.
##
##   voice/<nid>/<author>/<i>/2   one half of the note's clip record (i ∈ {0, 1}), in its
##                                author's name: {"v":1, "ts", "durMs", "digest", "part",
##                                "authorSig"}, the half as base64, every number an integer
##
## Each part is author-signed (authorship.nim reads its author off the key) and published
## through `publishAuthored`; `session.publish` pads every `voice/` frame to VoiceFrameBytes
## itself (§4), so no caller passes a pad. The note id is content-addressed over (author,
## clip digest, ts), so every member derives it and nobody can post under another member's
## note id (§6 rule 4).
##
## The fold is pure and order-free (invariant 4), and links no codec: it imports only the
## clip record's structural checks (audio/voice_clip), never libopus or a device. Pass it the
## room's authentic view (`roomEvents(s)`): it trusts that every part's author signed it
## (§6 rule 1) and checks the rest itself. A malformed part is dropped, never raised on.
##
## Only `threadRows` makes a voice row, and the row carries the note in a field of its own,
## `voice`, never in `body` (§7): `reduceMessages` builds a row from a message's author, ts
## and body alone, so no `message/` event can put a `voice` field on a row, whatever its body
## claims. The audio never rides a row: `voice` is metadata only.

import std/[json, strutils, tables, algorithm, base64]
import ../log/log
import ../dcbor/dcbor
import ../hashing/hash_input
import ../audio/voice_clip
import ./intent_events

const
  NoteIdDomain* = "muster.voice.note-id.v1"
  ClipDigestDomain* = "muster.voice.clip.v1"
  VoiceEventVersion* = 1        ## the value's "v"; a new wire shape is a new version
  VoiceParts* = 2               ## a note is exactly two parts, whatever its length (§3.4)
  VoiceMinMs* = 500             ## a shorter note is refused at Send, `too-short` (§3.4, §8)
  PartFields = ["v", "ts", "durMs", "digest", "part", "authorSig"]

type
  VoiceState* = enum
    vsArriving = "arriving"     ## one part so far
    vsComplete = "complete"     ## both parts, every check passed: only this plays
    vsBroken = "broken"         ## the parts disagree, the digest misses, or the record fails
  VoiceNote* = object
    nid*: string                ## the note id (32 hex)
    author*: string             ## the key's author: the member whose signature the room verified
    ts*: int64                  ## the author's clock at Send (seconds)
    durMs*: int                 ## the clip's length, as its parts state it
    state*: VoiceState
    parts*: array[VoiceParts, EventId]  ## the standing parts' event ids ("" for one not yet in)
  ThreadRow* = object
    ## One row of the room's thread: a message, or a note. Only `threadRows` sets `isVoice`.
    id*: string                 ## a message's id, or a note's nid
    author*: string
    ts*: int64
    body*: string               ## a message's body; "" for a note
    isVoice*: bool
    note*: VoiceNote            ## the note, for a voice row

proc hexOf(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc isLowerHex(s: string, n: int): bool =
  s.len == n and s.allCharsInSet({'0' .. '9', 'a' .. 'f'})

proc unhex(s: string): seq[byte] =
  ## Strict: anything but an even run of hex digits is empty.
  if s.len mod 2 != 0 or not s.allCharsInSet(HexDigits): return @[]
  for i in 0 ..< s.len div 2: result.add byte(parseHexInt(s[2*i .. 2*i+1]))

proc clipDigest*(record: openArray[byte]): Sha256Digest =
  ## The clip's digest (§3.2): a domain-separated hash-input record over the record's bytes.
  digest(hashInput(ClipDigestDomain, @[("clip", cbBytes(@record))]))

proc noteIdOf*(author, clipHex: string, ts: int64): string =
  ## The note id every member derives (§3.3): 16 bytes (32 hex) of a hash-input record over
  ## the author's identity, the clip digest (`clipDigest`, as hex) and the note's ts.
  let d = digest(hashInput(NoteIdDomain, @[("author", cbText(author.toLowerAscii)),
                                           ("clip", cbBytes(unhex(clipHex.toLowerAscii))),
                                           ("ts", cbInt(ts))]))
  hexOf(d[0 ..< 16])

proc voiceKey*(nid, author: string, i: int): string =
  "voice/" & nid & "/" & author & "/" & $i & "/" & $VoiceParts

proc voicePartEvents*(author: string, record: seq[byte], ts: int64,
                      durMs: int): tuple[nid: string, events: seq[Event]] =
  ## A note's two parts for any record bytes, unsigned: the first half (the larger) in part
  ## 0, the rest in part 1. `voiceEvents` is what a client sends; this one also builds, from
  ## bytes that are no clip, the parts a fold must refuse. Raises ValueError unless `author`
  ## is a member's identity (128 hex).
  let a = author.toLowerAscii
  if not isLowerHex(a, 128): raise newException(ValueError, "not a member identity: " & author)
  let dg = hexOf(clipDigest(record))
  result.nid = noteIdOf(a, dg, ts)
  let half = (record.len + 1) div 2
  for i, span in [(0, half), (half, record.len)]:
    let (lo, hi) = span
    result.events.add Event(key: voiceKey(result.nid, a, i),
                            value: $(%*{"v": VoiceEventVersion, "ts": ts, "durMs": durMs,
                                        "digest": dg, "part": encode(record[lo ..< hi])}))

proc voiceEvents*(author: string, clip: VoiceClip, ts: int64): tuple[nid: string, events: seq[Event]] =
  ## A note of `clip` in `author`'s name at `ts`, as two unsigned parts and its note id. The
  ## author signs and publishes each (authorship.publishAuthored). Raises ValueError for a
  ## clip no member could read (voice_clip.encodeRecord) or an author that is not an identity.
  voicePartEvents(author, encodeRecord(clip), ts, clip.durationMs)

# ── the fold (§6) ────────────────────────────────────────────────────────────────

type
  Part = object
    id: EventId
    ts: int64
    durMs: int
    digest: string
    bytes: seq[byte]
  Group = object
    nid, author: string
    have: array[VoiceParts, bool]
    part: array[VoiceParts, Part]

proc partKey(key: string): tuple[ok: bool, nid, author: string, i: int] =
  ## Rule 2: exactly voice/<nid>/<author>/<i>/2, a 32-hex nid and a 128-hex author, both
  ## lowercase (as voiceEvents writes them), i "0" or "1".
  let p = key.split('/')
  if p.len != 5 or p[0] != "voice" or p[4] != $VoiceParts: return
  if not (isLowerHex(p[1], 32) and isLowerHex(p[2], 128)): return
  let i = (if p[3] == "0": 0 elif p[3] == "1": 1 else: -1)
  if i < 0: return
  (true, p[1], p[2], i)

proc parsePart(e: Event): tuple[ok: bool, part: Part] =
  ## A part's value: a JSON object of the six fields (authorSig optional here, the room's
  ## view having verified it), v this version, ts an integer, durMs an integer no clip
  ## exceeds (0..VoiceMaxMs), the digest 64 lowercase hex, the half canonical base64.
  ## Anything else is not a part.
  try:
    let j = parseJson(e.value)
    if j.kind != JObject: return
    for k, _ in j:
      if k notin PartFields: return
    let v = j{"v"}
    let ts = j{"ts"}
    let dur = j{"durMs"}
    let dg = j{"digest"}
    let pt = j{"part"}
    if v == nil or v.kind != JInt or v.getBiggestInt() != VoiceEventVersion: return
    if ts == nil or ts.kind != JInt: return
    if dur == nil or dur.kind != JInt or dur.getBiggestInt() notin 0'i64 .. int64(VoiceMaxMs): return
    if dg == nil or dg.kind != JString or not isLowerHex(dg.getStr(), 64): return
    if pt == nil or pt.kind != JString: return
    let raw = decode(pt.getStr())
    if encode(raw) != pt.getStr(): return             # one spelling of the bytes only
    var b = newSeq[byte](raw.len)
    for i, c in raw: b[i] = byte(c)
    (true, Part(id: eventId(e), ts: ts.getBiggestInt(), durMs: int(dur.getBiggestInt()),
                digest: dg.getStr(), bytes: b))
  except CatchableError:
    (false, Part())

proc gather(events: seq[Event]): OrderedTable[(string, string), Group] =
  ## Each (nid, author)'s standing parts. Rule 3: in canonical order, the first well-formed
  ## copy of each part stands, and an equivocating later copy is ignored (as readBlob,
  ## xmr_msig_spend.nim), so every member keeps the same one whatever arrived first.
  var voice: seq[Event]
  for e in events:
    if e.key.startsWith("voice/"): voice.add e
  for e in canonicalOrder(voice):
    let k = partKey(e.key)
    if not k.ok: continue
    let at = (k.nid, k.author)
    if at in result and result[at].have[k.i]: continue
    let (ok, part) = parsePart(e)
    if not ok: continue
    if at notin result: result[at] = Group(nid: k.nid, author: k.author)
    result[at].have[k.i] = true
    result[at].part[k.i] = part

proc judge(g: Group): tuple[kept: bool, note: VoiceNote, record: seq[byte]] =
  ## Rules 4 to 6 for one (nid, author). The note id must derive from the author and a
  ## part's own (digest, ts), else nothing here is a note (squatting); the note is read off
  ## that part. Both parts must agree on ts, length and digest, and the record they make
  ## must match the digest, pass the structural checks (§3.2) and be the length it claims.
  var lead = -1
  for i in 0 ..< VoiceParts:
    if g.have[i] and noteIdOf(g.author, g.part[i].digest, g.part[i].ts) == g.nid:
      lead = i
      break
  if lead < 0: return
  result.kept = true
  let p = g.part[lead]
  result.note = VoiceNote(nid: g.nid, author: g.author, ts: p.ts, durMs: p.durMs)
  for i in 0 ..< VoiceParts:
    if g.have[i]: result.note.parts[i] = g.part[i].id
  if not (g.have[0] and g.have[1]):
    result.note.state = vsArriving
    return
  result.note.state = vsBroken
  let (a, b) = (g.part[0], g.part[1])
  if a.ts != b.ts or a.durMs != b.durMs or a.digest != b.digest: return
  let record = a.bytes & b.bytes
  if hexOf(clipDigest(record)) != a.digest: return
  let (ok, clip, _) = decodeRecord(record)
  if not ok or clip.durationMs != a.durMs: return
  result.note.state = vsComplete
  result.record = record

proc byTsNid(x, y: VoiceNote): int =
  if x.ts != y.ts: cmp(x.ts, y.ts) else: cmp(x.nid, y.nid)

proc reduceVoice*(events: seq[Event]): seq[VoiceNote] =
  ## The room's voice notes, each complete, arriving or broken, ordered by (ts, nid). A pure
  ## function of the event set (invariant 4). Pass the room's authentic view (`roomEvents`).
  for _, g in gather(events):
    let j = judge(g)
    if j.kept: result.add j.note
  result.sort(byTsNid)

proc voiceRecordOf*(events: seq[Event], nid: string): tuple[ok: bool, record: seq[byte]] =
  ## The clip record of the complete note `nid`, exactly the bytes its digest names, as the
  ## fold checked them; not ok for a note that is not complete, or not in the room.
  for _, g in gather(events):
    if g.nid != nid: continue
    let j = judge(g)
    if j.kept and j.note.state == vsComplete: return (true, j.record)
  (false, @[])

# ── thread rows (§7) ─────────────────────────────────────────────────────────────

proc threadRows*(events: seq[Event]): seq[ThreadRow] =
  ## The room's thread: every message (`reduceMessages`, unchanged) and one row per note
  ## (`reduceVoice`), ordered by (ts, id); a message sorts before a note of the same (ts,
  ## id). A note's row names the fold's author, has an empty body, and carries the note in
  ## `note` alone, which no message can set. Pass the room's authentic view.
  for m in reduceMessages(events):
    result.add ThreadRow(id: m.id, author: m.author, ts: m.ts, body: m.body)
  for n in reduceVoice(events):
    result.add ThreadRow(id: n.nid, author: n.author, ts: n.ts, body: "", isVoice: true, note: n)
  result.sort(proc(x, y: ThreadRow): int =
    if x.ts != y.ts: cmp(x.ts, y.ts)
    elif x.id != y.id: cmp(x.id, y.id)
    else: cmp(ord(x.isVoice), ord(y.isVoice)))

proc threadLastTs*(events: seq[Event]): int64 =
  ## The newest row's ts, a note's included (0 when the thread is empty): what moves a room
  ## up the list (coordinate_conversations' lastTs).
  let rows = threadRows(events)
  if rows.len > 0: rows[^1].ts else: 0'i64

proc voiceJson*(n: VoiceNote): JsonNode =
  ## A voice row's `voice` field: the note's metadata, never its audio (§7).
  %*{"v": VoiceEventVersion, "note": n.nid, "durationMs": n.durMs, "state": $n.state}

proc rowJson*(r: ThreadRow): JsonNode =
  ## A row as coordinate_messages serves it, before the hosted layer adds `alias` and
  ## `self`: {id, author, ts, body}, and `voice` on a note's row only.
  result = %*{"id": r.id, "author": r.author, "ts": r.ts, "body": r.body}
  if r.isVoice: result["voice"] = voiceJson(r.note)
