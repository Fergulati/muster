# module/src/audio/

Voice notes' audio (`docs/design/voice-notes.md`): a short clip recorded, encoded, decoded and
played inside `muster_module`. Audio plaintext never leaves the module: no method returns PCM
or a clip, and nothing here writes a file (§7, §9).

- `voice_clip.nim`: the clip record (§3.2), a CDE record of Opus packets built with
  `src/dcbor` (invariant 5), and its strict reader. Pure: it links no codec. The clip
  constants (48 kHz mono, 20 ms frames, 16 kbps, the 60 s cap) live here, and
  `maxClipBytes` is §5's size budget.
- `opus.nim`: the libopus binding, `importc` with no header (as `crypto/sodium.nim`), linked
  through `metadata.json` (`codegen.nim.link` "opus", `nix.packages.runtime` "libopus").
- `voice_codec.nim`: PCM to a clip record and back at one fixed set of settings (§3.1):
  an incremental encoder (`feed` / `finish` / `clip`) and `decodeClip`.

Rules:
- The ctl functions stay `{.varargs.}`, every SET value a `cint`, every GET argument a
  `ptr cint`. A fixed-arity binding passes garbage on Apple arm64 (§3.1); every setting is
  read back after it is set (`newClipEncoder`, `voice_codec_test` §1).
- libopus reads room-supplied bytes only after `voice_clip.decodeRecord` accepted the record
  and every packet is one 20 ms frame. A refusal is a value naming why, never a raise.
- The coordination layer (the room's fold, thread rows) imports `voice_clip` only, never
  `opus` or `voice_codec`: the fold must not link a codec (§6).
- A change to any clip constant or the record's fields strands notes already sent: it is a
  new `v`, never an edit (§3.4).
- Tests: `module/tests/voice_clip_test.nim` (pure), `module/tests/voice_codec_test.nim`
  (libopus; `run-suite.sh` links nixpkgs' libopus, `MUSTER_OPUS` picks another).
