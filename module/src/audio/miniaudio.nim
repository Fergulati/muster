## miniaudio 0.11.23 (github.com/mackron/miniaudio, Unlicense OR MIT-0) behind the AudioIo seam
## (docs/design/voice-notes.md §9): MiniaudioIo, a real device thread on the platform's own
## backends (abSystem) or on miniaudio's null backend (abNull). The null device runs the same
## thread, paced in real time, with no microphone, no speaker and no OS permission prompt.
##
## No C is tracked (scripts/check-no-cpp.py:35-45). miniaudio is a codegen.nim.packages pin in
## metadata.json, so its source sits on a --path: the builder's fetchFromGitHub, or
## tools/nim-closure.sh's checkout for run-suite.sh. `maDir` finds miniaudio.h there at
## compile time, and {.compile.} builds miniaudio.c into the staticlib. The -D flags go in a
## GLOBAL passC, not localPassC: the enabled backends change struct layouts, so miniaudio.c and
## every C file that includes miniaudio.h must see the same ones (localPassC failed in the
## prototype), and Nim, not this module, decides which files those are. A generic instance
## over a header type is emitted where Nim puts it: a `seq[ma_backend]` once put its hooks,
## and an #include of miniaudio.h, into system's C. So every header-typed binding stays in
## this module, the backend list is a fixed array (no hooks), and MiniaudioIo's fields are
## plain pointers; with those, only this module's C includes the header (checked in the
## nimcache of audio_io_null_test and of an --app:staticlib build).
##
## Backends: only CoreAudio, PulseAudio (which PipeWire answers through pipewire-pulse), ALSA
## and Null are compiled in. abSystem lists CoreAudio on macOS, PulseAudio then ALSA on Linux,
## and never Null, so a machine with none of them says "no-device" rather than record zeros
## (§9, §12; `backendNames`, audio_io_null_test §5). miniaudio's runtime linking is kept: it
## dlopens those libraries itself, so nothing joins codegen.nim.link, a flat list that would
## carry macOS frameworks onto the Linux link line. The module is built --app:staticlib, so
## nim links nothing: the archive leaves dlopen, dlsym and dlclose undefined, for the plugin's
## own link to resolve (S3), from libSystem on macOS and, on Linux, from libc itself (glibc
## 2.34 and later; earlier ones need -ldl). The darwin-arm64 plugin has been linked (S3): it
## defines ma_context_init and every other ma_ symbol, binds dlopen, dlsym and dlclose to
## libSystem, and links no audio framework. The Linux plugin links have not been run.
##
## Every stream is read back after ma_device_init (S1's read-back rule): the callback must be
## handed 48 kHz mono s16, the clip's own format, or the start is refused, "device-format".
## The device converts to whatever the hardware runs; what it holds after the callback (the
## one-period intermediary buffer and the device's own periods) is a playback's `tail`, so
## `done` is set only once that much silence has followed the last sample (audio_io.nim).
##
## The data callbacks run on miniaudio's thread, which Nim does not own. They are cdecl, gcsafe
## and raises: [], compiled with checks and stack traces off, and only hand the device's
## buffer to audio_io's captureInto / playFrom. A device is initialised, started and
## uninitialised on the module thread only, never from a callback; ma_device_uninit stops it
## and waits for its thread, so the buffer can be freed once a stop returns. The context is
## made on the first start and kept until `close`, which uninitialises it; a later start makes
## a new one. The voice recorder (coordination/voice_live.nim, S7) closes its AudioIo whenever
## a stream ends, so between streams no context is open, and since muster_module has no
## unload hook (the generated surface exports none) it registers an exit proc that closes
## whatever still runs: a context, and its backend's threads, left alive when the host unloads
## the plugin is a crash risk.

import std/[compilesettings, os]
import ./audio_io
import ./voice_clip

const maDir = block:
  var d = ""
  for p in querySettingSeq(searchPaths):
    if d.len == 0 and fileExists(p / "miniaudio.h"): d = p
  doAssert d.len > 0, "miniaudio.h is on no --path: the metadata.json miniaudio pin " &
    "(run-suite.sh passes --path:$P/miniaudio, the builder its fetch)"
  d

{.passC: "-I" & quoteShell(maDir) &
  " -DMA_ENABLE_ONLY_SPECIFIC_BACKENDS -DMA_ENABLE_COREAUDIO -DMA_ENABLE_PULSEAUDIO" &
  " -DMA_ENABLE_ALSA -DMA_ENABLE_NULL -DMA_NO_DECODING -DMA_NO_ENCODING -DMA_NO_GENERATION" &
  " -DMA_NO_RESOURCE_MANAGER -DMA_NO_NODE_GRAPH -DMA_NO_ENGINE".}
{.compile: maDir / "miniaudio.c".}

const H = "miniaudio.h"

type
  MaResult {.importc: "ma_result", header: H.} = cint
  MaBackend {.importc: "ma_backend", header: H.} = cint
  MaDeviceType {.importc: "ma_device_type", header: H.} = cint
  MaFormat {.importc: "ma_format", header: H.} = cint
  MaDataProc {.importc: "ma_device_data_proc", header: H.} = pointer
    ## void (*)(ma_device*, void*, const void*, ma_uint32): its own type, with each Nim
    ## callback cast to it, since clang 19 rejects assigning a proc whose input is not const.
  MaContext {.importc: "ma_context", header: H.} = object
    backend: MaBackend
  MaDeviceStream {.importc: "struct ma_device_stream_unnamed", header: H.} = object
    ## ma_device's anonymous `playback` and `capture` structs (miniaudio.h:7814-7861), reached
    ## only as dev.playback.* / dev.capture.*, so this name never reaches C. `format` and
    ## `channels` are the client side, what the callback is handed; the internal fields are
    ## the device's own; intermediaryBufferCap is at the client rate.
    format: MaFormat
    channels: uint32
    internalSampleRate, internalPeriodSizeInFrames, internalPeriods: uint32
    intermediaryBufferCap: uint32
  MaDevice {.importc: "ma_device", header: H.} = object
    sampleRate: uint32                  ## the client side's, for both directions
    pUserData: pointer
    playback, capture: MaDeviceStream
  MaStreamConfig {.importc: "struct ma_device_config_stream_unnamed", header: H.} = object
    ## ma_device_config's anonymous `playback` and `capture` structs. They are reached only as
    ## cfg.playback.* / cfg.capture.*, so this name never reaches C.
    format: MaFormat
    channels: uint32
  MaDeviceConfig {.importc: "ma_device_config", header: H.} = object
    sampleRate: uint32
    dataCallback: MaDataProc
    pUserData: pointer
    playback, capture: MaStreamConfig

let
  MA_SUCCESS {.importc, header: H, nodecl.}: MaResult
  ma_backend_coreaudio {.importc, header: H, nodecl.}: MaBackend
  ma_backend_pulseaudio {.importc, header: H, nodecl.}: MaBackend
  ma_backend_alsa {.importc, header: H, nodecl.}: MaBackend
  ma_backend_null {.importc, header: H, nodecl.}: MaBackend
  ma_device_type_playback {.importc, header: H, nodecl.}: MaDeviceType
  ma_device_type_capture {.importc, header: H, nodecl.}: MaDeviceType
  ma_format_s16 {.importc, header: H, nodecl.}: MaFormat

{.push importc, cdecl, header: H.}
proc ma_context_init(backends: ptr MaBackend, backendCount: uint32, config: pointer,
                     ctx: ptr MaContext): MaResult
proc ma_context_uninit(ctx: ptr MaContext): MaResult
proc ma_device_config_init(deviceType: MaDeviceType): MaDeviceConfig
proc ma_device_init(ctx: ptr MaContext, config: ptr MaDeviceConfig, dev: ptr MaDevice): MaResult
proc ma_device_uninit(dev: ptr MaDevice)
proc ma_device_start(dev: ptr MaDevice): MaResult
proc ma_get_backend_name(backend: MaBackend): cstring
proc ma_version_string(): cstring
{.pop.}

# ── The device thread's callbacks ───────────────────────────────────────────────────────────
{.push stackTrace: off, checks: off.}

proc onCapture(dev: ptr MaDevice, output, input: pointer, frameCount: uint32) {.cdecl, gcsafe, raises: [].} =
  captureInto(cast[AudioBuffer](dev.pUserData), cast[ptr UncheckedArray[int16]](input),
              int(frameCount))

proc onPlayback(dev: ptr MaDevice, output, input: pointer, frameCount: uint32) {.cdecl, gcsafe, raises: [].} =
  discard playFrom(cast[AudioBuffer](dev.pUserData), cast[ptr UncheckedArray[int16]](output),
                   int(frameCount))

{.pop.}

# ── MiniaudioIo ────────────────────────────────────────────────────────────────────────────

type
  AudioBackend* = enum
    abSystem = "system"         ## CoreAudio (macOS); PulseAudio, then ALSA (Linux); never Null
    abNull = "null"             ## miniaudio's null device: a real thread, no device, no prompt

  MiniaudioIo* = ref object of AudioIo
    backend: AudioBackend
    ctx: pointer                ## an ma_context, made on the first start, kept until close
    dev: pointer                ## the open stream's ma_device; nil when idle

  StreamFormat* = tuple[rate, channels: int, s16: bool]
    ## A stream's client-side settings: what the callback is handed.

const ClipFormat: StreamFormat = (rate: ClipRate, channels: ClipChannels, s16: true)

proc newMiniaudioIo*(backend = abSystem): MiniaudioIo =
  ## Opens nothing: the context is made by the first start, which only voice_record_start or
  ## voice_play makes (with the access policy off, any caller's, §13).
  MiniaudioIo(backend: backend)

proc miniaudioVersion*(): string = $ma_version_string()

proc backendName*(io: MiniaudioIo): string =
  ## The backend the context runs on, as miniaudio names it ("Null", "Core Audio", …); "" until
  ## a start made the context.
  if io.ctx == nil: "" else: $ma_get_backend_name(cast[ptr MaContext](io.ctx).backend)

proc backendsOf(b: AudioBackend): tuple[at: array[2, MaBackend], n: int] =
  ## The context's backend list, in order: the first `n` of `at`. A fixed array, not a seq,
  ## so no generic hook over ma_backend leaves this module (the header note). `n` is 0 only
  ## off macOS and Linux, where no backend is compiled in for abSystem.
  case b
  of abNull:
    result.at[0] = ma_backend_null
    result.n = 1
  of abSystem:
    when defined(macosx):
      result.at[0] = ma_backend_coreaudio
      result.n = 1
    elif defined(linux):
      result.at[0] = ma_backend_pulseaudio
      result.at[1] = ma_backend_alsa
      result.n = 2

proc backendNames*(b: AudioBackend): seq[string] =
  ## The backends a context for `b` lists, in order, as miniaudio names them. Pure: it makes
  ## no context and opens no device, so it prompts nothing. abSystem never lists Null and, on
  ## macOS and Linux, is never empty (audio_io_null_test §5).
  let list = backendsOf(b)
  for i in 0 ..< list.n: result.add $ma_get_backend_name(list.at[i])

proc context(io: MiniaudioIo): ptr MaContext =
  ## The context, made once; nil when no listed backend initialises, and the next start tries
  ## again. The list is never empty: miniaudio reads an empty one as its default order, which
  ## ends in Null.
  if io.ctx == nil:
    var list = backendsOf(io.backend)
    if list.n == 0: return nil
    let c = cast[ptr MaContext](allocShared0(sizeof(MaContext)))
    if ma_context_init(addr list.at[0], uint32(list.n), nil, c) != MA_SUCCESS:
      deallocShared(c)
      return nil
    io.ctx = c
  cast[ptr MaContext](io.ctx)

proc formatOf(dev: ptr MaDevice, s: AudioStream): StreamFormat =
  ## Read back from an initialised device: the client side of stream `s`.
  case s
  of asCapture:
    (rate: int(dev.sampleRate), channels: int(dev.capture.channels),
     s16: dev.capture.format == ma_format_s16)
  of asPlayback:
    (rate: int(dev.sampleRate), channels: int(dev.playback.channels),
     s16: dev.playback.format == ma_format_s16)
  of asIdle: (rate: 0, channels: 0, s16: false)

proc playbackTail(dev: ptr MaDevice): int =
  ## The frames a playback device still holds once the callback has handed a frame over, at
  ## the client rate: miniaudio's intermediary buffer, then the device's own periods at its
  ## rate, rounded up. ma_device_uninit drops them, so `done` waits for this much silence.
  ## The resampler's few frames, when the rates differ, are not counted.
  let rate = (if dev.playback.internalSampleRate > 0: int(dev.playback.internalSampleRate)
              else: ClipRate)
  let held = int(dev.playback.internalPeriods) * int(dev.playback.internalPeriodSizeInFrames)
  int(dev.playback.intermediaryBufferCap) + (held * ClipRate + rate - 1) div rate

proc streamFormat*(io: MiniaudioIo): StreamFormat =
  ## The open stream's client-side settings, read back from the device miniaudio initialised;
  ## (0, 0, false) when idle. A start refuses any but 48 kHz mono s16 ("device-format").
  if io.dev == nil: (rate: 0, channels: 0, s16: false)
  else: formatOf(cast[ptr MaDevice](io.dev), io.stream)

proc closeStream(io: MiniaudioIo) =
  ## Uninitialise the open device: miniaudio stops it and waits for its thread. Module thread.
  if io.dev != nil:
    ma_device_uninit(cast[ptr MaDevice](io.dev))
    deallocShared(io.dev)
    io.dev = nil
  io.stream = asIdle
  io.buffer = nil

proc openStream(io: MiniaudioIo, s: AudioStream, buf: AudioBuffer): string =
  # A nil reaching pUserData is dereferenced on miniaudio's thread with checks off: a SIGSEGV
  # in logos_host. Refused here, on the module thread, before a context or device is made.
  if buf == nil: return "no-buffer"
  if io.stream != asIdle: return "busy"
  let ctx = io.context()
  if ctx == nil: return "no-device"
  var cfg: MaDeviceConfig
  if s == asCapture:
    cfg = ma_device_config_init(ma_device_type_capture)
    cfg.capture.format = ma_format_s16
    cfg.capture.channels = uint32(ClipChannels)
    cfg.dataCallback = cast[MaDataProc](onCapture)
  else:
    cfg = ma_device_config_init(ma_device_type_playback)
    cfg.playback.format = ma_format_s16
    cfg.playback.channels = uint32(ClipChannels)
    cfg.dataCallback = cast[MaDataProc](onPlayback)
  cfg.sampleRate = uint32(ClipRate)
  cfg.pUserData = buf
  let dev = cast[ptr MaDevice](allocShared0(sizeof(MaDevice)))
  if ma_device_init(ctx, addr cfg, dev) != MA_SUCCESS:
    deallocShared(dev)
    return "no-device"
  if formatOf(dev, s) != ClipFormat:    # read back before the stream starts
    ma_device_uninit(dev)
    deallocShared(dev)
    return "device-format"
  if s == asCapture: buf.beginCapture() else: buf.beginPlayback(playbackTail(dev))
  io.dev = dev
  io.stream = s
  io.buffer = buf
  if ma_device_start(dev) != MA_SUCCESS:
    io.closeStream()
    return "no-device"
  ""

method startCapture*(io: MiniaudioIo, buf: AudioBuffer): string =
  ## "", "no-buffer", "busy", "no-device" (no backend listed for this platform initialised, or
  ## it has no capture device), or "device-format" (the device read back as other than 48 kHz
  ## mono s16).
  io.openStream(asCapture, buf)
method stopCapture*(io: MiniaudioIo): string =
  if io.stream == asCapture: io.closeStream()
  ""
method startPlayback*(io: MiniaudioIo, buf: AudioBuffer): string =
  io.openStream(asPlayback, buf)
method stopPlayback*(io: MiniaudioIo): string =
  if io.stream == asPlayback: io.closeStream()
  ""
method pump*(io: MiniaudioIo): string =
  ## Nothing to move: the device thread does it. The voice pump reads the buffer.
  ""
method close*(io: MiniaudioIo): string =
  io.closeStream()
  if io.ctx != nil:
    discard ma_context_uninit(cast[ptr MaContext](io.ctx))
    deallocShared(io.ctx)
    io.ctx = nil
  ""
