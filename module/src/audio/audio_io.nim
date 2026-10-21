## The audio device seam of voice notes (docs/design/voice-notes.md §9), in the shape of
## Transport and BlobStore: the voice surface (S7) codes against AudioIo, never against
## miniaudio, and no test mocks it (CLAUDE.md working agreements). Implementations:
##   * SyntheticAudioIo (here): deterministic PCM on a virtual clock and a collecting sink, the
##     in-process stand-in, as LocalBlobStore is;
##   * FileAudioIo (here): a 48 kHz mono s16 WAV source and a raw PCM sink, for the offscreen
##     self-test (MUSTER_VOICE_SOURCE / MUSTER_VOICE_SINK, S9), on the monotonic clock;
##   * MiniaudioIo (miniaudio.nim): a real device thread, on the platform's backends or null.
##
## Samples cross threads only through an AudioBuffer: allocShared0'd once and sized to its cap
## (a 60 s recording is 2,880,000 samples, 5,760,000 B), linear, never wrapping. One side
## writes at the write index, the other reads at the read index, both Atomic. The device side,
## `captureInto` and `playFrom`, runs on a thread Nim does not own, so it keeps
## transport/inbound_queue.nim's rule (:1-11): no GC allocation, no raise, no Defect (checks
## are off there, since a Defect on that thread takes down logos_host), an explicit min() on
## every index, atomics only. SyntheticAudioIo and FileAudioIo call the same two procs from
## `pump`, 10 ms at a time as miniaudio's default period does, so the tests hold the cap,
## `capped`, the peak and `done` on the code the device thread runs.
##
## Capture: the device side copies frames in at the write index until the buffer is full,
## then drops them and sets `capped`. Only that side can hold the 60 s cap: the module has no
## clock (side-modules.md:66), and a Stop can queue behind a 20 s sync call. The module thread
## drains with `takeCaptured`. Playback: the module thread loads the whole decoded clip with
## `loadPlayback`, then starts; the device side copies out at the read index, writes zeros
## past the end and sets `done`, and the module thread then stops the stream.
##
## Streams open and close on the module thread only, one at a time per AudioIo (§8 never
## records and plays at once), so a second start is "busy". A buffer is freed only after the
## stream using it stopped. Every method returns "" or a word naming the refusal.

import std/[atomics, monotimes]
import ./voice_clip

const
  FramesPerMs = ClipRate div 1000       ## 48: mono, so a frame is one sample
  Period = 10 * FramesPerMs             ## 480: miniaudio's default 10 ms period

type
  AudioBufferObj = object
    samples: ptr UncheckedArray[int16]  ## allocShared0, `cap` long; nil when cap is 0
    cap: int
    writeAt, readAt: Atomic[int]        ## capture: device writes, module reads; playback: the reverse
    peakAbs: Atomic[int]                ## the largest |sample| captured since `takePeak`
    cappedFlag, doneFlag: Atomic[bool]
  AudioBuffer* = ptr AudioBufferObj
    ## Shared with a device thread: plain memory and atomics, never GC-traced.

proc newAudioBuffer*(cap: int): AudioBuffer =
  ## A zeroed buffer of `cap` samples. Module thread. Free it with freeAudioBuffer once no
  ## stream uses it.
  let cap = max(cap, 0)
  result = cast[AudioBuffer](allocShared0(sizeof(AudioBufferObj)))
  result.cap = cap
  if cap > 0:
    result.samples = cast[ptr UncheckedArray[int16]](allocShared0(cap * sizeof(int16)))

proc freeAudioBuffer*(b: AudioBuffer) =
  if b == nil: return
  if b.samples != nil: deallocShared(b.samples)
  deallocShared(b)

proc cap*(b: AudioBuffer): int = b.cap
proc written*(b: AudioBuffer): int = b.writeAt.load(moAcquire)
  ## Samples in the buffer: captured so far, or loaded to play.
proc readIndex*(b: AudioBuffer): int = b.readAt.load(moAcquire)
  ## Samples taken out: drained by the module thread (capture), or played (playback).
proc capped*(b: AudioBuffer): bool = b.cappedFlag.load(moAcquire)
  ## The capture filled the buffer; frames since were dropped.
proc done*(b: AudioBuffer): bool = b.doneFlag.load(moAcquire)
  ## The playback consumed everything loaded.
proc takePeak*(b: AudioBuffer): int = b.peakAbs.exchange(0, moAcquireRelease)
  ## The largest |sample| captured since the last call (0..32768), and reset it.

proc beginCapture*(b: AudioBuffer) =
  ## Empty `b` for a capture. Module thread, before the stream starts.
  b.writeAt.store(0, moRelaxed)
  b.readAt.store(0, moRelaxed)
  b.peakAbs.store(0, moRelaxed)
  b.cappedFlag.store(false, moRelaxed)
  b.doneFlag.store(false, moRelease)

proc beginPlayback*(b: AudioBuffer) =
  ## Rewind `b` to play what was loaded from its start. Module thread, before the stream starts.
  b.readAt.store(0, moRelaxed)
  b.peakAbs.store(0, moRelaxed)
  b.cappedFlag.store(false, moRelaxed)
  b.doneFlag.store(false, moRelease)

proc loadPlayback*(b: AudioBuffer, pcm: openArray[int16]): int =
  ## Put `pcm` in `b` to be played, up to its cap; the samples loaded. Module thread, with no
  ## stream on `b`.
  let n = min(pcm.len, b.cap)
  if n > 0: copyMem(addr b.samples[0], addr pcm[0], n * sizeof(int16))
  b.writeAt.store(n, moRelease)
  b.beginPlayback()
  n

proc takeCaptured*(b: AudioBuffer): seq[int16] =
  ## The samples captured since the last take, in order. Module thread.
  let w = b.writeAt.load(moAcquire)
  let r = b.readAt.load(moRelaxed)
  if w > r:
    result = newSeq[int16](w - r)
    copyMem(addr result[0], addr b.samples[r], (w - r) * sizeof(int16))
  b.readAt.store(max(w, r), moRelease)

# ── The device side: called on a thread Nim does not own ─────────────────────────────────
{.push stackTrace: off, checks: off.}

proc raisePeak(b: AudioBuffer, m: int) {.inline, gcsafe, raises: [].} =
  var cur = b.peakAbs.load(moRelaxed)
  while m > cur and not b.peakAbs.compareExchangeWeak(cur, m, moRelaxed, moRelaxed): discard

proc captureInto*(b: AudioBuffer, input: ptr UncheckedArray[int16], frames: int) {.gcsafe, raises: [].} =
  ## Copy `frames` captured samples in at the write index, up to the cap. Frames past it are
  ## dropped, and `capped` is set once the buffer is full. This side alone moves the write index.
  let w = b.writeAt.load(moRelaxed)
  let n = max(0, min(frames, b.cap - w))
  var m = 0
  for i in 0 ..< n:
    let v = int(input[i])
    b.samples[w + i] = input[i]
    m = max(m, (if v < 0: -v else: v))
  if n > 0:
    b.writeAt.store(w + n, moRelease)
    b.raisePeak(m)
  if w + n >= b.cap: b.cappedFlag.store(true, moRelease)

proc playFrom*(b: AudioBuffer, output: ptr UncheckedArray[int16], frames: int): int {.gcsafe, raises: [].} =
  ## Copy up to `frames` samples out from the read index, zeros past the end of what was
  ## loaded; set `done` once all of it is consumed. The samples copied. This side alone moves
  ## the read index.
  let w = b.writeAt.load(moAcquire)
  let r = b.readAt.load(moRelaxed)
  let n = max(0, min(frames, w - r))
  for i in 0 ..< n: output[i] = b.samples[r + i]
  for i in n ..< frames: output[i] = 0
  if n > 0: b.readAt.store(r + n, moRelease)
  if r + n >= w: b.doneFlag.store(true, moRelease)
  n

{.pop.}

# ── Clocks ─────────────────────────────────────────────────────────────────────────────────

type
  AudioClock* = proc (): int64 {.gcsafe, raises: [].}
    ## Milliseconds on a clock that never goes back.
  VirtualClock* = ref object
    ms*: int64                          ## now on this clock; `advance` moves it

proc advance*(c: VirtualClock, ms: int) = c.ms += int64(ms)
proc clock*(c: VirtualClock): AudioClock =
  ## The clock a test owns.
  result = proc (): int64 = c.ms
proc monotonicClock*(): AudioClock =
  ## The process's monotonic clock.
  result = proc (): int64 = getMonoTime().ticks div 1_000_000

# ── The seam ───────────────────────────────────────────────────────────────────────────────

type
  AudioStream* = enum
    asIdle = "idle", asCapture = "capture", asPlayback = "playback"

  AudioIo* = ref object of RootObj
    stream*: AudioStream                ## the stream open now; set by implementations only
    buffer*: AudioBuffer                ## the buffer it moves samples through; nil when idle

method startCapture*(io: AudioIo, buf: AudioBuffer): string {.base.} =
  ## Empty `buf` and fill it from the source, up to its cap. "" or a refusal: "busy" (a stream
  ## is open), "no-device", or the implementation's own word.
  raise newException(CatchableError, "AudioIo.startCapture is abstract")
method stopCapture*(io: AudioIo): string {.base.} =
  ## Stop the capture, if one is open: the buffer keeps what it holds. Always "".
  raise newException(CatchableError, "AudioIo.stopCapture is abstract")
method startPlayback*(io: AudioIo, buf: AudioBuffer): string {.base.} =
  ## Play what `buf` holds (loadPlayback), from its start. "" or a refusal, as startCapture.
  raise newException(CatchableError, "AudioIo.startPlayback is abstract")
method stopPlayback*(io: AudioIo): string {.base.} =
  ## Stop the playback, if one is open. Always "".
  raise newException(CatchableError, "AudioIo.stopPlayback is abstract")
method pump*(io: AudioIo): string {.base.} =
  ## Called from the module thread's voice pump: move what is due. "" or a refusal.
  ""
method close*(io: AudioIo): string {.base.} =
  ## Stop any stream and release the device, before the module unloads. Idempotent.
  ""

proc shut(io: AudioIo) =
  io.stream = asIdle
  io.buffer = nil

# ── A device thread run by the module thread's pump ─────────────────────────────────────

type
  PacedAudioIo = ref object of AudioIo
    ## `pump` moves the frames the clock says are due through captureInto / playFrom, a period
    ## at a time, as the device callback would have.
    clock: AudioClock
    source: seq[int16]                  ## what a capture hears from its start; silence after
    t0: int64                           ## the clock when the stream opened
    frames: int                         ## frames moved since

proc open(io: PacedAudioIo, s: AudioStream, buf: AudioBuffer) =
  io.stream = s
  io.buffer = buf
  io.t0 = io.clock()
  io.frames = 0

proc due(io: PacedAudioIo): int =
  max(0, int(io.clock() - io.t0) * FramesPerMs - io.frames)

proc pumpCapture(io: PacedAudioIo) =
  var period: array[Period, int16]
  var n = io.due
  while n > 0:
    if io.buffer.capped:                # the rest would be dropped: skip the copying
      io.frames += n
      break
    let k = min(n, Period)
    for i in 0 ..< k:
      let at = io.frames + i
      period[i] = (if at < io.source.len: io.source[at] else: 0'i16)
    captureInto(io.buffer, cast[ptr UncheckedArray[int16]](addr period[0]), k)
    io.frames += k
    n -= k

proc pumpPlayback(io: PacedAudioIo): seq[int16] =
  ## The samples played: what a speaker would have sounded, without the zeros after the end.
  var period: array[Period, int16]
  var n = io.due
  while n > 0:
    let k = min(n, Period)
    let got = playFrom(io.buffer, cast[ptr UncheckedArray[int16]](addr period[0]), k)
    result.add period.toOpenArray(0, got - 1)
    io.frames += k
    n -= k
    if io.buffer.done:
      io.frames += n
      break

# ── SyntheticAudioIo ───────────────────────────────────────────────────────────────────────

type
  SyntheticAudioIo* = ref object of PacedAudioIo
    sunk: seq[int16]                    ## the collecting sink: the last playback, exactly

proc newSyntheticAudioIo*(source: seq[int16], clock: AudioClock): SyntheticAudioIo =
  ## A capture hears `source` from its start, then silence; playback is collected. Both run
  ## on `clock`, 48 frames a millisecond.
  SyntheticAudioIo(source: source, clock: clock)

proc played*(io: SyntheticAudioIo): seq[int16] = io.sunk

method startCapture*(io: SyntheticAudioIo, buf: AudioBuffer): string =
  if io.stream != asIdle: return "busy"
  buf.beginCapture()
  io.open(asCapture, buf)
  ""
method stopCapture*(io: SyntheticAudioIo): string =
  if io.stream == asCapture: io.shut()
  ""
method startPlayback*(io: SyntheticAudioIo, buf: AudioBuffer): string =
  if io.stream != asIdle: return "busy"
  buf.beginPlayback()
  io.sunk.setLen(0)
  io.open(asPlayback, buf)
  ""
method stopPlayback*(io: SyntheticAudioIo): string =
  if io.stream == asPlayback: io.shut()
  ""
method pump*(io: SyntheticAudioIo): string =
  case io.stream
  of asCapture: io.pumpCapture()
  of asPlayback: io.sunk.add io.pumpPlayback()
  of asIdle: discard
  ""
method close*(io: SyntheticAudioIo): string =
  io.shut()
  ""

# ── FileAudioIo ────────────────────────────────────────────────────────────────────────────

proc u16At(s: string, i: int): int = int(uint8(s[i])) or (int(uint8(s[i + 1])) shl 8)
proc u32At(s: string, i: int): int = u16At(s, i) or (u16At(s, i + 2) shl 16)

proc parseWav*(bytes: string): tuple[ok: bool, pcm: seq[int16], why: string] =
  ## The samples of a RIFF/WAVE file of 48 kHz mono s16 PCM (format 1). Refusals:
  ## "wav-format" for any other kind of file, "wav-truncated" for one that ends before its
  ## "fmt " and "data" chunks do. Chunks between them (LIST, …) are skipped.
  if bytes.len < 12: return (false, @[], "wav-truncated")
  if bytes[0 ..< 4] != "RIFF" or bytes[8 ..< 12] != "WAVE": return (false, @[], "wav-format")
  var at = 12
  var fmtSeen = false
  while true:
    if at + 8 > bytes.len: return (false, @[], "wav-truncated")
    let id = bytes[at ..< at + 4]
    let size = u32At(bytes, at + 4)
    let body = at + 8
    if size > bytes.len - body: return (false, @[], "wav-truncated")
    if id == "fmt ":
      if size < 16 or u16At(bytes, body) != 1 or u16At(bytes, body + 2) != ClipChannels or
          u32At(bytes, body + 4) != ClipRate or u16At(bytes, body + 12) != 2 or
          u16At(bytes, body + 14) != 16:
        return (false, @[], "wav-format")
      fmtSeen = true
    elif id == "data":
      if not fmtSeen or size mod 2 != 0: return (false, @[], "wav-format")
      var pcm = newSeq[int16](size div 2)
      for i in 0 ..< pcm.len: pcm[i] = cast[int16](uint16(u16At(bytes, body + 2 * i)))
      return (true, pcm, "")
    at = body + size + (size and 1)     # chunks are word-aligned

proc pcmLe(pcm: openArray[int16]): string =
  result = newString(pcm.len * 2)
  for i, s in pcm:
    let u = cast[uint16](s)
    result[2 * i] = char(u and 0xFF)
    result[2 * i + 1] = char(u shr 8)

type
  FileAudioIo* = ref object of PacedAudioIo
    sourcePath, sinkPath: string
    sink: File
    sinkOpen: bool

proc newFileAudioIo*(source, sink: string, clock = monotonicClock()): FileAudioIo =
  ## A capture hears the WAV file at `source`, read again at each start, then silence;
  ## playback writes raw s16 little-endian PCM to `sink`, truncated at each start. The only
  ## AudioIo that writes a file, and only to the path it is given (MUSTER_VOICE_SINK).
  FileAudioIo(sourcePath: source, sinkPath: sink, clock: clock)

proc closeSink(io: FileAudioIo) =
  if io.sinkOpen:
    close(io.sink)
    io.sinkOpen = false

method startCapture*(io: FileAudioIo, buf: AudioBuffer): string =
  ## Also "no-source" (no path, or no file there), "wav-format", "wav-truncated".
  if io.stream != asIdle: return "busy"
  if io.sourcePath.len == 0: return "no-source"
  var bytes: string
  try: bytes = readFile(io.sourcePath)
  except IOError: return "no-source"
  let w = parseWav(bytes)
  if not w.ok: return w.why
  io.source = w.pcm
  buf.beginCapture()
  io.open(asCapture, buf)
  ""
method stopCapture*(io: FileAudioIo): string =
  if io.stream == asCapture: io.shut()
  ""
method startPlayback*(io: FileAudioIo, buf: AudioBuffer): string =
  ## Also "no-sink": no path, or one that cannot be opened for writing.
  if io.stream != asIdle: return "busy"
  if io.sinkPath.len == 0 or not open(io.sink, io.sinkPath, fmWrite): return "no-sink"
  io.sinkOpen = true
  buf.beginPlayback()
  io.open(asPlayback, buf)
  ""
method stopPlayback*(io: FileAudioIo): string =
  if io.stream == asPlayback:
    io.closeSink()
    io.shut()
  ""
method pump*(io: FileAudioIo): string =
  ## Also "sink-write", when the sink refuses a write.
  case io.stream
  of asCapture: io.pumpCapture()
  of asPlayback:
    let pcm = io.pumpPlayback()
    if pcm.len > 0:
      try: io.sink.write(pcmLe(pcm))
      except IOError: return "sink-write"
  of asIdle: discard
  ""
method close*(io: FileAudioIo): string =
  io.closeSink()
  io.shut()
  ""
