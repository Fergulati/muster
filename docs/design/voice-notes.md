# Voice notes: a short recorded clip in the room, sealed like text, one fixed size on the wire

Status: **proposed 2026-10-21 by an outside contributor; nothing below is built yet.** This
document is the first commit of a draft PR, so the maintainer can object to the wire format
(§3–§5) before any code depends on it. There is no exo id yet (§18): the slices are S0–S11
in the order of §17, and the commit scope is `voice-notes` until an id is assigned. Every
code path named below as new is **planned**. Every file:line reference is to `main` at
`67701f8`.

Where it comes from: the design note *Voice in Muster* (2026-10-21, desk research against
`67701f8`) compared four designs for voice against the invariants. It recommended
asynchronous voice notes over the existing room first, and live calls only through a separate
ADR, labelled content-private, never metadata-private. This is that first part. The note is
not in the repo; everything in it that bears on this design is carried here, in §10 (what
still leaks) and §15 (what is not verified).

The idea in one paragraph: a member records up to 60 s. `muster_module` captures it, encodes it
as constant-bitrate Opus, and holds it as a draft in memory. Nothing is posted until the member
presses Send on a surface that has already said who will see what. Send splits the clip into
exactly two author-signed `voice/…` events, sealed under the epoch key as text is, each padded
to one fixed size. So every note costs the same two frames on the wire, whatever its length.
Members fold the parts into notes, and the thread shows a card. Play decodes in the module and
hands PCM to the speaker. No voice method returns audio, in either direction. Two existing
methods that return raw log content would carry it, and §10 says how each is closed.

## 1. Goal and non-goals

Goal: a member can record a voice note in a room, hear it back, and send it, and every member
can play it. The design promises the following, and §10 names what it does not:
- content confidentiality as text has it: sealed per epoch, readable by members only (F-16);
- authorship: each note is signed by its author, so a forged one drops out of the room's view
  (exo-f76, invariant 9);
- a store node can tell that a note was sent, to which topic and when, but not how long it is
  (FS-9).

Non-goals for v1:
- **Live calls.** Live audio cannot ride the room transport: every send is stored, messages are
  capped at 150 KiB, and receive is not real-time. Calls are a separate ADR (the design note's
  option B: relay-only, content-private).
- **Re-sharing to late joiners.** A member admitted after a note cannot play it (invariant 7),
  and v1 has no way to share it again into the new epoch. FileShare has one (room-swarm.md §5.3).
- **Transcription, speech-to-text, effects.** Audio is never interpreted.
- **Windows.** The pinned builders have no Windows path (`docs/design/platforms.md`, R8).
- **Attaching a note to an intent.** A note signs nothing for a chain (§16).

## 2. Why room events, not FileShare

FileShare (exo-4d0, `room-swarm.md`) carries sealed blobs of any size, and on first sight it
looks like the natural carrier. It is the worse fit here:

| | Room events (chosen) | FileShare blob |
|---|---|---|
| Needs | nothing new: the room's own transport | `storage_module` installed and running, and a seeder online (`storage_readiness`) |
| Offline members | the store keeps the frames, so a member who was away catches up | a member needs a seeder reachable when they fetch |
| New observers | none: room member and store node | the storage DHT (CID and providers) and storage peers (each seeder's IP), room-swarm.md §5.5 |
| Size of a 60 s note | about 126 KB of clip in two 90 KB frames (§5) | built for multi-MB files; Padmé padding unbuilt (room-swarm.md §7 S2) |
| Private fetch | the room path is already the only path | over Mix, about 15 KB/s: about 8 s for a 120 KB note |

A 60 s note at 16 kbps is the same scale as the largest event the tree already sends: a Monero
multisig blob part of `XBlobPart = 90_000` hex characters per event
(`module/src/coordination/xmr_msig_spend.nim:40`). If notes ever outgrow two frames, FileShare
is the path; v1 does not need it.

## 3. Wire format

### 3.1 Codec

libopus 1.5.2 (nixpkgs at the builder's pin `e9f00bd`, BSD-3), with these settings:
- 48 kHz mono, 20 ms frames (960 samples);
- `OPUS_APPLICATION_VOIP`, `OPUS_SET_SIGNAL(OPUS_SIGNAL_VOICE)`;
- **hard CBR** (`OPUS_SET_VBR(0)`) at 16,000 b/s;
- DTX 0, in-band FEC 0, complexity 5, maximum bandwidth wideband.

Why these settings:
- **CBR.** With CBR the clip's size is a pure function of its duration, so the fixed padded
  size of §4 can be tight. RFC 6562 §5 and RFC 7587 §3.1.2 both prefer CBR under encryption.
  In a throwaway prototype on this builder's toolchain (Apple M5, 2026-10-21, not in the
  repo), every packet came out at exactly 40 B, for a 1 kHz tone, for silence, and for a mix
  of the two. The encoder pads a short packet up to 40 B with `opus_packet_pad` and refuses a
  longer one.
- **DTX and FEC off.** DTX would shrink silent frames. FEC is useless inside a sealed blob,
  which loses no packets.
- **16 kbps** is Opus's recommended floor for wideband speech.
- **Complexity 5** encoded 60 s in about 0.26 s in the prototype, against about 1.0 s at
  complexity 10. That matters because dispatch is synchronous.

The binding is `importc` with no header, in the style of `module/src/crypto/sodium.nim`. The
ctl functions are declared `{.varargs.}`. Every value argument is passed as `cint` (libopus's
`opus_int32`), never a Nim `int`, which is 64-bit: read back by `va_arg` as an `opus_int32`, it
comes out right only by accident of little-endian layout. Every GET argument is a `ptr cint`.
In the prototype, a fixed-arity `opus_encoder_ctl` returned `OPUS_OK` but set the wrong value
on Apple arm64: `SET_BITRATE(16000)` read back as 300000. Apple arm64 passes variadic
arguments on the stack and fixed ones in registers, so a fixed-arity binding goes wrong there.
AAPCS64 Linux and SysV x86_64 pass both the same way, so there the two bindings behave alike.
CBR sizes follow from the bitrate, so that bug would silently break §4. The codec test reads
every setting back (S1).

### 3.2 The clip record

A CDE record built with `module/src/dcbor` (invariant 5), with no Ogg: no CRCs, no random
serial numbers, no libopusenc. A CDE array of `bstr` is length-prefixed framing for free.

```
{ v: 1, codec: "opus", rate: 48000, ch: 1, frame: 960, br: 16000,
  preskip: <encoder lookahead, 312 in the prototype>, samples: <exact count>,
  packets: [ * bstr ] }
```

- **Why `preskip` and `samples` are stored.** They let the decoder trim the lookahead and the
  zero-filled last frame.
- **Decode is defensive.** libopus decodes room-supplied bytes inside the core, so decode
  checks the structure first, without libopus. It refuses:
  - any other `codec`, `rate`, `ch`, `frame` or `br`;
  - a packet of 0 bytes or over 1,275;
  - `samples` over 2,880,000 (60 s);
  - a packet count other than `ceil((samples + preskip) / 960)`;
  - trailing bytes.

  It then requires `opus_packet_get_nb_samples == 960` for every packet before decoding. A
  refusal is an error value, never a raise and never a Defect.
- **Digest.** The clip's digest is a domain-separated hash-input record over its bytes,
  `muster.voice.clip.v1`. There is no ad-hoc concatenation of the kind `newMessageEvent`
  still uses for message ids (`intent_events.nim:598-612`).

### 3.3 The events

A note is exactly two author-signed events, one per half of the record's bytes:

```
key    voice/<nid>/<author>/<i>/2          i ∈ {0, 1}; author = 128 hex (ed25519 ‖ x25519)
value  {"v":1, "ts":<int s>, "durMs":<int>, "digest":"<64 hex>", "part":"<base64>",
        "authorSig":"<128 hex>"}
nid    16 bytes (32 hex) of digest(hashInput("muster.voice.note-id.v1", author, clip digest, ts))
```

- **Integers only.** Every number is an integer: an author-signed value refuses a float
  (`authorship.nim:95`). `durMs` is the record's own duration, `samples / 48`.
- **Base64, not hex.** The value must be JSON text (`log/log.nim:48-58`). At 4/3, base64 fits
  a 60 s half in one frame; hex at 2× would need three parts.
- **The note id is content-addressed** over (author, clip, ts), so every member derives it,
  and nobody can post under another member's note id (§6).
- **The author is in the key.** `authorOf` classifies events on every hosted read. `message/`
  and `file/` parse their value's JSON to find their author (`authorship.nim:100-125`), but
  that would mean parsing an 84 KB value per voice part on every tick. So the branch reads the
  key:

  `if p[0] == "voice": return (true, (if p.len >= 3: p[2] else: ""))`

  A malformed shape is still author-bearing, so it can never verify. The `authorship.nim`
  header table gains the row, and `authorship_test` gains a section §11, appended (invariant
  tests are append-only).
- **No `parents`.** A part is built the way `newMessageEvent` builds a message, with
  `parents` empty; its order rides `after` (`docs/design/causal-parents.md`). §5's worst case
  assumes `"parents":[]`.
- **Publishing.** Each part is published through `publishAuthored(s, ks, e)`, and
  `session.publish` pads every `voice/` key to `VoiceFrameBytes` itself (§4). No call site
  passes the pad, so none can forget it.

### 3.4 Constants

| Name | Value | Why |
|---|---|---|
| `VoiceMaxMs` | 60,000 | the cap the device callback enforces (§9) |
| `VoiceMinMs` | 500 | shorter is refused at Send (`too-short`) |
| `VoiceBitrate` | 16,000 | §3.1 |
| `VoiceParts` | 2 | a fixed part count, so the count says nothing about length |
| `VoiceFrameBytes` | 90,112 (88 KiB) | the padded plaintext of every voice frame (§4, §5) |

Changing any of these after release strands notes already sent: a new value is a `v: 2`.

## 4. Padding: `session.publish(padTo)`, and why the pad goes on the frame

**Today.** `session.publish` ingests the event, encodes it as JSON (`encodeEvent`, not
exported), seals it and sends `@[FrameData] & s.crypto.seal(encodeEvent(e))`
(`coordination/session.nim:168-184`). The seal is libsodium secretbox, which adds a 24-byte
nonce and a 16-byte MAC (`crypto/epoch_crypto.nim:144-147`). Nothing in `module/` pads
anything today.

**Planned (S4).** `publish(ev, padTo = 0)`. With `padTo > 0`, the event's JSON is followed by
ASCII spaces up to exactly `padTo` bytes before sealing. `padTo = 0` is today's path, byte for
byte, for every key but one:
- **A `voice/` key is always padded to `VoiceFrameBytes`.** `publish` sets that pad itself
  and raises on any other non-zero `padTo` for such a key.
- **Why the key decides, not the caller.** `publish` already has a second send path for the
  same event: one the log holds is re-sealed as the stored copy (`session.nim:168-184`). A
  retried Send or a re-announce takes it. If the pad were an argument at each call site, a
  path that forgot it would send an unpadded frame that shows the note's length, and nothing
  would fail.

So every voice frame is exactly 1 + 24 + 16 + 90,112 = **90,153 B**, on either path.

Why on the frame, not inside the value:
- `publishAuthored` signs the value first. Only then does it set `after = heads()` (0 to 8 ids,
  `log.nim:226`) and sign `afterSig` (`authorship.nim:279-287`).
- A pad inside the value would be fixed before those bytes exist, so it could not account for
  them.
- The pad sits outside `value`, so the event id does not change: the id hashes parents, key
  and the value's text, never the frame.

Older clients read it unchanged. `decodeEvent` is `parseJson(toStr(b))` (`session.nim:82-83`).
At the builder's Nim pin (2.2.4), the parser accepts trailing whitespace (5,000 spaces were
tried) and refuses trailing garbage; this was checked while planning, outside the repo. So:
- no new frame kind;
- no `room_journal` change: journal frames are opaque, with `MaxFrame` 16 MiB
  (`room_journal.nim:24`);
- a 0.3.x peer reads a padded frame as an ordinary event, and its thread ignores the `voice/`
  key (§7).

**What does not fit, raises.** An event whose JSON exceeds `padTo` raises `FrameTooLarge`
before anything is ingested, journalled or sent. Today nothing guards size: an oversized frame
lands in the sender's own log and reaches nobody, and a failed send is logged only under
`MUSTER_LP_DEBUG` (`transport/delivery.nim:118-123`).

## 5. Size budget

These figures are arithmetic, not measured. The S4 and S5 tests measure the worst case. A
60 s note is 2,880,000 samples. The encoder is flushed through its 312-sample lookahead, so by
§3.2's count it is ceil((2,880,000 + 312) / 960) = 3,001 packets.

| | Bytes |
|---|---|
| One Opus packet at 16 kbps, 20 ms, CBR | 40 |
| The same packet inside the CDE array (`bstr` header) | 42 |
| A 60 s record: 3,001 packets plus 77 B of header | 126,119 |
| The larger half | 63,060 |
| The same half as base64 | 84,080 characters |
| The event JSON, worst case: 128-hex author, `"parents":[]`, 8 heads in `after`, `afterSig` | about 85,257 |
| The padded plaintext, `VoiceFrameBytes` | 90,112 |
| Margin left in the worst case | about 4,855 |
| One frame on the wire: kind 1 + nonce 24 + MAC 16 + 90,112 | 90,153 |
| **One note, any length from 0.5 s to 60 s: 2 frames** | **180,306** |
| Delivery's per-message cap, as the tree assumes it (`xmr_msig_spend.nim:40`) | 153,600 (150 KiB) |

A 500 ms note is 26 packets, a 1,166 B clip, and still costs two full frames. That is the
price of hiding length.

The alternative was 12 kbps in one 128 KiB frame (§18). It would mean narrower speech, and a
single frame bigger than anything the tree sends today.

## 6. The fold

`reduceVoice(roomEvents(s))` (planned, `coordination/voice.nim`) is pure and order-free, and
it never links libopus. It imports only the clip record's structural checks. Its rules:

1. **Authentic only.** `roomEvents` has already dropped a part that is forged, unsigned,
   replayed from another room, or edited (`authorship.nim:262-277`).
2. **Shape.** The key is exactly `voice/<nid>/<author>/<i>/<n>`, with `n == 2`, `i` in
   {0, 1}, a 32-hex nid and a 128-hex author, all lowercase. The value holds the fields of
   §3.3 and no others: `v` 1, `ts` an integer, `durMs` an integer in 0..`VoiceMaxMs`,
   `digest` 64 lowercase hex, and `part` in canonical base64, the one spelling `encode` gives
   its bytes. Anything else is dropped without raising.
   - **Base64 is checked before it is decoded.** std/base64's `decode` (Nim 2.2.4,
     `lib/pure/base64.nim:252-262`) skips whitespace inside its 4-character loop and then
     reads past the end of the string. `"    AB"` and `"AAAA     AAA"` each raise an
     IndexDefect, which no `except CatchableError` catches, and any member can sign such a
     part. So the fold first requires a length that is a multiple of 4, the standard
     alphabet, `=` only as final padding and zero spare bits, and only then decodes.
3. **The first copy stands.** In `canonicalOrder`, the first copy of each (nid, author, i)
   stands, and an equivocating later copy is ignored, as in `readBlob`
   (`xmr_msig_spend.nim:60-78`).
4. **No squatting.** `nid` must equal `noteIdOf(author, digest, ts)`, the same refusal
   `fileIdOf` makes for a squatted file id (`swarm.nim:135`).
5. **The parts must agree.** Both carry the same `ts`, `durMs` and `digest`. The reassembled
   record must match that digest and pass the structural checks of §3.2, and `durMs` must be
   its own duration.
6. **States.** A note is one of:
   - `complete`: both parts, every check passed;
   - `arriving`: one part so far;
   - `broken`: the parts disagree, the digest misses, or the structure fails.

   Only a complete note plays.
7. **Epochs.** A part sealed in an epoch this member never held never opens, so the fold never
   sees it (F-16).

The result is `{nid, author, ts, durMs, state, parts}` per note, ordered by (ts, nid), where
`parts` names the standing parts' event ids. The fold runs in two passes:
- **The header pass** reads each part's key and value and checks rules 2 to 4, base64
  spelling included, but decodes nothing. It decides which parts stand and which notes exist.
  `threadLastTs` needs nothing more, because a note's row is there whatever its state.
- **The verdict pass** judges a note of two parts by rules 5 and 6. It decodes the halves,
  then checks their agreement, the digest and the record.

**The memo.** A verdict is a pure function of the two standing parts' event ids, because an
id is a content address. So `reduceVoice` and `threadRows` take an optional `VoiceMemo`,
keyed by those two ids, which holds complete and broken verdicts alike:
- the hosted layer keeps one per session (S7), so a clip is not decoded and checked on every
  read;
- a part that comes to stand in another's place, such as an equivocating copy that sorts
  first, makes a new key, so its note is judged afresh;
- it grows by one entry, about 140 B, per pair of parts that ever stood, against their two
  90 KB frames in the log.

Measured on darwin-arm64 (`-d:release`, 20 notes of 60 s in the authentic view, outside the
repo), per call:
- with no memo, about 44 ms, or 2.2 ms a note;
- with a warm memo, about 12 ms;
- `threadLastTs`, about 13 ms.

What a warm memo still pays is the header pass: parsing each 84 KB value and hashing its
event id. `coordinate_messages` polls each second and `coordinate_conversations` folds every
room, all on the module thread, so a few such rooms still cost tens of ms a second. S7
measures again with the hosted reads (§15).

## 7. Thread rows

The thread is `coordinate_messages`, which returns every message body on each 1 s poll
(`muster_module.nim:4582-4594`). Audio must never ride that. So a note is never a `message/`
event, and there is no pointer message as `intent-ref` uses.

Instead, a planned `threadRows(events)` merges `reduceMessages(events)` with one synthesized
row per note, ordered by (ts, id). The row carries the note in a field of its own, `voice`,
never in `body`. That field is metadata only, under 300 B:

```
{ "id": "<nid>", "author": "<reduceVoice's author>", "ts": N, "body": "",
  "voice": { "v": 1, "note": "<nid>", "durationMs": N, "state": "complete|arriving|broken" } }
```

`musterCoordinateMessages` adds `alias` and `self` to it, as to every row.

**Only `threadRows` can make a voice row, and `voice-note` is a reserved kind.** Without
that, a member could forge a note row:
- Any member, or any co-resident module, can post a `message/` whose body is a typed card as
  JSON `{kind, ...}` (`muster.lidl:119`).
- `reduceMessages` passes bodies through unchanged (`intent_events.nim:614-629`).
- RoomThread makes a card of any body that parses to an object with a `kind`
  (`RoomThread.qml:71-79`).

So a body `{"kind":"voice-note","note":"<Alice's nid>",…}` would draw as a voice-note card
under the forger's name, and its Play would play Alice's audio. That attributes one member's
voice to another, against invariant 9. Three rules close it:
- **The fold alone sets `voice`.** `reduceMessages` builds a row from a message's `author`,
  `ts` and `body` only. `musterCoordinateMessages` serializes just those fields
  (`muster_module.nim:4590-4593`). So no `message/` event can put a `voice` field on a row.
- **The card draws from `modelData.voice` alone.** RoomThread's `parsedCard` refuses
  `voice-note` from a body, so a `message/` that claims it falls through to plain text: the
  forger's raw JSON, under the forger's name.
- **The card names the fold's author.** The row's `author` is `reduceVoice`'s: the key author
  that `roomEvents` verified (§3.3, §6 rule 1), never anything a message says.

`voice_play` takes the nid alone and checks no author. The only rows that carry a nid in
`voice` are made from the fold, so the name on the card is the note's author by
construction. A co-resident module can call `voice_play` with any nid, but that draws no card
and names nobody (§13).

`threadRows` is used in exactly two places:
- `musterCoordinateMessages`, in place of `reduceMessages` (`:4590`);
- the `lastTs` of `coordinate_conversations` (`:4640-4641`), so a note moves its room up the
  list. That one reads `threadLastTs`, the newest row's ts from the fold's header pass (§6),
  which judges no clip.

`reduceMessages` itself is unchanged. Three things read address shares from it:
- `settle_up.nim:81`;
- `send.nim:28`;
- the shared-address readers in `intent_events.nim` (`:643`, `:664`).

What this means for each kind of reader:
- **The thread.** RoomThread gains a delegate branch that draws a new `CardVoiceNote.qml`
  from `modelData.voice`, beside the `MusterCard { card: msg.parsedCard }` branch
  (`RoomThread.qml:692-695`). `MusterCard.known` (`MusterCard.qml:712`) does not gain
  `voice-note`, because no body may carry it. `CardVoiceNote.qml` is pure render: it emits
  `play` and `stop`, and RoomThread owns the backend calls, as for every card.
- **A 0.3.x peer** shows nothing for a note in its thread: it never synthesizes the row, and
  `reduceMessages` skips the `voice/` events. That is better than its unknown-card render: an
  unknown kind draws nothing, or a stray heading, never a text fallback
  (`RoomThread.qml:693, :722`). Its information-flow view and room map do show each part, as
  an unknown `voice` entry: envelope rows only (`flow.nim:121-124`), and an entry node of kind
  `voice` with basis `sealed` (`room_graph.nim:299-331`).
- **Older clients in general.** S8 fixes that fallback for the next unknown kind, but clients
  already released keep it.

## 8. Record → draft → send

```
             voice_record_start               voice_record_stop, or the 60 s cap
   idle ─────────────────────────▶ recording ─────────────────────────────────▶ draft
    ▲                                                                          │   │
    │                voice_draft_send: two frames published                    │   │
    ├──────────────────────────────────────────────────────────────────────────┘   │
    └──────────────────────────────── voice_draft_discard ─────────────────────────┘

   voice_play(note | "draft"), from idle or draft → playing → (end, or voice_play_stop)
                                                              → back where it was
```

**The draft.** It lives in module memory only: never on disk, never over IPC. A crash loses
it. There is one draft at a time. Nothing is posted without Send. The draft surface shows Play,
Send, Discard and the disclosure lines first (material-and-disclosure.md §4, rule 2: "Nothing
is disclosed without an act"). Proposed wording, for S8:

> Everyone in this room can play it. Your voice can identify you, here and outside this room.
> The store node sees two sealed frames of one fixed size, and when.

**The methods** (planned for `muster.lidl` in S3 and S7). Each one returns at once. Parameter
names avoid C++ keywords (`7480de8` renamed `private` for that reason), and every method
declares a return type.

| Method | Returns |
|---|---|
| `voice_status()` | the JSON below; it also drives the voice pump |
| `voice_record_start()` | `{ok}`, or `{error}`: `not-joined` · `busy` (recording, playing, or a draft held) · `no-device` |
| `voice_record_stop()` | `{draft: {durationMs, silent, peak}}`, or `{error}` |
| `voice_draft_send()` | `{note}`, or `{error}`: `no-draft` · `silent` · `too-short` · `not-joined` · `too-large` |
| `voice_draft_discard()` | `"ok"` |
| `voice_play(note_id)` | `"draft"` or a note id; `{ok}`, or `{error}`: `unknown-note` · `incomplete` · `broken` · `busy` · `no-draft` |
| `voice_play_stop()` | `"ok"` |

`voice_status` returns integers, strings, booleans and null, never a float, and never audio:

```
{ ready:     { capture: "unknown|ok|no-device|…", playback: "…", codec: "<opus_get_version_string()>",
               note: "<a platform note, e.g. §11's, or empty>" },
  recording: { state: "idle|recording|draft", elapsedMs, capMs: 60000, peak, capped, silent, error },
  playing:   { note, positionMs, durationMs } | null }
```

**Refusals at Send:**
- **Silent.** A recording whose samples are all exactly zero is refused as `silent`, and the
  platform note says why (§11). A low but non-zero peak is only a warning.
- **Too short.** Under 500 ms is refused as `too-short`.

**Polling only.** The `.rep` declares no SIGNAL, the module has no clock
(`docs/design/side-modules.md:66`), and the SDK's `emit` callback is a threadvar, so the audio
thread cannot emit. So:
- `voice_status` drives `voicePump`, as `fileshare_files` drives `fileSharePump`
  (`muster_module.nim:2778`);
- `coordinate_intents` also calls it, from its pump list (`:2854-2861`);
- the UI polls `voice_status` every 250 ms while not idle;
- the room's 1 s timer reads it too, so a recording any caller started shows a banner (§13).

Elapsed time on screen comes from a QML clock. The module's cap is the one that counts.

## 9. Devices, threads and the build

**The `AudioIo` seam** (planned, `module/src/audio/audio_io.nim`). It is built in the shape of
`Transport` and `BlobStore`, and no test mocks it (CLAUDE.md working agreements). Its
implementations:
- `SyntheticAudioIo`: deterministic PCM on a virtual clock, with a collecting sink. It is the
  in-process stand-in, as `LocalBlobStore` is.
- `FileAudioIo`: a 48 kHz mono s16 WAV source (`MUSTER_VOICE_SOURCE`) and a raw PCM sink
  (`MUSTER_VOICE_SINK`), for the offscreen self-test (S9).
- `MiniaudioIo(system | null)`: miniaudio's null backend runs the real device-thread path with
  no device and no permission prompt. Real-device tests sit behind `MUSTER_VOICE_REAL`, in
  run-suite's E2E list (S11).

**The device callback.** miniaudio calls it on a thread Nim does not own, so it follows the
same rule as `transport/inbound_queue.nim:1-11`:
- no GC allocation, no raise, no Defect (a Defect there takes down `logos_host`);
- `ptr UncheckedArray` and an explicit `min()` everywhere;
- only atomics shared with the module thread.

**Capture.** One buffer, `allocShared0` at record start, sized to the cap: 60 × 48,000 samples
× 2 B = 5,760,000 B.
- It is **linear and never wraps.** The callback advances an `Atomic[int]` write index, stops
  writing at the cap and sets `capped`. However long the module thread is busy, the buffer
  cannot overflow.
- **Only this thread can enforce the cap.** The module has no clock, and a Stop can queue
  behind a 20 s sync call.
- **The module thread drains it.** The voice pump reads from its own index and Opus-encodes 20
  ms at a time. Stop therefore finds at most about 1 s of audio left to encode. The same pass
  keeps the peak and the all-zero check.

**Playback.** The module thread checks the note (§3.2) and decodes it whole into a shared
buffer; the prototype decoded 60 s in about 27 ms. The callback copies out at an atomic read
index, writes zeros past the end and sets `done`. The pump then releases the device.

**Device lifetime.** A device is opened lazily, by `voice_record_start` or `voice_play`, and
bounded. With the access policy off, any caller can make those calls (§13). It is stopped and
uninitialised on the module thread only, never from the callback: on stop, on done, and before
the module unloads. That is the `abandoned` lesson from the storage FFI (CLAUDE.md, pattern
sources). The module has no unload hook yet: the generated surface exports none
(`muster_gen.nim:392-438`: seven `logos_module_*` entry points and a constructor), so nothing
calls `MiniaudioIo.close`. S3 opens no context, so nothing is left open today. S7 must wire
`close` before it opens a device: a miniaudio context, and its backend's threads, left alive
when the host unloads the plugin is a crash risk.

**The build** (planned, S1–S3):
- **libopus** comes from nixpkgs as libsodium does: `codegen.nim.link += "opus"` and
  `nix.packages.runtime += "libopus"` (`module/metadata.json:55`, `:173`).
- **miniaudio 0.11.23** comes in as a `codegen.nim.packages` fetch, pinned at
  `f40cf03f80cdb7e741d43e53b7e706e8c1394bcf` (the hash nixpkgs uses for its source). It is
  compiled into the staticlib with `{.compile.}`, with a global
  `{.passC: "-I<dir> -DMA_…".}` computed from `querySettingSeq(searchPaths)`.
  - **No C is tracked**, so `scripts/check-no-cpp.py:35-45` still passes.
  - **The flags are global** because the backend defines change struct layouts.
  - **Backends.** `MA_ENABLE_ONLY_SPECIFIC_BACKENDS` keeps CoreAudio, PulseAudio, ALSA and
    Null. The system IO never lists Null, so a machine with no backend says `no-device`, and
    never records zeros.
  - **Runtime linking is kept.** miniaudio dlopens the platform's audio libraries itself. On
    macOS the staticlib's only new undefined symbol was `_dlopen` (prototype). Framework entries
    on the flat link list would also land on the Linux link line.
- **The test harness** learns libopus and miniaudio as well: `module/tests/run-suite.sh` and
  the host-harness probe (`probe_return_marshalling_host.nim`), or the suite goes red (S1, S3).

## 10. Who sees what

| Observer | Sees | Never sees |
|---|---|---|
| room member (epoch-key holder when the note was sealed) | the note itself, played: the audio, its author (signed), its length and time | — |
| store node (delivery) | that the room's topic carried two frames of 90,153 B each, and when; the publishing node, unless `mix` is on; a frame that size marks a voice note | its length, which member sent it (FS-7), the audio |
| relay-mesh peers | the publishing node of each frame, as for any send, unless `mix` is on | the content, the member |
| mix node (`mix` on) | a hop of each frame, if mix carries frames this size: **untested** | the endpoints together |
| a module loaded beside Muster (access policy off) | the voice state and peak level; it can start a recording, send or discard the draft, play the draft or a note aloud (§13); until the operator decides (below), the clip itself, through `coordinate_proof`, which returns raw log content (S6 closed `coordinate_graph`) | the audio through any voice method: none returns it |

**Two methods that return raw log content.** No voice method returns audio. But a part's value
holds its half of the clip as base64 Opus, and two existing methods hand event values to any
caller:
- **`coordinate_graph`**, the room map, copies every field of a JSON-object value into the
  entry's `content` (`room_graph.nim:198`), and does so for every entry (`:348`). A voice
  part's `part` would go with it.
- **`coordinate_proof`** returns every raw log event, value and all (`proof.nim:79`,
  `muster_module.nim:3230`). A proof must carry each value whole: the verifier recomputes
  every event's id from it, and the id hashes the value's text itself (`muster.event.v1`,
  `log.nim:48-58`). So the field cannot simply be left out.

Left as they are, both methods give any caller the Opus of every note in the room. That
contradicts the decision that audio plaintext never crosses IPC (§18), and §13. The two cases
differ:
- **`coordinate_graph`: S6 strips it.** A `voice/` entry's `content` carries no `part`: at
  most `v`, `ts`, `durMs` and `digest`. `voice_test` pins that field by field.
- **`coordinate_proof`: the operator decides** (§18). One option keeps raw values, since a
  proof accounts for every entry, and says here that a proof export carries the audio. That
  amends the IPC decision for this one explicit export. The other is a proof form that
  carries a voice part as a committed digest. Because today's id hashes the value itself,
  that means a new proof format, and perhaps a new id derivation, not a filter on today's.

**What the code adds** (planned, S6):
- **A `voice/` branch in `flow.nim`.** Today an unknown prefix falls through to envelope-only
  rows (`flow.nim:121-124`), which would show the room nothing about its own content. With the
  branch, each part shows:
  - room-member: `voice-note`, `voice-note-length`;
  - store-node: `timing`, `topic`, `fixed-size`.
- **The room map.** A `room_graph` entry, with basis author-signed and kind `voice`
  (`room_graph.nim:69`, `:327`). Its `content` carries no `part` (above).
- **Provenance.** A `logProvenance` entry as a peer message (`intents.nim:829`).

`voice_test` pins those rows field for field, the way `swarm_test` §8 pins FileShare's.

**The claim** (planned for S10, under FS-9 and worded narrowly; credibility imperative):

> **A voice note's length does not show in its size.** Every voice note leaves as two sealed
> frames of one fixed size, whatever its length, so a store node can tell that a voice note was
> sent, to which room's topic and when, but not how long it is. It still sees the conversation
> graph (the gap above).

Its test is `module/tests/probes/probe_voice_fixed_size_stepper.nim` (S5), which covers
durations from 0.5 s to 60 s, 0, 1 or 8 heads, and two epochs. It also publishes the same note
twice, so the second goes out on the held path (§4), and asserts that both frames are
90,153 B. It sits beside the existing gap
*The store node still sees the conversation graph* (`contracts/claims/registry.json:83`) and
does not soften it.

**What still leaks.** The design note listed these, and each stays true after this PR:
1. **A voice is a biometric, against FS-7.** FS-7 scopes a member's identity to the room. A
   voice undoes that for everyone who hears it:
   - a listener in two rooms can tell that the same person speaks in both;
   - a voice can tie a member to a real person;
   - nothing stops a listener re-recording playback.

   The draft surface says so before Send (§8).
2. **Size and timing are visible.** The store node sees the two frames at the moment of Send.
   Their size marks them as a voice note: chat frames are far smaller, and the largest
   events the tree sends today, Monero multisig blob parts, are of the same scale. Only the
   length is hidden. Like text, the store keeps the
   ciphertext for as long as the fleet's capacity policy allows, and `room_journal` keeps it
   sealed on every member's disk. A note is exactly as forward-secret as the room's text: a
   later holder of that epoch's key opens it.
3. **Co-resident modules, with the access policy off** (§13).
4. **Leaving re-keys nothing.**
   - `coordinate_leave` announces nothing and re-keys nothing (`muster.lidl:133`).
   - No method removes another member: F-16's "Removing a member rotates the epoch
     immediately" is not built.
   - So a member who left can still open every later note, as they can open later text, by
     reading the topic again.
5. **No mix test.**
   - Nothing has sent a 90 KB frame under `mix = preferred | required`.
   - Whether delivery 0.3's mix path carries a frame this size is unknown.
   - Today a send that fails is visible only under `MUSTER_LP_DEBUG`.
   - Voice notes make no mix claim, and the gap *The store node still sees the conversation
     graph* (`contracts/claims/registry.json:83`) stays partial.

The S10 registry entries carry these as gaps unless the maintainer prefers them folded into
existing entries:
- "a voice can identify the speaker" (exposed; the party is everyone who plays the note);
- "modules loaded beside Muster can record and send as you" (exposed; the party is the
  co-resident modules);
- "leaving re-keys nothing" (exposed; the party is a former member). It is a room-wide gap
  that no entry names today.

## 11. macOS

Read on the installed `/Applications/LogosBasecamp.app` 0.3.2 (2026-10-21, with `codesign`
and `PlistBuddy`):
- `Contents/MacOS` holds `LogosBasecamp`, `LogosBasecamp.bin`, `logos_host` and `ui-host`.
  `logos_host`, where `muster_module` runs, and `LogosBasecamp.bin` are both signed with the
  hardened runtime (`flags=0x10000(runtime)`).
- `logos_host`'s entitlements are `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.disable-library-validation` only. There is no
  `com.apple.security.device.audio-input`.
- `Info.plist` has no `NSMicrophoneUsageDescription`.

What follows from that is inferred, not tested. There are two possible outcomes, and nothing
here says which one happens:
- **Zero-filled buffers.** From Apple's hardened-runtime rules and OpenJDK bug JDK-8244951,
  CoreAudio capture inside `logos_host` succeeds and delivers zeros, with no error and no
  prompt. That precedent is weaker than it looks: JDK-8244951 is a command-line `java` run
  from Terminal, so TCC charges the request to Terminal, an Apple app. `logos_host` is a
  helper inside a third-party app whose `Info.plist` has no usage string, and that case does
  not transfer.
- **TCC terminates `logos_host`.** macOS can kill a process that asks for the microphone
  without a usage description ("Termination Reason: Namespace TCC"). Then pressing Record
  kills `logos_host` and every module in it, and the `silent` refusal below never runs.

S11's first macOS check settles it. Under Basecamp 0.3.2, with a throwaway profile, it calls
`voice_record_start` and observes whether `logos_host` survives. It runs before anything
relies on the `silent` refusal. If `logos_host` does not survive, that goes back to the
operator, because it bears on the decision to keep the record button.

Launching Basecamp from Terminal does not help in either case, because `logos_host` itself is
the hardened binary without the entitlement (also inferred). Playback needs no permission.

The answer (decided):
- **Keep the record button.**
- **Refuse an all-zero recording at Send** with error `silent`. The module supplies the note
  (`hostOS == "macosx"`), so both UIs show the same words. Proposed wording: "Basecamp 0.3.2
  can't use the microphone on macOS yet: it lacks the microphone permission."
- **Never post silence.** A note of zeros would be a lie the card cannot show.

**The upstream ask** (not filed: filing is a public post, and that is the operator's call):
Basecamp adds `com.apple.security.device.audio-input` to `logos_host`'s entitlements (and the
app's), adds `NSMicrophoneUsageDescription` to `Info.plist`, and re-signs.

**Outside Basecamp.** An unbundled, nix-built binary is charged to the terminal app that runs
it, and macOS asks the person to grant that app the microphone. S11's opt-in microphone test
runs only with that consent.

## 12. Linux

All of this is unverified, because there is no Linux host here.
- **What miniaudio loads.** It dlopens `libpulse.so` or `libpulse.so.0`, and
  `libasound.so.2`. PipeWire answers through `pipewire-pulse`.
- **Portable `.lgx` and the AppImage.** `logos_host` uses the system loader, so the distro's
  libraries should resolve (inferred).
- **A nix-built dev runner.** Nix glibc's loader does not read `/etc/ld.so.cache`, so a dlopen
  by soname may find nothing. The system backend then reports `no-device`; it never records
  silence, because Null is not on its list.
  - The fix to try: `libpulseaudio` in `nix.packages.runtime`, so its lib dir joins RUNPATH.
  - The list is flat, so it would enter the darwin closure too.
  - A runner that drops nim.link libraries from RUNPATH has bitten before
    (`docs/labbook/nim-cdylib-modules-cannot-load-in-basecamp-sdk-skew.md`).

## 13. Co-resident callers, with the access policy off

Basecamp runs with the access policy off by default, so any loaded module can call any other
(`docs/basecamp-access-policy.md:3`, `side-modules.md:102`). A Nim provider cannot see its
caller. So any module loaded beside Muster can:
- call `voice_record_start` and turn on the microphone;
- send the draft, with `voice_draft_send`, before the member decides. The note is signed with
  the member's key, as `coordinate_post_message` already lets such a module post text in the
  member's name;
- destroy the draft, with `voice_draft_discard`, before the member decides;
- play the member's unsent draft through the speaker, with `voice_play("draft")`. The draft is
  the one piece of audio this design otherwise keeps inside the module until Send;
- play any complete note aloud, with `voice_play`;
- poll `voice_status`. Its `peak`, read and reset at the poller's own rate, is a coarse loudness
  envelope of a recording or playback in progress. Whether to coarsen it (one value per 100
  ms, a few levels) is open for S7.

What it cannot do is read audio through a voice method: none returns it, and `voice_status`
carries state, position and peak only. That is unlike `coordinate_messages`, which serves
room plaintext to any caller (`side-modules.md:104`). Two methods that return raw log content,
`coordinate_graph` and `coordinate_proof`, would hand it the clip. S6 closes the first, and
the second is the operator's decision (§10, §18).

**The mitigations:**
- **A banner.** The room's 1 s timer shows a recording banner from `voice_status`, whoever
  started the recording. In headless `logoscore` nothing shows.
- **The real fix** is `--access-policy enforce` with `muster_module`'s allowed callers set to
  `muster_ui` (`docs/basecamp-access-policy.md`, `infra/access-policy.json`), or Basecamp's
  capability broker.

## 14. F-13: a message in another medium

F-13 closes the render vocabulary: `message`, `intent`, `fact`, `choice`, `artifact`,
`receipt`, plus system notices. Additions to it are core releases (`docs/01-furps.md:25`). This
design classes a voice note as a **message** in another medium:
- one member's words to the room;
- no agreement and no chain;
- authored and signed like text.

It is not an `artifact`. F-17 ties artifacts to Logos Storage content addressing
(`01-furps.md:29`), and a note rides the log.

`CardVoiceNote.qml` extends the UI's concrete card set, not the class vocabulary. The mic is
an `IconAction` in the message row (`RoomComposer.qml:1254-1314`, beside the existing send
`IconAction` at `:1305-1313`), not a
tile in `RoomActionPicker`, which is titled "Propose something" and whose every tile is an
intent. If the maintainer reads a new medium as a vocabulary addition, this is a core release,
and the PR says so (§18).

## 15. What is not verified

Nothing in this document is built. What is unverified even as a plan:
- **The audio facts came from a throwaway prototype on an Apple M5.** These are packet sizes,
  the varargs hazard, the null backend, encode and decode cost, and miniaudio compiled through
  `{.compile.}`. None of them has run through the real `logos-module-builder` derivation, and
  none has run on Linux.
- **Microphone capture under Basecamp's hardened runtime.** Neither outcome of §11 is
  observed: zero-filled buffers, or TCC terminating `logos_host`. S11 checks this first. Real
  capture anywhere without the person's grant is unobserved too.
- **Linux dlopen** of `libpulse` and `libasound`, from a portable `.lgx`, the AppImage and a
  nix-built runner; and PipeWire.
- **Delivery of two 90,153 B frames:**
  - over the live fleet;
  - with RLN on `logos.test`, where each note spends two sends;
  - under `mix = preferred | required`.
- **The cost of store catch-up.** It returns each payload as a JSON byte array
  (`delivery.nim:309-315`), so a voice frame inside the 60 s lookback is re-fetched as several
  hundred KB of JSON per query. That should be measured before anything is added; a seen-frame
  short-circuit only if it matters.
- **The cost of the fold.** `eventId`'s memo key concatenates the whole value (`log.nim:71-75`),
  and every hosted read re-runs `roomEvents` with no fold cache (the cache is
  `side-modules.md` S4, `exo-ff5.4`, not built). `voice.nim`'s own cost is measured (§6), but
  `roomEvents`' authorship checks over 84 KB values are not, and nor is the whole hosted read.
- **Audio over `coordinate_proof`** (§10). It still returns a voice part's `part`, and waits on
  the operator. S6 stripped it from the room map: an entry's content is `v`, `ts`, `durMs` and
  `digest` at most, and `voice_test` §14 finds no stretch of any half in the map `toJson` gives.
- **The size budget** (§5) is arithmetic until S4 and S5 measure the worst case.
- **Checks that are Linux-only or the maintainer's:**
  - the runner self-tests and `ui-parity.sh` for both UIs;
  - the Nim UI's `contract_test`;
  - `scripts/grade-specs.sh`, `exo-526` above all: its host probe now links libopus, through
    `.probe-env/opus`, a path no Mac run takes;
  - the Linux plugin links, by `lgx-variants.yml` on the fork (S3 linked darwin-arm64 only).
    Each Linux variant's bundled lib directory must hold `libopus.so.0`, and the plugin's
    `NEEDED` and `RUNPATH` must resolve it. The plugin links libopus at load (on darwin a
    plain, non-weak `@loader_path/./libopus.0.dylib`), so a variant without it fails all of
    `muster_module` to load, not only voice. `dlopen`, `dlsym` and `dlclose` must resolve from
    glibc there.

## 16. Invariants, checked

| # | How voice notes keep it |
|---|---|
| 3 | No plugin is involved. The core captures, encodes, seals and plays. |
| 4 | Notes are `reduceVoice(roomEvents(log))`, order-free and idempotent, and a property test permutes and duplicates the parts (S5 §9). The draft is not state: it is never posted until Send, and it is lost with the process. |
| 5 | The clip is a CDE record. The note id and the clip digest are hash-input records (`muster.voice.note-id.v1`, `muster.voice.clip.v1`). Values hold no float. |
| 7 | Parts are sealed under the epoch they were sent in. A later joiner never opens them, and v1 has no re-share. |
| 8 | Nothing new runs on a server: no relay, no storage, no service. |
| 9 | A note is named for its author only by its author's signature, and a forged or squatted part drops out. A `message/` cannot pose as a note: only the fold sets a row's `voice` field (§7). |
| 1, 2, 10 | Not bound: a note signs nothing for a chain and enters no effect. Attaching a note to an intent would make its digest an external read (F-20), and that is out of scope. |

## 17. Order of work

Each slice's test is written and run red before its code (worker.md), and every commit carries
`Tested-Behavior` or `TDD-Exempt`.

- **S0 — this document** (TDD-Exempt: docs).
- **S1 — The Opus binding, the clip record, the codec.** `audio/opus.nim`, `voice_clip.nim`
  (pure CDE), `voice_codec.nim`, plus libopus in `metadata.json` and `run-suite.sh`. Tests:
  `voice_clip_test` and `voice_codec_test`. The ctl read-back is the arm64 guard. It tells a
  fixed-arity binding from a varargs one only on darwin-arm64, so it must run on this Mac. On
  Linux it cannot tell the two apart (§3.1).
- **S2 — The `AudioIo` seam and miniaudio on the null backend.** Tests: `audio_io_test` and
  `audio_io_null_test`, which cover the cap, `capped`, `busy` and idempotent uninit.
- **S3 — A native build gate.** `voice_status` in `muster.lidl`, with the marshalling probe
  linking libopus and miniaudio.
- **S4 — Fixed-size sealed frames.** `session.publish(padTo)`, the `voice/` key rule (§4) and
  `FrameTooLarge`. Test: `session_pad_test`.
- **S5 — Events, authorship, the fold, thread rows.** `coordination/voice.nim`, the `authorOf`
  branch, `voice_test`, `authorship_test` §11, and three stepper probes: fixed size (with the
  held-path case of §10), author, and order. The author probe includes a forged row: a
  member's `message/` that claims `voice-note` with another member's nid. `threadRows` gives
  it no `voice` field, so it neither renders as a voice card nor plays under the forger's name
  (§7); S8 pins the render side.
- **S6 — Disclosure.** The `flow.nim` branch, the room map and provenance, with the rows pinned
  in `voice_test`. A `voice/` entry's room-map `content` carries no `part` (§10), pinned field
  by field.
- **S7 — The hosted surface and its state machine.** `voice_live.nim`, the six remaining
  methods, `voicePump`, and `threadRows` in `coordinate_messages`, and `close` before the
  module unloads (§9). The session keeps a `VoiceMemo` and passes it to every `threadRows`;
  `coordinate_conversations`' `lastTs` reads `threadLastTs` (§6). `coordinate_proof` follows
  the operator's decision (§10). Test: `voice_live_test` on `SyntheticAudioIo` and
  `LocalTransport`, which holds §8's type rule (no float) in every state.
- **S8 — The UI.** The `.rep` (both backends, ADR-019), `CardVoiceNote.qml`, the mic in the
  composer, observer and kind labels, the regenerated gallery `FakeBackend.qml`, and the
  unknown-kind fallback. A gallery fixture holds a forged `voice-note` body, and RoomThread
  must draw it as plain text (§7).
- **S9 — End to end.** `scripts/voice-self-test.sh`: two offscreen runners, A sending from a
  generated WAV and B playing into a PCM sink, with a 1 kHz Goertzel check. Plus the autopilots
  in both backends and a `ui-parity.sh` entry.
- **S10 — The claim, docs, labbook and layout.** The protects claim and the gaps of §10, and the
  CLAUDE.md layout.
- **S11 — Checks on a Mac display, the opt-in device test, and the draft PR.** First, before
  anything relies on the `silent` refusal: under Basecamp 0.3.2, with a throwaway profile,
  does `logos_host` survive `voice_record_start`? If it does not, that goes back to the
  operator (§11). Test: `voice_device_e2e`, behind `MUSTER_VOICE_REAL`. Its microphone leg
  runs only with the person's consent.

## 18. Decisions

Decided by the operator (2026-10-21):
- **Length.** At most 60 s.
- **Codec.** libopus, hard CBR at 16 kbps, 48 kHz mono, 20 ms frames, DTX off, FEC off.
- **Shape on the wire.** Every note is exactly two author-signed parts, and each sealed frame
  is padded to 90,112 B of plaintext (`VoiceFrameBytes`), through `session.publish(padTo)`.
- **Carrier.** Room events, not FileShare (§2).
- **Where audio lives.** Capture, playback and Opus live in `muster_module`, and audio
  plaintext never crosses IPC.
- **macOS.** Keep the record button, and refuse an all-zero recording as `silent` with the
  Basecamp 0.3.2 note (§11).
- **Process.** Open as a draft PR that asks the maintainer for an exo id and for spec sign-off.

Asked of the maintainer (corpetty):
- **An exo id for the epic.** Until it exists, commits use the `voice-notes` scope, and nothing
  touches `.pebbles/`.
- **The typed spec.** It would be `derived-exo-<id>`, through `discuss-issue`, with your
  sign-off. The probes are written in stepper form now, as its oracles.
- **The wire format, §3–§5, before S4 lands.** The alternative was 12 kbps in one 128 KiB
  frame. Changing the format later strands notes already sent.
- **F-13** (§14): is a voice note a message in another medium, or a core vocabulary addition?
- **`derived-exo-526`'s oracle.** S3 added `voice_status` to its host probe: the method listed
  as `QString`, `ready.codec` the libopus linked, both devices `"unknown"`. The spec's
  acceptance criterion still names only `health()`, `propose()` and `status()`, so a voice
  regression now turns exo-526 red. Sign off on the wider oracle, or a voice spec's own probe
  takes these checks over once the epic has an exo id.
- **The Linux-only checks** (§15): who runs them? This PR is built on a Mac.
- **Scope.** This PR regenerates the stale gallery `FakeBackend.qml`, which also pulls in
  FileShare's missing slots, and fixes the unknown-card fallback. The Nim backend's missing
  FileShare autopilot and FileShare's absence from `ui-parity.sh` are left for a separate PR.

Still open:
- **for the operator: `coordinate_proof` and the audio** (§10). A log proof carries every
  event's value whole, so a proof of a room with a note carries its Opus to the caller. Either
  the proof export is named as an exception to "audio plaintext never crosses IPC", or a new
  proof form carries voice parts as committed digests. S7 needs the answer;
- whether to coarsen `voice_status`'s peak for co-resident callers (§13);
- the exact disclosure wording on the draft surface (§8);
- whether the gaps of §10 become new registry entries.
