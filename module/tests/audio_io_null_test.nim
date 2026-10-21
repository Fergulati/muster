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

const Clip: StreamFormat = (rate: ClipRate, channels: ClipChannels, s16: true)

# 1. Capture starts a device thread: within 1 s frames arrive, and every one is zero (the
#    null backend hears nothing). The device miniaudio initialised is read back: the callback
#    is handed 48 kHz mono s16, the clip's own format, whatever the hardware runs (S1's
#    read-back rule; a start whose device reads back otherwise is refused, `device-format`).
#    Stop ends the thread's writes; stop and close are idempotent.
block:
  let io = newMiniaudioIo(abNull)
  let buf = newAudioBuffer(ClipRate)                     # 1 s
  doAssert io.streamFormat == (rate: 0, channels: 0, s16: false), "idle: no device to read"
  doAssert io.startCapture(buf) == ""
  doAssert io.backendName == "Null", io.backendName
  doAssert io.stream == asCapture
  doAssert io.streamFormat == Clip, $io.streamFormat
  let ms = waitUntil(proc (): bool = buf.written > 0, 1_000)
  doAssert buf.written > 0, "no frames within " & $ms & " ms"
  let got = buf.takeCaptured()
  doAssert got.len > 0
  for s in got: doAssert s == 0, "the null backend delivered a non-zero sample"
  doAssert buf.takePeak() == 0
  doAssert io.stopCapture() == ""
  doAssert io.stream == asIdle
  doAssert io.streamFormat == (rate: 0, channels: 0, s16: false)
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

# 3. Playback reads back as 48 kHz mono s16 and consumes 48,000 frames a second, give or take
#    5%: the rate is measured between two reads 600 ms apart, so the period the null device
#    takes ahead at its start is not counted, and 44.1 kHz (−8%) is outside it. Then, on a
#    short buffer, it reaches its end and sets `done` only after writing the buffer's tail of
#    silence: miniaudio's one-period intermediary buffer and the device's three 10 ms periods,
#    1,920 frames, the device's own numbers read back. ma_device_uninit drops what those hold,
#    so a stop on `done` drops only silence.
block:
  let io = newMiniaudioIo(abNull)
  var pcm = newSeq[int16](2 * ClipRate)
  for i in 0 ..< pcm.len: pcm[i] = int16((i mod 96) * 100 - 4_800)
  let buf = newAudioBuffer(pcm.len)
  doAssert buf.loadPlayback(pcm) == pcm.len
  doAssert io.startPlayback(buf) == ""
  doAssert io.stream == asPlayback
  doAssert io.streamFormat == Clip, $io.streamFormat
  sleep(100)
  let r1 = buf.readIndex
  let t1 = getMonoTime()
  sleep(600)
  let r2 = buf.readIndex
  let us = int((getMonoTime() - t1).inMicroseconds)
  let rate = (r2 - r1) * 1_000_000 div us
  doAssert not buf.done
  doAssert rate in 45_600 .. 50_400, $(r2 - r1) & " frames in " & $(us div 1_000) & " ms: " & $rate & "/s"
  doAssert io.stopPlayback() == ""
  let short = newAudioBuffer(ClipRate div 10)            # 100 ms
  doAssert short.loadPlayback(pcm) == 4_800
  doAssert io.startPlayback(short) == ""
  doAssert short.tail == 1_920, $short.tail
  let doneMs = waitUntil(proc (): bool = short.done, 1_000)
  doAssert short.done, "not done within " & $doneMs & " ms"
  doAssert short.readIndex == 4_800
  doAssert short.silenceAfter >= short.tail, $short.silenceAfter & " frames of silence"
  doAssert io.stopPlayback() == "" and io.stopPlayback() == ""
  doAssert io.close() == ""
  freeAudioBuffer(buf)
  freeAudioBuffer(short)
  echo "   ", r2 - r1, " frames in ", us div 1_000, " ms (", rate, "/s); 100 ms done after ",
    doneMs, " ms, ", short.silenceAfter, " frames of silence after it"
echo "3. null playback: 48 kHz mono s16 read back, 48k frames/s ±5%; done after the tail OK"

# 4. One stream at a time: a second start while one runs is `busy`, capture or playback, and
#    stopping the other kind leaves the running one alone. Once stopped, the same context
#    opens the other kind. A nil buffer is refused as `no-buffer` on the module thread, before
#    a context or a device is made: miniaudio's thread would dereference it with checks off.
block:
  let io = newMiniaudioIo(abNull)
  let a = newAudioBuffer(ClipRate)
  let b = newAudioBuffer(ClipRate)
  doAssert b.loadPlayback(newSeq[int16](ClipRate)) == ClipRate
  doAssert io.startCapture(nil) == "no-buffer"
  doAssert io.startPlayback(nil) == "no-buffer"
  doAssert io.stream == asIdle and io.backendName == "", "a refused start made a context"
  doAssert io.startCapture(a) == ""
  doAssert io.startPlayback(nil) == "no-buffer"
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
echo "4. null device: a second start while one runs is busy; a nil buffer is no-buffer OK"

# 5. The backend lists, read with no context and no device (nothing is opened, nothing
#    prompts): abNull lists Null alone; abSystem lists the platform's own backends, in order,
#    and never Null, and is never empty on macOS or Linux. miniaudio reads an empty list as
#    its default order, which ends in Null, so with no backend a start must say no-device,
#    never record zeros (voice-notes.md §9). A MiniaudioIo opens nothing until a start.
block:
  doAssert backendNames(abNull) == @["Null"], $backendNames(abNull)
  let sys = backendNames(abSystem)
  when defined(macosx): doAssert sys == @["Core Audio"], $sys
  elif defined(linux): doAssert sys == @["PulseAudio", "ALSA"], $sys
  when defined(macosx) or defined(linux): doAssert sys.len > 0
  doAssert "Null" notin sys, $sys
  let io = newMiniaudioIo()
  doAssert io.backendName == "" and io.stream == asIdle
  doAssert io.close() == ""
  echo "   abSystem lists ", sys
echo "5. backend lists: abNull is Null alone; abSystem never Null, never empty OK"
