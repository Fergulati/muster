# Voice notes' audio stack: libopus and miniaudio inside a Nim plugin (2026-10-21)

**Voice notes, slices S1 to S7 (`docs/design/voice-notes.md`). darwin-arm64 only, with nim
2.2.4 and clang 19.1.7 at the builder's nixpkgs `e9f00bd`. None of this has run on Linux.**

Cost: a throwaway prototype on an Apple M5, then one review per slice. Most of these traps
passed every test that existed when they went in. Each was found by a mutation or a
deliberate bad input, not by a failure.

The stack: libopus 1.5.2 bound by `importc` with no header (`module/src/audio/opus.nim`).
miniaudio 0.11.23 is compiled from source into the staticlib (`audio/miniaudio.nim`) behind
the `AudioIo` seam (`audio/audio_io.nim`). Room-supplied clips are checked before libopus
sees them (`audio/voice_clip.nim`). The rules this left are in `module/src/audio/CLAUDE.md`.

## 1. The libopus ctl functions are variadic, and only Apple arm64 shows it

**What happened.**
- In the prototype, `opus_encoder_ctl` was declared with a fixed arity. Every call returned
  `OPUS_OK` but set the wrong value: `SET_BITRATE(24000)` read back as 500, and 16000 and
  32000 both read back as 300000.
- In this build, the same mistake fails loudly instead: "opus ctl 4024: invalid argument",
  "opus ctl 4002: invalid argument" (`OPUS_BAD_ARG`). The outcome depends on what happens to
  be on the stack.

**Why.**
- Apple arm64 passes variadic arguments on the stack and fixed ones in registers. libopus's
  `va_arg` reads the stack.
- AAPCS64 Linux and SysV x86_64 pass both the same way, so the bug cannot show there.
- It matters because the frame size rests on it. A CBR packet's size follows from the
  bitrate, so a wrong bitrate would quietly break §4's fixed frame.

**The fix.**
- The ctl functions are `{.varargs.}`. Every SET value is a `cint`, never a 64-bit Nim `int`.
  Every GET argument is a `ptr cint`.
- `newClipEncoder` reads every setting back and raises `VoiceCodecError` on a mismatch
  ("opus ctl 4003 read back 300000, want 16000"), so no encoder exists to make clips of the
  wrong size.
- `voice_codec_test` §1 goes red under a fixed-arity mutant on this Mac. On Linux the same
  test cannot tell the two bindings apart.

**A Nim aside.** Two `importc` declarations of one C symbol with different signatures, in
one C translation unit, do not compile ("conflicting types"). So the S1 mutant called the
varargs symbol through a cast:
`cast[proc(st: ptr OpusEncoder, request, value: cint): cint {.cdecl.}](opus_encoder_ctl)`.

## 2. miniaudio's `-D` flags go in a global `passC`, and no generic may hold a header type

**What happened.**
- The prototype tried `{.localPassC.}` on the one module that `{.compile.}`s miniaudio.c.
  Every other Nim module whose C used a header-typed object also `#include`d miniaudio.h,
  and failed with "file not found".
- The backend defines (`MA_ENABLE_ONLY_SPECIFIC_BACKENDS`, `MA_ENABLE_COREAUDIO`, …) change
  struct layouts, so every C file that includes the header must see the same set.

**The fix.**
- One global `{.passC: "-I<dir> -D…".}`. `<dir>` comes from `querySettingSeq(searchPaths)`
  at compile time: the `--path` that holds the `codegen.nim.packages` checkout.
- Every header-typed binding stays in `miniaudio.nim`, and `MiniaudioIo`'s fields are plain
  pointers.

**The second half (the S2 review).** A generic instance over a header type is emitted
wherever Nim puts it.
- A `seq[ma_backend]` put its hooks, and an `#include` of miniaudio.h, into system's C. The
  pre-fix nimcache shows a `ma_backend data[]` seq struct and `NIM_ALIGNOF(ma_backend)`.
- The fix was a fixed array plus a count.
- The check: in a fresh nimcache of `audio_io_null_test`, and of an `--app:staticlib` build,
  only `miniaudio.nim.c` includes the header.

## 3. clang 19 refuses the data callback without a cast

`ma_device_data_proc` is `void (*)(ma_device*, void*, const void*, ma_uint32)`. Nim's proc
type has no `const` on the input, and clang 19 rejects assigning one to the other. (The
prototype's exact error text was not kept.)

**The fix.** Bind `ma_device_data_proc` as an `importc`'d type (`MaDataProc`), and cast each
Nim callback to it (`miniaudio.nim`).

## 4. Keep miniaudio's runtime linking

miniaudio `dlopen`s the platform's audio libraries itself:
- on macOS, CoreAudio, AudioToolbox or AudioUnit, and CoreFoundation (miniaudio.h:36536-36573);
- on Linux, `libpulse.so` / `libpulse.so.0` (:32511) and `libasound.so.2` (:29972).

**What `MA_NO_RUNTIME_LINKING` costs.**
- In the prototype the link failed with `_AudioComponentFindNext`, `_AudioObjectGetPropertyData`
  and others undefined. It succeeded once `-framework CoreFoundation -framework CoreAudio
  -framework AudioToolbox` was added (miniaudio.h:485-495).
- But `codegen.nim.link` is one flat list for every platform. The builder joins it into a
  single `LOGOS_MODULE_NIM_LINK_LIBS` (`lib/mkLogosModule.nix:541-542`), so a framework there
  would land on the Linux link line too.
- nixpkgs' own `miniaudio` is Linux-only and built with `MINIAUDIO_NO_RUNTIME_LINKING`. So
  muster takes the source as a `codegen.nim.packages` pin instead: `mackron/miniaudio` at
  `f40cf03`, with the hash nixpkgs uses for `miniaudio.src`.

**What runtime linking leaves.**
- The staticlib leaves `dlopen`, `dlsym` and `dlclose` undefined (`nm`), for the plugin's
  own link to resolve.
- On darwin that is libSystem. S3's plugin shows all three "(from libSystem)" (`nm -m`),
  with no audio framework linked (`otool -L`).
- On Linux it should be libc itself (glibc 2.34 and later; earlier ones need `-ldl`). That
  link has not been run.

**The trap inside it: macOS links a plugin with `-undefined dynamic_lookup`.** A missing
symbol shows up only when the plugin loads, never at link. So S3 made `voice_status` reach
both libraries and inspected the built plugin:
- `otool -L` lists `@loader_path/./libopus.0.dylib`, and no `/nix/store` load path;
- `nm` shows `T _ma_context_init`.

libopus is a plain, non-weak load. A Linux variant that does not bundle `libopus.so.0` would
fail all of `muster_module` to load, not only voice (§15).

**Notarization.** miniaudio.h:485-495 warns that runtime linking may fail Apple's
notarization. That applies to a notarized app. Muster's plugin is a separately installed
dylib, which `logos_host` loads with library validation disabled (inferred, not tested).

## 5. Read the device back after you open it

**What happened (the S2 review).**
- A wrong stream config passed every test: 44.1 kHz, f32, stereo.
- The null device only ever delivers zeros, so the all-zero capture check cannot tell one
  format from another.
- The test's "about 48k frames a second" band, 36,000..60,000, accepted 44,100. Under that
  mutant it measured 45,500/s; correct runs measured 49,980 to 50,376.
- On a real device that bug means notes at the wrong pitch, or garbage, with every
  automated test green until S11's opt-in device test.

**The fix.**
- `miniaudio.nim` binds `ma_device.sampleRate` and the client-side `format` and `channels` of
  its anonymous `playback` and `capture` structs (`struct ma_device_stream_unnamed`, a name
  that never reaches C).
- A start whose device reads back as anything but 48 kHz mono s16 is refused,
  `device-format`. `streamFormat(io)` exposes the read-back.
- The rate is now measured between two reads 600 ms apart, within ±5% (45,600..50,400).
- `audio_io_null_test` §1 and §3 hold it.

**Two neighbours from the same review.**
- **`done` meant handed over, not heard.** A stop on `done` dropped what miniaudio's
  intermediary buffer and the device's own periods still held: 1,920 frames, 40 ms, on the
  null device. So `done` is now set only once a `tail` of silence that long has followed the
  last sample. The tail is read back at start.
- **A nil buffer** would have been dereferenced on miniaudio's thread with checks off, a
  SIGSEGV in `logos_host`. Every start refuses it on the module thread, `no-buffer`.

## 6. std/base64's `decode` reads past the end of a string with whitespace in it

**What happened (the S5 review).** Any member could sign a voice part whose `part` crashed
the fold.
- Nim 2.2.4's `decode` (`lib/pure/base64.nim:252-262`) skips whitespace inside its
  4-character loop, then reads past the end of the string.
- The `IndexDefect` is a Defect, so `except CatchableError` never catches it. `reduceVoice`,
  `threadRows`, `threadLastTs` and `voiceRecordOf` all abort.
- Once `threadRows` serves `coordinate_messages`, one such part would take down the host on
  every poll, and again after every restart, because the raw log and the journal keep it.

**Reproduced again for this entry,** at the pinned nim:
- `decode("    AB")`: `IndexDefect: index 6 not in 0 .. 5`;
- `decode("AAAA     AAA")`: `IndexDefect: index 12 not in 0 .. 11`;
- `decode("  ABC")`: `IndexDefect: index 5 not in 0 .. 4`.

The second string is twelve characters, a multiple of 4. So a length check alone is not
enough.

**The fix.** `voice.nim`'s `isCanonicalBase64` runs before any decode:
- a length that is a multiple of 4;
- the standard alphabet only (a table);
- `=` only as final padding;
- zero spare bits.

A string that passes is the only spelling of its bytes, so the `encode(raw) == s` re-check
went. Held by `voice_test` §7 (the whitespace strings, URL-safe characters, spare bits,
padding inside, and 4,000 random strings) and by `probe_voice_author_stepper`'s ten malformed
cases.

**Not checked.** `transport/received.nim:50` and `bitcoin/psbt.nim:166` also hand strings to
`decode`. Whether their callers can pass a string with whitespace inside has not been looked
at; psbt strips only the ends.

## 7. The suite tested a libopus the module does not ship

**What happened (the S1 review).**
- `run-suite.sh` took libopus from the registry's nixpkgs, as it does libsodium. That is
  1.6.1. The `.lgx` ships the builder's 1.5.2 (`nix.packages.runtime` "libopus" at
  `e9f00bd`).
- `voice_codec_test` passed on both, so nothing failed. But the default run was not on the
  shipping codec.
- The macOS link warned: "dylib (/nix/store/n6gds98…-libopus-1.6.1/lib/libopus.dylib) was
  built for newer macOS version (14.0) than being linked (11.3)".

**The fix (`c2b2dc7`).**
- On macOS the suite builds `$NIXPKGS_PIN#libopus.out`. `builder_pin` reads the pin off
  `module/flake.lock`, or off the builder's own lock in a fresh clone, and never evaluates the
  flake.
- `voice_codec_test` §1 prints "libopus 1.5.2, preskip 312". `MUSTER_OPUS` picks another.
- The store paths on 2026-10-21: 1.5.2 at `/nix/store/f3kcnzp35b1wy1fg8cd4f2354xhww150-libopus-1.5.2`,
  1.6.1 at `/nix/store/n6gds98gifgs65vfr987j84jgh543rsa-libopus-1.6.1`.

**Still open.**
- On Linux the suite still links nixpkgs' current libopus, 1.6.1. It has to share nixpkgs
  gcc's glibc with libsodium.
- A run with `MUSTER_SODIUM` set and no `MUSTER_OPUS` stops, rather than link nixpkgs'
  libopus under the host compiler.
- The version is printed, not asserted: no test fails on the wrong one.
- The ctl request numbers are the same in 1.5.2 and 1.6.1 (checked against both `-dev`
  headers). Re-check them when the pin moves.

## 8. The frame's pad, and a NUL

Every `voice/` frame is the event's JSON followed by ASCII spaces, up to `VoiceFrameBytes`
(§4). An older client still reads it, because `decodeEvent` is `parseJson`, and at nim 2.2.4
`parseJson` accepts trailing whitespace.

It also treats a NUL as the end of its input, and accepts whatever follows one. Reproduced
again for this entry:
- `"{}     "`, `"{}\0\0"` and `"{}\0garbage"` are accepted;
- `"{} x"` and `"{}}"` are refused, `JsonParsingError`.

Nothing pads with NULs. `session_pad_test` finds the JSON's end by re-serializing what
`parseJson` read, so a NUL pad fails it (§1). It first got through, to §5, before that
change.

## Not found out yet

These are inferred, or wait on a host this was not built on. The design doc carries each one:
- **The microphone under Basecamp's hardened runtime** (§11). `logos_host` has no
  `com.apple.security.device.audio-input`, and `Info.plist` no `NSMicrophoneUsageDescription`.
  Either capture delivers zeros, which Send refuses as `silent`, or TCC terminates
  `logos_host`. S11 checks which, before anything relies on the refusal.
- **Linux** (§12, §15): miniaudio's `dlopen` of `libpulse` and `libasound` from a portable
  `.lgx`, the AppImage and a nix-built runner (whose loader reads no `/etc/ld.so.cache`); the
  Linux plugin links; `libopus.so.0` bundled and resolved by each variant's RUNPATH.
- **The exit proc at unload** (§9, §15): whether it runs when the host unloads the plugin
  with a device open.
