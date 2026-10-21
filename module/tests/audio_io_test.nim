## The audio seam (docs/design/voice-notes.md §9) on its two in-process implementations, with
## no device: SyntheticAudioIo (deterministic PCM on a virtual clock, a collecting sink) and
## FileAudioIo (a 48 kHz mono s16 WAV source, a raw PCM sink). Both move samples through
## `captureInto` / `playFrom`, the procs the miniaudio device callback runs, so the cap,
## `capped`, the peak and `done` are held here on a clock the test owns. The real device
## thread runs in audio_io_null_test. Pure Nim: no libopus, no miniaudio.

import std/os
import ../src/audio/[audio_io, voice_clip]

proc ramp(n: int): seq[int16] =
  ## Deterministic and never constant: a sawtooth through both signs.
  result = newSeq[int16](n)
  for i in 0 ..< n: result[i] = int16((i * 37) mod 2001 - 1000)

proc le16(v: int): string = char(v and 0xFF) & char((v shr 8) and 0xFF)
proc le32(v: int): string = le16(v and 0xFFFF) & le16((v shr 16) and 0xFFFF)

proc pcmBytes(pcm: openArray[int16]): string =
  ## Little-endian s16, two bytes a sample: what a raw PCM sink must hold.
  for s in pcm: result.add le16(int(cast[uint16](s)))

proc wav(pcm: openArray[int16], rate = ClipRate, channels = 1, bits = 16, format = 1,
         extra = ""): string =
  ## A RIFF/WAVE file: "fmt " (16 bytes), then `extra` (whole chunks), then "data".
  let data = pcmBytes(pcm)
  let fmt = "fmt " & le32(16) & le16(format) & le16(channels) & le32(rate) &
            le32(rate * channels * bits div 8) & le16(channels * bits div 8) & le16(bits)
  let body = "WAVE" & fmt & extra & "data" & le32(data.len) & data
  "RIFF" & le32(body.len) & body

let dir = getTempDir() / ("muster_audio_io_test_" & $getCurrentProcessId())
createDir(dir)

# 1. A capture fills exactly to the cap and sets `capped`. The source runs on the virtual
#    clock, 48 frames a millisecond; the write index only grows, never past the cap, and
#    `capped` is set exactly when the buffer is full. Frames past the cap are dropped (the
#    source runs on), so a 60 s buffer cannot overflow however late the module thread drains
#    it (§9). The drained samples are the source's first `cap`, in order.
block:
  let vc = VirtualClock()
  let src = ramp(10_000)
  let io = newSyntheticAudioIo(src, vc.clock)
  let buf = newAudioBuffer(4_800)                       # 100 ms
  doAssert io.startCapture(buf) == ""
  doAssert io.stream == asCapture
  doAssert io.startCapture(buf) == "busy"
  doAssert io.startPlayback(buf) == "busy"
  var t, last = 0
  var drained: seq[int16]
  for step in [0, 1, 7, 13, 29, 3, 41, 2, 4, 50, 1_000]:
    vc.advance(step)
    t += step
    doAssert io.pump() == ""
    let w = buf.written
    doAssert w >= last, "the write index went back: " & $last & " then " & $w
    doAssert w == min(t * ClipRate div 1000, buf.cap), $t & " ms: " & $w
    doAssert buf.capped == (w == buf.cap), $w
    last = w
    drained.add buf.takeCaptured()
  doAssert buf.written == 4_800 and buf.capped
  doAssert drained == src[0 ..< 4_800]
  vc.advance(500)
  doAssert io.pump() == ""
  doAssert buf.written == 4_800 and buf.takeCaptured().len == 0
  doAssert io.stopCapture() == "" and io.stopCapture() == ""
  doAssert io.stream == asIdle
  # one jump far past the cap writes exactly the cap, from a reset buffer
  doAssert io.startCapture(buf) == ""
  doAssert buf.written == 0 and not buf.capped
  vc.advance(60_000)
  doAssert io.pump() == ""
  doAssert buf.written == 4_800 and buf.capped
  doAssert buf.takeCaptured() == src[0 ..< 4_800]
  doAssert io.close() == "" and io.close() == ""
  freeAudioBuffer(buf)
echo "1. capture: paced 48 frames/ms, write index monotone, exactly the cap, capped; busy OK"

# 2. The peak: the largest |sample| written since the last read, reset by reading it. The most
#    negative s16 reads 32768, not a wrapped value. Silence past the source's end reads 0.
block:
  var src = newSeq[int16](1_440)
  for i in 0 ..< 480: src[i] = (if i mod 2 == 0: 1_000'i16 else: -999'i16)
  for i in 480 ..< 960: src[i] = (if i == 700: low(int16) else: 5'i16)
  for i in 960 ..< 1_440: src[i] = 300
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(src, vc.clock)
  let buf = newAudioBuffer(ClipRate)
  doAssert io.startCapture(buf) == ""
  doAssert buf.takePeak() == 0
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 1_000
  doAssert buf.takePeak() == 0, "read once, the peak resets"
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 32_768
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.takePeak() == 300
  vc.advance(10)
  doAssert io.pump() == ""
  doAssert buf.written == 1_920 and buf.takePeak() == 0
  doAssert io.stopCapture() == ""
  freeAudioBuffer(buf)
echo "2. peak: 1000, reset to 0 on read, 32768 for int16.low, 300, 0 for silence OK"

# 3. Playback consumes the whole buffer at the clock's pace, then reports `done`. The
#    collecting sink holds exactly what was loaded. `playFrom`, the callback's half, writes
#    zeros past the end of what was loaded and sets `done` once it is consumed.
block:
  let pcm = ramp(2_000)
  let vc = VirtualClock()
  let io = newSyntheticAudioIo(@[], vc.clock)
  let buf = newAudioBuffer(4_800)
  doAssert buf.loadPlayback(pcm) == 2_000
  doAssert io.startPlayback(buf) == ""
  doAssert io.stream == asPlayback
  doAssert io.startPlayback(buf) == "busy"
  doAssert io.startCapture(buf) == "busy"
  var t = 0
  for step in [10, 10, 5, 3]:
    vc.advance(step)
    t += step
    doAssert io.pump() == ""
    doAssert buf.readIndex == t * ClipRate div 1000 and not buf.done, $buf.readIndex
  vc.advance(100)
  doAssert io.pump() == ""
  doAssert buf.done and buf.readIndex == 2_000
  doAssert io.played == pcm
  vc.advance(100)
  doAssert io.pump() == "" and io.played == pcm
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert io.stream == asIdle
  doAssert buf.loadPlayback(ramp(6_000)) == 4_800, "a load longer than the buffer stops at its cap"
  # the device-thread half on its own
  doAssert buf.loadPlayback(pcm) == 2_000
  var output = newSeq[int16](3_000)
  for x in output.mitems: x = 7
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[0]), 1_500) == 1_500
  doAssert not buf.done and output[0 ..< 1_500] == pcm[0 ..< 1_500]
  doAssert buf.playFrom(cast[ptr UncheckedArray[int16]](addr output[1_500]), 1_500) == 500
  doAssert buf.done and buf.readIndex == 2_000
  doAssert output[1_500 ..< 2_000] == pcm[1_500 ..< 2_000]
  for i in 2_000 ..< 3_000: doAssert output[i] == 0, "past the end: silence, at " & $i
  freeAudioBuffer(buf)
echo "3. playback: paced, the whole buffer then done; the sink holds it exactly; zeros past the end OK"

# 4. A WAV source is paced by the given clock, then silent past its end, as a microphone
#    in a quiet room. Anything but 48 kHz mono s16 PCM is refused as `wav-format`, a file cut
#    short as `wav-truncated`, a missing one as `no-source`; a refused start opens nothing.
block:
  let pcm = ramp(9_600)                                 # 200 ms
  writeFile(dir / "ok.wav", wav(pcm, extra = "LIST" & le32(4) & "INFO"))
  let vc = VirtualClock()
  let io = newFileAudioIo(dir / "ok.wav", "", vc.clock)
  let buf = newAudioBuffer(ClipRate)
  doAssert io.startCapture(buf) == ""
  doAssert io.pump() == "" and buf.written == 0, "nothing before the clock moves"
  vc.advance(50)
  doAssert io.pump() == "" and buf.written == 2_400
  vc.advance(150)
  doAssert io.pump() == "" and buf.written == 9_600
  vc.advance(100)
  doAssert io.pump() == "" and buf.written == 14_400
  let got = buf.takeCaptured()
  doAssert got[0 ..< 9_600] == pcm
  for i in 9_600 ..< 14_400: doAssert got[i] == 0, "past the file's end: silence, at " & $i
  doAssert io.stopCapture() == ""
  let whole = wav(pcm)
  for (name, bytes, want) in [
      ("44k1", wav(pcm, rate = 44_100), "wav-format"),
      ("stereo", wav(pcm, channels = 2), "wav-format"),
      ("u8", wav(pcm, bits = 8), "wav-format"),
      ("float", wav(pcm, format = 3), "wav-format"),
      ("rifx", "RIFX" & whole[4 .. ^1], "wav-format"),
      ("odd-data", whole[0 ..< 40] & le32(19_199) & whole[44 .. ^2], "wav-format"),
      ("riff-only", whole[0 ..< 11], "wav-truncated"),
      ("fmt-cut", whole[0 ..< 30], "wav-truncated"),
      ("no-data", whole[0 ..< 36], "wav-truncated"),
      ("data-cut", whole[0 ..< 44 + 101], "wav-truncated")]:
    writeFile(dir / name & ".wav", bytes)
    let bad = newFileAudioIo(dir / name & ".wav", "", vc.clock)
    let why = bad.startCapture(buf)
    doAssert why == want, name & ": " & why
    doAssert bad.stream == asIdle, name
  doAssert newFileAudioIo(dir / "missing.wav", "", vc.clock).startCapture(buf) == "no-source"
  doAssert newFileAudioIo("", "", vc.clock).startCapture(buf) == "no-source"
  freeAudioBuffer(buf)
echo "4. WAV source: paced by the clock, silent past its end; wav-format, wav-truncated, no-source OK"

# 5. The PCM sink writes exactly the PCM played: two bytes a sample, little-endian, nothing
#    before or after, whatever the file held. Without a sink path, or with one that cannot be
#    opened, playback is refused as `no-sink`.
block:
  var pcm = ramp(7_000)
  pcm.add [low(int16), high(int16), -1'i16, 0'i16, 1'i16]
  let sink = dir / "sink.pcm"
  writeFile(sink, "stale bytes from an earlier playback")
  let vc = VirtualClock()
  let io = newFileAudioIo("", sink, vc.clock)
  let buf = newAudioBuffer(pcm.len)
  doAssert buf.loadPlayback(pcm) == pcm.len
  doAssert io.startPlayback(buf) == ""
  var guard = 0
  while not buf.done:
    vc.advance(7)
    doAssert io.pump() == ""
    inc guard
    doAssert guard < 1_000, "playback never finished"
  vc.advance(100)
  doAssert io.pump() == ""
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert readFile(sink) == pcmBytes(pcm)
  doAssert newFileAudioIo("", "", vc.clock).startPlayback(buf) == "no-sink"
  doAssert newFileAudioIo("", dir / "no" / "such" / "dir.pcm", vc.clock).startPlayback(buf) == "no-sink"
  freeAudioBuffer(buf)
echo "5. PCM sink: exactly the samples played, little-endian; no-sink OK"

removeDir(dir)
