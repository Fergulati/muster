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
## prototype). Even so, every header-typed binding stays in this module, and MiniaudioIo's
## fields are plain pointers, so no other module's C includes the header.
##
## Backends: only CoreAudio, PulseAudio (which PipeWire answers through pipewire-pulse), ALSA
## and Null are compiled in. abSystem lists CoreAudio on macOS, PulseAudio then ALSA on Linux,
## and never Null, so a machine with none of them says "no-device" rather than record zeros
## (§9, §12). miniaudio's runtime linking is kept: it dlopens those libraries itself, so
## nothing joins codegen.nim.link, a flat list that would carry macOS frameworks onto the
## Linux link line (on macOS the prototype's staticlib gained one undefined symbol, _dlopen;
## nim links -ldl on Linux by default).
##
## The data callbacks run on miniaudio's thread, which Nim does not own. They are cdecl, gcsafe
## and raises: [], compiled with checks and stack traces off, and only hand the device's
## buffer to audio_io's captureInto / playFrom. A device is initialised, started and
## uninitialised on the module thread only, never from a callback; ma_device_uninit stops it
## and waits for its thread, so the buffer can be freed once a stop returns. The context is
## made on the first start and kept until `close`, which the module calls before it unloads.

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
  MaDevice {.importc: "ma_device", header: H.} = object
    pUserData: pointer
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

proc newMiniaudioIo*(backend = abSystem): MiniaudioIo =
  ## Opens nothing: the context is made by the first start, on the person's own action (§9).
  MiniaudioIo(backend: backend)

proc miniaudioVersion*(): string = $ma_version_string()

proc backendName*(io: MiniaudioIo): string =
  ## The backend the context runs on, as miniaudio names it ("Null", "Core Audio", …); "" until
  ## a start made the context.
  if io.ctx == nil: "" else: $ma_get_backend_name(cast[ptr MaContext](io.ctx).backend)

proc backendsOf(b: AudioBackend): seq[MaBackend] =
  case b
  of abNull: @[ma_backend_null]
  of abSystem:
    when defined(macosx): @[ma_backend_coreaudio]
    elif defined(linux): @[ma_backend_pulseaudio, ma_backend_alsa]
    else: @[]

proc context(io: MiniaudioIo): ptr MaContext =
  ## The context, made once; nil when no listed backend initialises, and the next start tries
  ## again. The list is never empty: miniaudio reads an empty one as its default order, which
  ## ends in Null.
  if io.ctx == nil:
    var backends = backendsOf(io.backend)
    if backends.len == 0: return nil
    let c = cast[ptr MaContext](allocShared0(sizeof(MaContext)))
    if ma_context_init(addr backends[0], uint32(backends.len), nil, c) != MA_SUCCESS:
      deallocShared(c)
      return nil
    io.ctx = c
  cast[ptr MaContext](io.ctx)

proc closeStream(io: MiniaudioIo) =
  ## Uninitialise the open device: miniaudio stops it and waits for its thread. Module thread.
  if io.dev != nil:
    ma_device_uninit(cast[ptr MaDevice](io.dev))
    deallocShared(io.dev)
    io.dev = nil
  io.stream = asIdle
  io.buffer = nil

proc openStream(io: MiniaudioIo, s: AudioStream, buf: AudioBuffer): string =
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
  if s == asCapture: buf.beginCapture() else: buf.beginPlayback()
  io.dev = dev
  io.stream = s
  io.buffer = buf
  if ma_device_start(dev) != MA_SUCCESS:
    io.closeStream()
    return "no-device"
  ""

method startCapture*(io: MiniaudioIo, buf: AudioBuffer): string =
  ## "", "busy", or "no-device" (no backend listed for this platform initialised, or it has no
  ## capture device).
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
