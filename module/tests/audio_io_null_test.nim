## The audio seam on miniaudio's real device thread (docs/design/voice-notes.md §9), on the
## null backend: a device thread miniaudio starts and paces in real time, with no microphone,
## no speaker and no OS permission prompt (the context lists the null backend alone, so
## CoreAudio, PulseAudio and ALSA are never opened). The callback is the production one:
## `captureInto` / `playFrom` on a shared buffer, atomics only. Each block runs at most about
## 1 s of real time. Needs miniaudio on the --path (run-suite.sh: $P/miniaudio, the
## metadata.json pin).

import std/[monotimes, os, times]
import ../src/audio/[audio_io, miniaudio, voice_clip]

proc msSince(t: MonoTime): int = int((getMonoTime() - t).inMilliseconds)

proc waitUntil(cond: proc (): bool, limitMs: int): int =
  ## Poll every 5 ms until `cond` holds or `limitMs` passes; the ms it took.
  let t0 = getMonoTime()
  while not cond() and msSince(t0) < limitMs: sleep(5)
  msSince(t0)

# 1. Capture starts a device thread: within 1 s frames arrive, and every one is zero (the
#    null backend hears nothing). Stop ends the thread's writes; stop and close are idempotent.
block:
  let io = newMiniaudioIo(abNull)
  let buf = newAudioBuffer(ClipRate)                     # 1 s
  doAssert io.startCapture(buf) == ""
  doAssert io.backendName == "Null", io.backendName
  doAssert io.stream == asCapture
  let ms = waitUntil(proc (): bool = buf.written > 0, 1_000)
  doAssert buf.written > 0, "no frames within " & $ms & " ms"
  let got = buf.takeCaptured()
  doAssert got.len > 0
  for s in got: doAssert s == 0, "the null backend delivered a non-zero sample"
  doAssert buf.takePeak() == 0
  doAssert io.stopCapture() == ""
  doAssert io.stream == asIdle
  let w = buf.written
  sleep(50)
  doAssert buf.written == w, "frames written after stop: " & $w & " then " & $buf.written
  doAssert io.stopCapture() == "" and io.stopPlayback() == ""
  doAssert io.close() == "" and io.close() == ""
  freeAudioBuffer(buf)
  echo "   first frames after ", ms, " ms; ", w, " frames, all zero"
echo "1. null capture: frames within 1 s, all zero; stop and close idempotent OK"

# 2. A 0.2 s cap: the device thread stops writing at 9,600 frames and sets `capped`, and keeps
#    calling back without writing past it. It took real time to get there: the cap is held on
#    a running thread, not by a single call.
block:
  let io = newMiniaudioIo(abNull)
  let buf = newAudioBuffer(ClipRate div 5)               # 9,600 frames
  let t0 = getMonoTime()
  doAssert io.startCapture(buf) == ""
  let ms = waitUntil(proc (): bool = buf.capped, 1_000)
  doAssert buf.capped, "not capped within " & $ms & " ms (" & $buf.written & " frames)"
  doAssert buf.written == 9_600, $buf.written
  doAssert msSince(t0) >= 150, "9,600 frames in " & $msSince(t0) & " ms: not paced"
  sleep(100)
  doAssert buf.written == 9_600 and buf.capped
  doAssert io.stopCapture() == ""
  doAssert io.close() == ""
  freeAudioBuffer(buf)
  echo "   capped after ", ms, " ms"
echo "2. null capture: a 0.2 s cap stops at 9,600 frames, capped OK"

# 3. Playback consumes about 48,000 frames a second, then, on a short buffer, reaches its end
#    and sets `done` with every frame consumed.
block:
  let io = newMiniaudioIo(abNull)
  var pcm = newSeq[int16](2 * ClipRate)
  for i in 0 ..< pcm.len: pcm[i] = int16((i mod 96) * 100 - 4_800)
  let buf = newAudioBuffer(pcm.len)
  doAssert buf.loadPlayback(pcm) == pcm.len
  let t0 = getMonoTime()
  doAssert io.startPlayback(buf) == ""
  doAssert io.stream == asPlayback
  sleep(500)
  let played = buf.readIndex
  let ms = msSince(t0)
  let rate = played * 1_000 div ms
  doAssert not buf.done
  doAssert rate in 36_000 .. 60_000, $played & " frames in " & $ms & " ms"
  doAssert io.stopPlayback() == ""
  let short = newAudioBuffer(ClipRate div 10)            # 100 ms
  doAssert short.loadPlayback(pcm) == 4_800
  doAssert io.startPlayback(short) == ""
  let doneMs = waitUntil(proc (): bool = short.done, 1_000)
  doAssert short.done, "not done within " & $doneMs & " ms"
  doAssert short.readIndex == 4_800
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert io.close() == ""
  freeAudioBuffer(buf)
  freeAudioBuffer(short)
  echo "   ", played, " frames in ", ms, " ms (", rate, "/s); 100 ms done after ", doneMs, " ms"
echo "3. null playback: about 48k frames/s; a short buffer played to its end, done OK"

# 4. One stream at a time: a second start while one runs is `busy`, capture or playback, and
#    stopping the other kind leaves the running one alone. Once stopped, the same context
#    opens the other kind.
block:
  let io = newMiniaudioIo(abNull)
  let a = newAudioBuffer(ClipRate)
  let b = newAudioBuffer(ClipRate)
  doAssert b.loadPlayback(newSeq[int16](ClipRate)) == ClipRate
  doAssert io.startCapture(a) == ""
  doAssert io.startCapture(b) == "busy"
  doAssert io.startPlayback(b) == "busy"
  doAssert io.stopPlayback() == ""
  doAssert io.stream == asCapture
  doAssert waitUntil(proc (): bool = a.written > 0, 1_000) < 1_000
  doAssert io.stopCapture() == ""
  doAssert io.startPlayback(b) == ""
  doAssert io.startCapture(a) == "busy"
  doAssert io.startPlayback(a) == "busy"
  doAssert io.stopPlayback() == ""
  doAssert io.close() == ""
  freeAudioBuffer(a)
  freeAudioBuffer(b)
echo "4. null device: a second start while one runs is busy OK"
