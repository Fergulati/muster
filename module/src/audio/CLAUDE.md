# module/src/audio/

Voice notes' audio (`docs/design/voice-notes.md`): a short clip recorded, encoded, decoded and
played inside `muster_module`. Audio plaintext never leaves the module: no method returns PCM
or a clip, and nothing here writes a file except `FileAudioIo`'s sink, to the one path it is
given (`MUSTER_VOICE_SINK`, the offscreen self-test) (§7, §9).

- `voice_clip.nim`: the clip record (§3.2), a CDE record of Opus packets built with
  `src/dcbor` (invariant 5), and its strict reader. Pure: it links no codec. The clip
  constants (48 kHz mono, 20 ms frames, 16 kbps, the 60 s cap) live here, and
  `maxClipBytes` is §5's size budget.
- `opus.nim`: the libopus binding, `importc` with no header (as `crypto/sodium.nim`), linked
  through `metadata.json` (`codegen.nim.link` "opus", `nix.packages.runtime` "libopus").
- `voice_codec.nim`: PCM to a clip record and back at one fixed set of settings (§3.1):
  an incremental encoder (`feed` / `finish` / `clip`) and `decodeClip`.
- `audio_io.nim`: the device seam (§9), shaped like `Transport` and `BlobStore`. `AudioBuffer`
  is the only thing a device thread touches: `allocShared0`, sized to its cap, linear, two
  `Atomic` indices, `capped`, `done` and the peak. `captureInto` / `playFrom` are the device
  side. `AudioIo`'s methods (`startCapture`, `stopCapture`, `startPlayback`, `stopPlayback`,
  `pump`, `close`) return `""` or a refusal word. `SyntheticAudioIo` (a virtual clock, a
  collecting sink) and `FileAudioIo` (a 48 kHz mono s16 WAV source, a raw PCM sink) are the
  in-process stand-ins; their `pump` drives the same device side 10 ms at a time.
- `miniaudio.nim`: `MiniaudioIo`, miniaudio 0.11.23 behind the seam, on the platform's
  backends (`abSystem`: CoreAudio; PulseAudio, then ALSA) or the null device (`abNull`). The C
  comes from the `codegen.nim.packages` pin and is `{.compile.}`d from the `--path`, so no C is
  tracked (`scripts/check-no-cpp.py`).

Rules:
- The ctl functions stay `{.varargs.}`, every SET value a `cint`, every GET argument a
  `ptr cint`. A fixed-arity binding hands libopus whatever is on the stack on Apple arm64: in
  the prototype a silent 300000 bitrate (§3.1), in this build `OPUS_BAD_ARG`. Every setting is
  read back after it is set (`newClipEncoder`, `voice_codec_test` §1).
- libopus decodes room-supplied bytes only after `voice_clip.decodeRecord` accepted the
  record and every packet carries 20 ms of audio: 960 samples, as `opus_packet_get_nb_samples`
  reads them off the TOC byte (and a code-3 packet's frame count). That is a sample count, not
  one frame: several frames adding up to 20 ms pass. A refusal is a value naming why, never a
  raise.
- The room's fold and thread rows (`coordination/voice.nim`) import `voice_clip` only, never
  `opus` or `voice_codec`: the fold must not link a codec (§6). The hosted half,
  `coordination/voice_live.nim` (`VoiceRecorder`, the state machine of the seven voice
  methods, S7), is the one coordination file that links the codec: it imports `voice_codec`
  and the `AudioIo` seam. It drains the capture buffer into the incremental encoder on every
  pump, and closes the `AudioIo` whenever a stream ends, so between streams no device and no
  miniaudio context is open.
- A change to any clip constant or the record's fields strands notes already sent: it is a
  new `v`, never an edit (§3.4).
- **The device thread.** miniaudio calls back on a thread Nim does not own
  (`transport/inbound_queue.nim:1-11`'s rule): the callbacks and `captureInto` / `playFrom`
  stay `cdecl` / `gcsafe` / `raises: []` under `{.push stackTrace: off, checks: off.}`, with no
  GC allocation, no raise, an explicit `min()` on every index, and only the buffer's atomics
  shared. Only that side holds the 60 s cap: the module has no clock.
- Devices start and stop on the module thread only, never from a callback; one stream per
  `AudioIo` at a time (a second start is `busy`). Every start refuses a nil buffer
  (`no-buffer`) on the module thread, before anything opens. A buffer is freed only after the
  stream using it stopped (`ma_device_uninit` waits for the device thread). `close` runs before
  unload.
- `done` means heard, not handed over: `playFrom` sets it once the buffer's `tail` of silence
  has followed the last sample. The tail is what the implementation counts as still queued
  past the callback: 0 for the in-process sinks; for `MiniaudioIo`, the intermediary buffer
  plus the device's own periods, read back at start (1,920 frames on the null device). So the
  voice pump (S7), which has no clock, stops the stream as soon as it sees `done`.
- Every device stream is read back after `ma_device_init` (S1's rule): anything but 48 kHz mono
  s16 on the callback's side is refused, `device-format` (`streamFormat`, audio_io_null_test
  §1, §3).
- `abSystem` never lists Null, and never an empty list (miniaudio's default order ends in Null):
  no backend means `no-device`, never a recording of zeros. `backendNames` reads the lists
  with no context (audio_io_null_test §5).
- Nothing outside this directory imports `miniaudio` but the hosted module
  (`nim-lib/muster_module.nim`), which makes the one `AudioIo` on the first voice call, as
  `voice_live.voiceIoChoice` picks it: `FileAudioIo` when MUSTER_VOICE_SOURCE or
  MUSTER_VOICE_SINK is set, `MiniaudioIo(abNull)` for MUSTER_VOICE_BACKEND=null, else
  `MiniaudioIo(abSystem)`, and hands it to `voice_live`. That opens nothing: the context is
  made on the first start. It registers an exit proc that closes the recorder, since the
  generated surface has no unload hook. `voice_live` codes against `AudioIo` only. Every
  miniaudio header type stays in `miniaudio.nim`, never inside a generic (a `seq` of one put
  miniaudio.h into system's C: use a fixed array), and the `-D` backend flags stay one global
  `passC` (they change struct layouts).
- No test opens a real device: `abNull` only. A real-device test sits behind
  `MUSTER_VOICE_REAL`, in run-suite's E2E list (S11).
- Tests: `module/tests/voice_clip_test.nim` (pure), `module/tests/voice_codec_test.nim`
  (libopus; `run-suite.sh` links the builder pin's on macOS, the .lgx's 1.5.2, and nixpkgs'
  beside libsodium on Linux; `MUSTER_OPUS` picks another; §1 prints the version),
  `module/tests/audio_io_test.nim` (the seam with no device),
  `module/tests/audio_io_null_test.nim` (miniaudio's null device thread; `run-suite.sh` puts
  the pin's checkout on `--path`), and `module/tests/voice_live_test.nim` (the recorder over
  `SyntheticAudioIo`, `FileAudioIo` and the null device, two members over `LocalTransport`).
  `probes/probe_return_marshalling_host.nim` (exo-526) builds the whole module into a host,
  so it links libopus (`opusTokens`, `MUSTER_OPUS_LIB`) and compiles miniaudio from the
  closure's checkout; its `voice_status` call must name the libopus linked, with both
  devices still "unknown", and the six other voice methods, called with no room joined,
  must each reply exactly what that state gives, opening no device.
