## Voice notes' hosted half (docs/design/voice-notes.md §8, §9; S7): `VoiceRecorder`, the state
## machine the six voice methods and voice_status run, over the AudioIo seam, the room's session
## and the member's keystore. Two members over LocalTransport, each with a recorder of their own
## on SyntheticAudioIo and a virtual clock (FileAudioIo in §12, miniaudio's null device in §13),
## so the cap, the draft, every refusal and playback are held on a clock the test owns, and
## libopus encodes and decodes for real. No seam is mocked.
##   1. Alice records 3.000 s of a 1 kHz tone and stops: a draft of 3,000 ms; she sends it: two
##      frames of 90,153 B; Bob's thread holds one complete voice row of hers, metadata only;
##      Bob plays it: his sink holds exactly the clip's samples, with a 1 kHz Goertzel peak, and
##      once the pump sees done he is idle again, the device released
##   2. the cap: a 70 s source stops at 60,000 ms with `capped`, the device released by the pump
##      alone; Stop then hands back that draft, and it sends
##   3. an all-zero source: the draft is silent, peak 0; Send refuses `silent` with the platform
##      note as its `detail` (the macOS words on macOS, `hostOS` choosing), keeps the draft, and
##      nothing reaches the log, its heads or the topic
##   4. under 500 ms: `too-short`, nothing published; 500 ms exactly sends
##   5. busy: start while recording, playing or a draft is held; play while recording or
##      playing; send with no draft is `no-draft`; stop with nothing recording `not-recording`
##   6. no room: start, send and play a note refuse `not-joined`, and nothing opens
##   7. play refusals: an unknown note `unknown-note`, an arriving one `incomplete`, a broken one
##      `broken`, and a note the fold calls complete whose packets libopus refuses `broken`
##   8. (run last, over every reply the others got) no JSON any call returns carries audio or a
##      float, in every state: no `part`, no run of base64 characters over 64, under 1 KB
##   9. encoding is incremental: after each 1 s of pumps everything captured is encoded, so after
##      59 s Stop encodes the last 0.5 s alone
##  10. discard drops the draft (and a recording in progress): later Play("draft") and Send say
##      `no-draft`
##  11. the memo: the thread's rows judge a note's clip once per pair of standing parts, then
##      serve the verdict; one memo per room
##  12. which AudioIo the module makes (MUSTER_VOICE_SOURCE / _SINK, MUSTER_VOICE_BACKEND), and
##      FileAudioIo end to end: a WAV source recorded, sent, played into a raw PCM sink; a
##      missing source refused `no-source`, which `ready.capture` then says
##  13. miniaudio's null device: a real device thread captures zeros, so Send refuses `silent`;
##      the context is released when the stream ends
##  14. close stops what runs and releases the device; it is idempotent
##  15. a Send that fails between its two parts (the delivery raising on the second) keeps the
##      draft, and its retry, at a later clock, sends the same note: the first part again on
##      the held path and the second, so the other member holds one complete note, not a
##      stranded part beside a second note
## Needs libopus, libsecp256k1, libsodium and the miniaudio pin (run-suite.sh links them all).

import std/[json, math, os, strutils, sequtils, tables]
import ../src/transport/transport
import ../src/crypto/epoch_crypto
import ../src/crypto/keystore
import ../src/crypto/curve25519
import ../src/audio/[audio_io, voice_clip, voice_codec, miniaudio]
import ../src/coordination/session
import ../src/coordination/authorship
import ../src/coordination/voice
import ../src/coordination/voice_live

proc seed(b: byte): array[32, byte] = (for i in 0 ..< 32: result[i] = b)
proc hex(b: openArray[byte]): string =
  const d = "0123456789abcdef"
  for x in b: (result.add d[int(x shr 4)]; result.add d[int(x and 0x0F)])

proc sine(freq: float, n: int, amp = 0.5): seq[int16] =
  result = newSeq[int16](n)
  for i in 0 ..< n:
    result[i] = int16(amp * 32767.0 * sin(2.0 * PI * freq * float(i) / float(ClipRate)))

proc goertzel(x: openArray[int16], freq: float): float =
  ## The signal's power at one frequency.
  let k = 2.0 * cos(2.0 * PI * freq / float(ClipRate))
  var s1, s2 = 0.0
  for v in x:
    let s0 = float(v) + k * s1 - s2
    s2 = s1
    s1 = s0
  (s1 * s1 + s2 * s2 - k * s1 * s2) / (float(x.len) * float(x.len))

let aliceKs = newInMemoryKeystore(seed(0x71), seed(0x81))
let bobKs   = newInMemoryKeystore(seed(0x72), seed(0x82))
let alice   = hex(aliceKs.encIdentity().toBytes())

const topic = "/muster/1/room-voice-live/proto"
const WireBytes = 1 + 24 + 16 + 90_112
const Second = ClipRate                  ## samples in a second

type Wire = ref object
  frames: seq[seq[byte]]

proc tap(net: LocalNetwork, topic: string): Wire =
  let w = Wire()
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    w.frames.add m.payload)
  w

proc dataFrames(w: Wire): seq[seq[byte]] =
  for f in w.frames: (if f.len > 0 and f[0] == 0x00'u8: result.add f)

type Refuser = ref object
  left: int   ## voice frames to let through before one is refused; -1 refuses none

proc refuser(net: LocalNetwork, topic: string): Refuser =
  ## A subscriber on the topic that raises on a voice frame once armed, as a failing send
  ## raises to its publisher: LocalTransport carries the raise back through `publish`.
  let r = Refuser(left: -1)
  newLocalTransport(net).subscribe(topic, proc (m: IncomingMessage) {.gcsafe.} =
    if m.payload.len == WireBytes and r.left >= 0:
      if r.left == 0:
        r.left = -1
        raise newException(IOError, "the delivery node refused the frame")
      dec r.left)
  r

let net = newLocalNetwork()
let aliceCrypto = newEpochCrypto(aliceKs, topic, @[bobKs.encIdentity()])
let bobCrypto = newEpochJoiner(bobKs)
bobCrypto.ingestGrant(aliceCrypto.grantFor(0, bobKs.encIdentity()))
let aliceS = newCoordinationSession(newLocalTransport(net), aliceCrypto, topic)
let bobS = newCoordinationSession(newLocalTransport(net), bobCrypto, topic)
let wire = tap(net, topic)

var seen: seq[JsonNode]   ## every JSON a call returned, for §8
proc ck(j: JsonNode): JsonNode = (seen.add j; j)
proc status(v: VoiceRecorder): JsonNode = ck(v.voiceStatus())
proc err(j: JsonNode): string = j{"error"}.getStr()
proc ok(j: JsonNode): bool = j{"ok"}.getBool() and j{"error"} == nil

proc noteRow(rows: seq[ThreadRow], nid: string): ThreadRow =
  var n = 0
  for r in rows:
    if r.isVoice and r.id == nid: (result = r; inc n)
  doAssert n == 1, "one voice row " & nid & ", not " & $n

var ts = 1_792_100_000'i64
proc nextTs(): int64 = (ts += 10; ts)

proc recordFor(v: VoiceRecorder, vc: VirtualClock, s: CoordinationSession, ms: int): JsonNode =
  ## Start, let `ms` pass on the clock with a status read each second, then Stop.
  doAssert v.recordStart(s).ck.ok
  var left = ms
  while left > 0:
    let step = min(left, 1000)
    vc.advance(step)
    left -= step
    discard v.status()
  v.recordStop().ck

# ── 1. record → draft → send → the other member plays ──────────────────────────────
var nid1 = ""
block:
  let tone = sine(1000.0, 3 * Second)
  let vcA = VirtualClock(ms: 5_000)
  let ioA = newSyntheticAudioIo(tone, vcA.clock)
  let a = newVoiceRecorder(ioA)
  var st = a.status()
  doAssert st["recording"]["state"].getStr() == "idle" and st["playing"].kind == JNull, $st
  doAssert st["ready"]["capture"].getStr() == "unknown" and st["ready"]["codec"].getStr() == opusVersion()
  doAssert a.recordStart(aliceS).ck.ok
  doAssert ioA.stream == asCapture
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "recording" and st["ready"]["capture"].getStr() == "ok", $st
  vcA.advance(1_000)
  st = a.status()
  doAssert st["recording"]["elapsedMs"].getInt() == 1_000, $st
  doAssert st["recording"]["peak"].getInt() > 10_000, "a tone at half scale: " & $st
  doAssert a.status()["recording"]["peak"].getInt() == 0, "the peak is reset when read, nothing new since"
  vcA.advance(2_000)
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() == 3_000, $stop
  doAssert not stop["draft"]["silent"].getBool() and stop["draft"]["peak"].getInt() > 10_000, $stop
  doAssert ioA.stream == asIdle, "the capture is released at Stop"
  st = a.status()
  doAssert st["recording"]["state"].getStr() == "draft" and st["recording"]["elapsedMs"].getInt() == 3_000, $st
  let before = wire.dataFrames().len
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  nid1 = sent{"note"}.getStr()
  doAssert nid1.len == 32, $sent
  let frames = wire.dataFrames()[before .. ^1]
  doAssert frames.len == 2 and frames.allIt(it.len == WireBytes), "two frames of 90,153 B: " & $frames.mapIt(it.len)
  doAssert a.status()["recording"]["state"].getStr() == "idle", "sent: no draft held"
  # Bob's thread: one voice row, Alice's, complete, metadata only
  let vcB = VirtualClock(ms: 9_000)
  let ioB = newSyntheticAudioIo(@[], vcB.clock)
  let b = newVoiceRecorder(ioB)
  let row = noteRow(b.rows(bobS), nid1)
  doAssert row.author == alice and row.body == "" and row.note.state == vsComplete, $row
  let rj = rowJson(row)
  doAssert rj["voice"] == %*{"v": 1, "note": nid1, "durationMs": 3_000, "state": "complete"}, $rj
  # Bob plays it
  doAssert b.play(bobS, nid1).ck.ok
  doAssert ioB.stream == asPlayback
  st = b.status()
  doAssert st["playing"] == %*{"note": nid1, "positionMs": 0, "durationMs": 3_000}, $st
  doAssert st["ready"]["playback"].getStr() == "ok" and st["recording"]["state"].getStr() == "idle", $st
  vcB.advance(1_500)
  doAssert b.status()["playing"]["positionMs"].getInt() == 1_500
  vcB.advance(1_600)
  st = b.status()
  doAssert st["playing"].kind == JNull, "done: idle again: " & $st
  doAssert ioB.stream == asIdle, "the playback is released once the pump sees done"
  let (okR, record) = voiceRecordOf(bobS.roomEvents(), nid1)
  doAssert okR
  let (okD, pcm, _) = decodeClip(record)
  doAssert okD and pcm.len == 3 * Second
  doAssert ioB.played == pcm, "the sink holds exactly the clip's samples: " & $ioB.played.len
  let p1k = goertzel(ioB.played, 1000.0)
  doAssert p1k > 0.25 * goertzel(tone, 1000.0), $p1k
  doAssert goertzel(ioB.played, 3100.0) < 0.01 * p1k, "the power is at 1 kHz"
  echo "1. a 3 s tone recorded, sent as two 90153 B frames, played by the other member: ",
       "the clip's samples exactly, 1 kHz; idle after done OK"

# ── 2. the 60 s cap ─────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(440.0, 70 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  var st: JsonNode
  for s in 1 .. 70:
    vc.advance(1_000)
    st = a.status()
    if s < 60:
      doAssert st["recording"]["state"].getStr() == "recording" and not st["recording"]["capped"].getBool(), $s & ": " & $st
  doAssert st["recording"]["state"].getStr() == "draft", "the cap made the draft: " & $st
  doAssert st["recording"]["capped"].getBool() and st["recording"]["elapsedMs"].getInt() == 60_000, $st
  doAssert st["recording"]["capMs"].getInt() == 60_000
  doAssert io.stream == asIdle, "the pump released the device at the cap"
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() == 60_000, "Stop hands back the capped draft: " & $stop
  let sent = a.draftSend(aliceS, aliceKs, nextTs()).ck
  let nid = sent{"note"}.getStr()
  doAssert nid.len == 32, $sent
  let row = noteRow(threadRows(bobS.roomEvents()), nid)
  doAssert row.note.state == vsComplete and row.note.durMs == 60_000, $row
  echo "2. a 70 s source stops at 60000 ms, capped, released by the pump; it sends OK"

# ── 3. an all-zero recording ────────────────────────────────────────────────────────
block:
  doAssert platformNote("macosx") ==
    "Basecamp 0.3.2 can't use the microphone on macOS yet: it lacks the microphone permission."
  doAssert platformNote("linux") == ""
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(newSeq[int16](2 * Second), vc.clock))
  let stop = a.recordFor(vc, aliceS, 2_000)
  doAssert stop["draft"]["durationMs"].getInt() == 2_000 and stop["draft"]["silent"].getBool(), $stop
  doAssert stop["draft"]["peak"].getInt() == 0, $stop
  let frames = wire.frames.len
  let heads = aliceS.heads()
  let digest = aliceS.digest()
  let r = a.draftSend(aliceS, aliceKs, nextTs()).ck
  doAssert r.err == "silent" and r{"detail"}.getStr() == platformNote(), $r
  doAssert wire.frames.len == frames, "nothing reached the topic"
  doAssert aliceS.heads() == heads and aliceS.digest() == digest, "nothing reached the log"
  let st = a.status()
  doAssert st["recording"]["state"].getStr() == "draft" and st["recording"]["silent"].getBool(), "the draft stays: " & $st
  doAssert st["ready"]["note"].getStr() == platformNote(), $st
  doAssert a.draftDiscard() == "ok"
  echo "3. an all-zero recording: Send refuses silent with the platform note (\"", platformNote(),
       "\"), nothing published OK"

# ── 4. under 500 ms ─────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, Second), vc.clock))
  doAssert a.recordFor(vc, aliceS, VoiceMinMs - 1)["draft"]["durationMs"].getInt() == 499
  let frames = wire.frames.len
  let digest = aliceS.digest()
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "too-short"
  doAssert wire.frames.len == frames and aliceS.digest() == digest, "nothing published"
  doAssert a.draftDiscard() == "ok"
  doAssert a.recordFor(vc, aliceS, VoiceMinMs)["draft"]["durationMs"].getInt() == 500
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck{"note"}.getStr().len == 32, "500 ms sends"
  doAssert wire.frames.len == frames + 2
  echo "4. 499 ms is too-short and publishes nothing; 500 ms sends OK"

# ── 5. busy ─────────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStop().ck.err == "not-recording"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft"
  doAssert a.recordStart(aliceS).ck.ok
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while recording"
  doAssert a.play(aliceS, nid1).ck.err == "busy", "play while recording"
  doAssert a.play(aliceS, "draft").ck.err == "busy", "play the draft while recording"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft", "send with no draft"
  vc.advance(1_000)
  doAssert a.recordStop().ck["draft"]["durationMs"].getInt() == 1_000
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while a draft is held"
  doAssert a.play(aliceS, "draft").ck.ok
  doAssert a.status()["playing"]["note"].getStr() == "draft"
  doAssert a.recordStart(aliceS).ck.err == "busy", "start while playing"
  doAssert a.play(aliceS, nid1).ck.err == "busy", "play while playing"
  doAssert a.playStop() == "ok" and a.playStop() == "ok"
  let st = a.status()
  doAssert st["playing"].kind == JNull and st["recording"]["state"].getStr() == "draft", "back where it was: " & $st
  doAssert io.stream == asIdle
  doAssert a.play(aliceS, nid1).ck.ok, "a note plays beside a held draft"
  vc.advance(4_000)
  doAssert a.status()["playing"].kind == JNull
  doAssert a.status()["recording"]["state"].getStr() == "draft"
  doAssert a.draftDiscard() == "ok"
  doAssert a.recordStart(aliceS).ck.ok, "idle again: a recording starts"
  doAssert a.draftDiscard() == "ok"
  echo "5. busy while recording, playing or holding a draft; no-draft; not-recording OK"

# ── 6. no room joined ───────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(nil).ck.err == "not-joined"
  doAssert io.stream == asIdle and a.status()["ready"]["capture"].getStr() == "unknown", "nothing opened"
  doAssert a.play(nil, nid1).ck.err == "not-joined"
  doAssert io.stream == asIdle
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.draftSend(nil, aliceKs, nextTs()).ck.err == "not-joined"
  doAssert a.status()["recording"]["state"].getStr() == "draft", "the draft stays"
  doAssert a.play(nil, "draft").ck.ok, "a draft plays with no room"
  doAssert a.playStop() == "ok" and a.draftDiscard() == "ok"
  echo "6. no room: start, send and play a note refuse not-joined, nothing opened OK"

# ── 7. play refusals ────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(@[], vc.clock)
  let b = newVoiceRecorder(io)
  doAssert b.play(bobS, "0f".repeat(16)).ck.err == "unknown-note"
  # arriving: one part of a real clip
  let (okE, clip, _) = encodeClip(sine(1000.0, Second))
  doAssert okE
  let (nidA, partsA) = voiceEvents(alice, clip, nextTs())
  aliceS.publishAuthored(aliceKs, partsA[0])
  doAssert noteRow(b.rows(bobS), nidA).note.state == vsArriving
  doAssert b.play(bobS, nidA).ck.err == "incomplete"
  # broken: two halves of bytes that are no record
  let junk = toSeq(0'u8 .. 199'u8)
  let (nidB, partsB) = voicePartEvents(alice, junk, nextTs(), 1_000)
  for e in partsB: aliceS.publishAuthored(aliceKs, e)
  doAssert noteRow(b.rows(bobS), nidB).note.state == vsBroken
  doAssert b.play(bobS, nidB).ck.err == "broken"
  # complete to the fold, which decodes no audio, but its packets are not Opus libopus reads
  var fake = VoiceClip(preskip: 312, samples: Second)
  for i in 0 ..< packetCount(Second, 312): fake.packets.add newSeqWith(PacketBytes, 0xFF'u8)
  let (nidF, partsF) = voiceEvents(alice, fake, nextTs())
  for e in partsF: aliceS.publishAuthored(aliceKs, e)
  doAssert noteRow(b.rows(bobS), nidF).note.state == vsComplete
  doAssert not decodeClip(encodeRecord(fake)).ok
  doAssert b.play(bobS, nidF).ck.err == "broken"
  doAssert io.stream == asIdle and b.status()["playing"].kind == JNull, "no refusal opened a device"
  echo "7. play refuses unknown-note, incomplete, broken, and broken for packets libopus refuses OK"

# ── 9. incremental encoding ─────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 60 * Second), vc.clock))
  doAssert a.recordStart(aliceS).ck.ok
  doAssert a.encodedMs() == 0
  for s in 1 .. 59:
    vc.advance(1_000)
    discard a.status()
    doAssert a.encodedMs() == s * 1_000, $s & " s of pumps: " & $a.encodedMs() & " ms encoded"
  vc.advance(500)
  doAssert a.encodedMs() == 59_000, "Stop finds 0.5 s left to encode"
  doAssert a.recordStop().ck["draft"]["durationMs"].getInt() == 59_500
  doAssert a.encodedMs() == 59_500
  doAssert a.draftDiscard() == "ok"
  echo "9. each pump encodes what was captured: after 59 s Stop encodes the last 0.5 s alone OK"

# ── 10. discard ─────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  discard a.recordFor(vc, aliceS, 1_000)
  doAssert a.draftDiscard() == "ok" and a.draftDiscard() == "ok"
  doAssert a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.play(aliceS, "draft").ck.err == "no-draft"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "no-draft"
  doAssert a.recordStart(aliceS).ck.ok
  vc.advance(700)
  doAssert a.draftDiscard() == "ok", "a recording in progress is dropped too"
  doAssert io.stream == asIdle and a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.recordStop().ck.err == "not-recording"
  echo "10. discard drops the draft and a recording; then play(draft) and send say no-draft OK"

# ── 11. the memo ────────────────────────────────────────────────────────────────────
block:
  let b = newVoiceRecorder(newSyntheticAudioIo(@[], VirtualClock().clock))
  let first = b.rows(bobS)
  let memo = b.memoFor(bobS)
  var pairs = 0
  for n in reduceVoice(bobS.roomEvents()):
    if n.parts[0].len > 0 and n.parts[1].len > 0: inc pairs
  doAssert pairs >= 4 and memo.len == pairs and memo.hits == 0, $pairs & " " & $memo.len & " " & $memo.hits
  let second = b.rows(bobS)
  doAssert second == first and memo.hits == pairs, "every verdict served from the memo: " & $memo.hits
  let elsewhere = newCoordinationSession(newLocalTransport(net),
                                         newEpochCrypto(bobKs, "/muster/1/another-room/proto", @[]),
                                         "/muster/1/another-room/proto")
  doAssert b.memoFor(bobS) == memo and b.memoFor(elsewhere) != memo, "one memo per room"
  doAssert first == threadRows(bobS.roomEvents()), "the memo changes no row"
  echo "11. the thread's rows judge each pair of parts once, then serve the memo's verdict OK"

# ── 12. which AudioIo, and FileAudioIo end to end ───────────────────────────────────
block:
  doAssert voiceIoChoice("", "", "") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("", "", "null") == (kind: vkNull, source: "", sink: "")
  doAssert voiceIoChoice("", "", "system") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("", "", "pulse") == (kind: vkSystem, source: "", sink: "")
  doAssert voiceIoChoice("/a.wav", "", "null") == (kind: vkFile, source: "/a.wav", sink: "")
  doAssert voiceIoChoice("", "/b.pcm", "") == (kind: vkFile, source: "", sink: "/b.pcm")
  let dir = getTempDir() / ("muster_voice_live_test_" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  proc le16(v: int): string = char(v and 0xFF) & char((v shr 8) and 0xFF)
  proc le32(v: int): string = le16(v and 0xFFFF) & le16((v shr 16) and 0xFFFF)
  let tone = sine(1000.0, Second)
  var data = ""
  for s in tone: data.add le16(int(cast[uint16](s)))
  let fmt = "fmt " & le32(16) & le16(1) & le16(1) & le32(ClipRate) & le32(ClipRate * 2) & le16(2) & le16(16)
  writeFile(dir / "tone.wav", "RIFF" & le32(4 + fmt.len + 8 + data.len) & "WAVE" & fmt & "data" & le32(data.len) & data)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newFileAudioIo(dir / "tone.wav", "", vc.clock))
  doAssert a.recordFor(vc, aliceS, 1_000)["draft"]["durationMs"].getInt() == 1_000
  let nid = a.draftSend(aliceS, aliceKs, nextTs()).ck{"note"}.getStr()
  doAssert nid.len == 32
  let b = newVoiceRecorder(newFileAudioIo("", dir / "sink.pcm", vc.clock))
  doAssert b.play(bobS, nid).ck.ok
  vc.advance(1_100)
  doAssert b.status()["playing"].kind == JNull
  let (_, pcm, _) = decodeClip(voiceRecordOf(bobS.roomEvents(), nid).record)
  var want = ""
  for s in pcm: want.add le16(int(cast[uint16](s)))
  doAssert readFile(dir / "sink.pcm") == want, "the sink holds the clip's samples, s16le"
  let none = newVoiceRecorder(newFileAudioIo(dir / "missing.wav", "", vc.clock))
  doAssert none.recordStart(aliceS).ck.err == "no-source"
  let st = none.status()
  doAssert st["ready"]["capture"].getStr() == "no-source" and st["recording"]["state"].getStr() == "idle", $st
  echo "12. the env picks FileAudioIo, miniaudio null or the system; a WAV recorded, sent and played ",
       "into a PCM sink; a missing source is no-source OK"

# ── 13. miniaudio's null device ─────────────────────────────────────────────────────
block:
  let io = newMiniaudioIo(abNull)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  doAssert io.backendName() == "Null"
  for _ in 0 ..< 8:
    sleep(100)
    discard a.status()
  let stop = a.recordStop().ck
  doAssert stop["draft"]["durationMs"].getInt() in 500 .. 3_000, $stop
  doAssert stop["draft"]["silent"].getBool() and stop["draft"]["peak"].getInt() == 0, "the null device captures zeros: " & $stop
  doAssert io.backendName() == "", "the context is released when the stream ends"
  doAssert a.draftSend(aliceS, aliceKs, nextTs()).ck.err == "silent"
  doAssert a.draftDiscard() == "ok" and a.close() == "ok"
  echo "13. miniaudio's null device: zeros, refused silent; the context released after Stop OK"

# ── 14. close ───────────────────────────────────────────────────────────────────────
block:
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(sine(1000.0, 5 * Second), vc.clock)
  let a = newVoiceRecorder(io)
  doAssert a.recordStart(aliceS).ck.ok
  vc.advance(600)
  doAssert a.close() == "ok"
  doAssert io.stream == asIdle and a.status()["recording"]["state"].getStr() == "idle"
  doAssert a.play(bobS, nid1).ck.ok
  doAssert a.close() == "ok" and a.close() == "ok"
  doAssert io.stream == asIdle and a.status()["playing"].kind == JNull
  echo "14. close stops what runs and releases the device, idempotently OK"

# ── 15. a Send that fails between its parts, retried ────────────────────────────────
block:
  const topic2 = "/muster/1/room-voice-retry/proto"
  let ac = newEpochCrypto(aliceKs, topic2, @[bobKs.encIdentity()])
  let bc = newEpochJoiner(bobKs)
  bc.ingestGrant(ac.grantFor(0, bobKs.encIdentity()))
  let a2 = newCoordinationSession(newLocalTransport(net), ac, topic2)
  let refuse = refuser(net, topic2)       # subscribed before Bob: he never sees what it refuses
  let b2 = newCoordinationSession(newLocalTransport(net), bc, topic2)
  let vc = VirtualClock()
  let a = newVoiceRecorder(newSyntheticAudioIo(sine(1000.0, 2 * Second), vc.clock))
  discard a.recordFor(vc, a2, 1_000)
  refuse.left = 1                         # part 0 goes out, part 1 is refused
  doAssertRaises(IOError): discard a.draftSend(a2, aliceKs, nextTs())
  let first = reduceVoice(b2.roomEvents())
  doAssert first.len == 1 and first[0].state == vsArriving, "Bob holds part 0 alone: " & $first
  doAssert a.status()["recording"]["state"].getStr() == "draft", "the draft is kept"
  let sent = a.draftSend(a2, aliceKs, nextTs()).ck
  doAssert sent{"note"}.getStr() == first[0].nid, "the retry sends the same note: " & $sent
  let after = reduceVoice(b2.roomEvents())
  doAssert after.len == 1 and after[0].state == vsComplete and after[0].nid == first[0].nid, $after
  doAssert a.status()["recording"]["state"].getStr() == "idle"
  echo "15. a Send refused between its parts keeps the draft; the retry sends the same note, ",
       "complete, nothing stranded OK"

# ── 8. no JSON carries audio or a float ─────────────────────────────────────────────
block:
  proc walk(j: JsonNode, path: string) =
    case j.kind
    of JFloat: doAssert false, path & " is a float: " & $j
    of JObject:
      for k, v in j:
        doAssert k != "part", path & " carries a part"
        walk(v, path & "." & k)
    of JArray:
      for i, v in j.elems: walk(v, path & "[" & $i & "]")
    of JString:
      var run = 0
      for c in j.getStr():
        run = (if c in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '+', '/', '='}: run + 1 else: 0)
        doAssert run <= 64, path & ": a base64 run over 64 characters"
    else: discard
  var states: CountTable[string]
  for j in seen:
    walk(j, "$")
    doAssert ($j).len < 1024, "bounded: " & $($j).len & " B"
    if j{"recording"} != nil:
      states.inc j["recording"]["state"].getStr()
      if j["playing"].kind != JNull: states.inc "playing"
  for s in ["idle", "recording", "draft", "playing"]:
    doAssert states[s] > 0, "no status was read in state " & s
  echo "8. ", seen.len, " JSON replies, every state: no part, no base64 run over 64, no float, under 1 KB OK"

echo "voice_live_test: all OK"
