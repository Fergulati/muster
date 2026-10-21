## Voice notes' hosted half (docs/design/voice-notes.md §8, §9): what muster_module's voice
## methods run over, one per module instance. Audio and Opus live in the module only, and no
## method returns audio.
##
## So far (S3) it answers `voice_status` and nothing else. Its two native libraries are
## touched lazily, and neither opens anything:
##   * libopus (through voice_codec), read only for its version: `ready.codec`;
##   * the device seam (AudioIo), handed in by the module, which picks the implementation
##     (MiniaudioIo on the platform's own backends). MiniaudioIo makes miniaudio's context
##     on its first start, and only voice_record_start or voice_play starts one (S7). Any
##     caller can make those calls while the access policy is off (§13). Until a device has
##     been opened, `ready.capture` and `ready.playback` say "unknown". Reading the status
##     opens no device and prompts for nothing.
##
## Planned for S7: recording, the draft, sending it and playing (§8's six other methods), the
## voice pump that voice_status drives, and the thread rows. This module codes against
## AudioIo, never against miniaudio, so voice_live_test can run it on SyntheticAudioIo.

import std/json
import ../audio/[audio_io, voice_clip, voice_codec]

const DeviceUnknown* = "unknown"
  ## A device's readiness before anything opened one. S7 adds what an open says.

type
  VoiceLive* = ref object
    io: AudioIo                 ## the device seam; nothing is opened until the person acts
    capture, playback: string   ## each device's readiness: DeviceUnknown until one opens

proc newVoiceLive*(io: AudioIo): VoiceLive =
  ## Opens nothing.
  VoiceLive(io: io, capture: DeviceUnknown, playback: DeviceUnknown)

proc voiceStatus*(v: VoiceLive): JsonNode =
  ## §8's voice_status: integers, strings, booleans and null, never a float, never audio.
  ## With no recording or playback built yet, it is always idle.
  %*{"ready": {"capture": v.capture, "playback": v.playback, "codec": opusVersion(),
               "note": ""},
     "recording": {"state": "idle", "elapsedMs": 0, "capMs": VoiceMaxMs, "peak": 0,
                   "capped": false, "silent": false, "error": ""},
     "playing": newJNull()}
