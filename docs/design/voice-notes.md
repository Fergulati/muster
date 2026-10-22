# Voice notes: a short recorded clip in the room, sealed like text, one fixed size on the wire

Status: **proposed 2026-10-21 by an outside contributor; slices S1–S10 are built on this
branch. Of S11, the real-device test is built and has run in part (§17). S9's end-to-end
self-test has not run yet (§15).** This document is
the first commit of a draft PR, so the maintainer can object to the wire format (§3–§5) before any code depends on it. There is no exo id yet
(§18): the slices are S0–S11 in the order of §17, and the commit scope is `voice-notes` until
an id is assigned. A code path named below as new is **planned** unless its slice is built.
Every file:line reference is to `main` at `67701f8`, except one marked "on this branch".

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

**Built (S4).** `publish(ev, padTo = 0)`. With `padTo > 0`, the event's JSON is followed by
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

**Which copy the held path seals** (built, on this branch). On `main`, the held path re-seals the
copy the log keeps: of the copies of one id, the one with the smallest `afterDigest` (`log.nim`
`keep`). Ingest takes a copy with an `after` of any length, unsigned, from any member, so a
member who received a part could plant a copy whose `after` alone overflows the pad and that
sorts first; every later held-path send of that part would then raise `FrameTooLarge`, and a
retried Send would fail for good. So `publishAuthored` passes `publish` the copy to seal
(`asGiven`): for an event the log already holds, the copy whose `after` this member signed,
the smallest by `afterDigest` if there are several, as the room's view picks; with none, the
event with no ordering claim, which is what the room's view makes of any copy whose `after`
its author did not sign (`authorship.copyToSeal`). That copy's `after` came from `heads()`, at
most 8 ids, so it fits the pad (§5). `voice_live_test` §24 plants such a copy with 1,400 ids
and retries.

Why on the frame, not inside the value:
- `publishAuthored` signs the value first. Only then does it set `after = heads()` (0 to 8 ids,
  `log.nim:226`) and sign `afterSig` (`authorship.nim:279-287`).
- A pad inside the value would be fixed before those bytes exist, so it could not account for
  them.
- The pad sits outside `value`, so the event id does not change: the id hashes parents, key
  and the value's text, never the frame.

Older clients read it unchanged. `decodeEvent` is `parseJson(toStr(b))` (`session.nim:82-83`).
At the builder's Nim pin (2.2.4), the parser accepts trailing whitespace (5,000 spaces were
tried, while planning) and trailing `//` or `/* */` comments, takes a NUL as the end of its
input (accepting anything after one), and refuses other trailing text, such as a letter or a
`}`. The pad is ASCII spaces, so only the first of those matters here. Nothing pads with NULs,
and `session_pad_test` fails a NUL pad (`docs/labbook/voice-notes-audio-stack.md` §8). So:
- no new frame kind;
- no `room_journal` change: journal frames are opaque, with `MaxFrame` 16 MiB
  (`room_journal.nim:24`);
- a peer on a Muster from before voice notes (0.3.2 or earlier) reads a padded frame as an
  ordinary event, and its thread ignores the `voice/` key (§7).

**What does not fit, raises.** An event whose JSON exceeds `padTo` raises `FrameTooLarge`
before anything is ingested, journalled or sent. Send seals both parts before either frame
leaves (§10), so a part that does not fit is refused before any frame of its note is sent; for
a draft under the cap neither can (§5). Today nothing guards size: an oversized frame
lands in the sender's own log and reaches nobody, and a failed send is logged only under
`MUSTER_LP_DEBUG` (`transport/delivery.nim:118-123`).

## 5. Size budget

The record's figures are arithmetic, and S1 holds them: `maxClipBytes` gives 126,119 B at
60 s and 1,166 B at 500 ms (`voice_clip_test`), and a real 60 s encode stays within it
(`voice_codec_test` §5). The JSON around a half is measured: `session_pad_test` puts the
worst case below, a 63,060 B half with 8 heads, at 85,257 B, 4,855 B under the pad, and
`probe_voice_fixed_size_stepper` sends 60 s notes with 8 heads in 90,153 B frames. Both run
over `LocalTransport`, not the fleet (§15). A 60 s note is 2,880,000 samples. The encoder is
flushed through its 312-sample lookahead, so by §3.2's count it is
ceil((2,880,000 + 312) / 960) = 3,001 packets.

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

`reduceVoice(roomEvents(s))` (built, S5: `coordination/voice.nim`) is pure and order-free, and
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
- the hosted layer keeps one per room (S7, built: `VoiceRecorder.memoFor`), so a clip is not
  decoded and checked on every read;
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
room, all on the module thread, so a few such rooms still cost tens of ms a second.

S7 measured the hosted reads the same way (20 notes of 60 s, a member's session over
`LocalTransport`, `-d:release`, darwin-arm64, outside the repo), per call:
- `roomEvents`, the authentic view: about 37 ms the first time, while it checks and caches
  every part's signature, then about 3 ms;
- the thread's rows as `coordinate_messages` reads them (`roomEvents`, then `threadRows` with
  the room's memo): about 48 ms with a cold memo, then about 16 ms;
- `threadLastTs(roomEvents)`, the `lastTs` of `coordinate_conversations`: about 16 ms;
- `threadRows` with no memo: about 48 ms on every call, which the memo saves.

## 7. Thread rows

The thread is `coordinate_messages`, which returns every message body on each 1 s poll
(`muster_module.nim:4582-4594`). Audio must never ride that. So a note is never a `message/`
event, and there is no pointer message as `intent-ref` uses.

Instead, `threadRows(events)` (built, S5) merges `reduceMessages(events)` with one synthesized
row per note, ordered by (ts, id). The row carries the note in a field of its own, `voice`,
never in `body`. That field is metadata only, under 300 B:

```
{ "id": "<nid>", "author": "<reduceVoice's author>", "ts": N, "body": "",
  "voice": { "v": 1, "note": "<nid>", "durationMs": N, "state": "complete|arriving|broken" } }
```

The hosted layer adds `alias` and `self` to it, as to every row (`voice_live.messagesJson`
on this branch, which `musterCoordinateMessages` calls; `voice_live_test` §22 pins both row
shapes).

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
  forger's raw JSON, under the forger's name, with no voice card and no Play for the note it
  names (the gallery fixture `room-voice-forged` checks each).
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
- **A peer from before voice notes** (0.3.2 or earlier) shows nothing for a note in its
  thread: it never synthesizes the row, and `reduceMessages` skips the `voice/` events. That
  is better than its unknown-card render: an
  unknown kind draws nothing, or a stray heading, never a text fallback
  (`RoomThread.qml:693, :722`). Its information-flow view and room map do show each part, as
  an unknown `voice` entry: envelope rows only (`flow.nim:121-124` on `main`), and an entry
  node of kind `voice` with basis `sealed` (`room_graph.nim:299-331` on `main`). That entry's
  `content` is the whole value, `part` included (`room_graph.nim:198`, `:348` on `main`), so
  that peer's `coordinate_graph` returns the audio, as its `coordinate_proof` does: §10 lists
  it among what still leaks.
- **Older clients in general.** S8 fixes that fallback for the next unknown kind (built: a
  body whose kind MusterCard does not know is the message's text, RoomThread's `isText`), but
  clients already released keep it.
- **A UI from before S8.** `coordinate_messages` returns a note's row, with an empty `body`.
  RoomThread before S8 parses the body as a card in a `try`, gets null from `""`, and falls
  through to plain chat text (`RoomThread.qml:75-79` on `main`), and the Nim UI passes the
  same JSON through (`ui-nim/app/backend.nim:129` on `main`). So such a UI, paired with this
  module, draws a voice note as an empty chat line under its author's name (§15). S8's
  RoomThread draws the row's `voice` field as a `CardVoiceNote` instead (built).

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

**The methods** (built: in `muster.lidl` since S3 and S7). Each one returns at once. Parameter
names avoid C++ keywords (`7480de8` renamed `private` for that reason), and every method
declares a return type.

| Method | Returns |
|---|---|
| `voice_status()` | the JSON below; it also drives the voice pump |
| `voice_record_start()` | `{ok}`, or `{error}`: `not-joined` · `busy` (recording, playing, or a draft held) · `codec` · `no-device`, or another word the device seam gives (`FileAudioIo`'s `no-source`, …), which `ready.capture` then says |
| `voice_record_stop()` | `{draft: {durationMs, silent, peak}}` (a draft the 60 s cap already made included), or `{error}`: `not-recording`, or why the encoder refused |
| `voice_draft_send()` | `{note}`, or `{error}`: `no-draft` · `too-short` · `silent` (with `detail`, the platform note of §11) · `not-joined` · `room-changed` (the joined room is not the one the draft was recorded in) · `too-large`. The draft is kept on every refusal |
| `voice_draft_discard()` | `"ok"`; it also drops a recording in progress |
| `voice_play(note_id)` | `"draft"` or a note id; `{ok}`, or `{error}`: `unknown-note` · `incomplete` · `broken` (the fold's verdict, or a clip libopus refuses) · `busy` · `no-draft` · `not-joined` (a note with no room) · `codec`, or the device seam's word, which `ready.playback` then says |
| `voice_play_stop()` | `"ok"` |

`voice_status` returns integers, strings, booleans and null, never a float, and never audio:

```
{ ready:     { capture: "unknown|ok|no-device|…", playback: "…", codec: "<opus_get_version_string()>",
               note: "<a platform note, e.g. §11's, or empty>" },
  recording: { state: "idle|recording|draft", elapsedMs, capMs: 60000, peak, capped, silent, error },
  playing:   { note, positionMs, durationMs } | null }
```

**Refusals at Send**, in this order:
- **Too short.** Under 500 ms is refused as `too-short`. That includes a recording of no
  samples at all (Start, then Stop at once), which is too short, not silent, and raises no
  microphone note (`voice_live_test` §16).
- **Silent.** A draft long enough to send whose samples are all exactly zero is refused as
  `silent`, and the platform note says why (§11): it is the refusal's `detail`, and
  `ready.note` once such a recording came back. A low but non-zero peak is only a warning.
- **Another room.** A draft belongs to the room it was recorded in: `voice_record_start`
  takes the room's topic, and a Send while another room is joined is refused as
  `room-changed`, with nothing published to either room (`voice_live_test` §18). So a draft
  is never posted to a room other than the one its draft surface named, and a retry never
  sends a note's second part to another room than its first. `voice_status` does not say
  which room holds the draft yet, so S8's draft surface shows a draft in whichever room is
  open and says whose it is only when Send is refused (§18).
- **A retried Send sends the same note, where the failure is seen.** The note's ts is fixed at
  the draft's first Send. Send signs both parts and puts each into the log and the journal
  before either frame reaches the transport (`session.publishTogether`, §10), so after a
  transport raised between the two frames, the log holds both, and a retry re-sends both on
  the held path (§4), under the same note id, each as this member first sealed it, so a copy
  another member planted cannot block it (`voice_live_test` §15 makes the transport raise
  through a `LocalTransport` subscriber, §24 adds such a copy). Until the retry, the sender's
  own thread shows the note complete while the room may hold only its first part.
  `too-large` is refused before any frame leaves, and cannot happen for a draft under the
  cap (§4, §5).
- **The live transport raises nothing.** `DeliveryTransport.publish` is fire-and-forget: it
  hands the frame to `lp_invoke_async` and returns, and a failed send is logged only under
  `MUSTER_LP_DEBUG` (`delivery.nim:118-123`, `:202-212`). So if either 90 KB frame fails on
  the fleet, Send still returns `{note}` and drops the draft, and every other member can hold
  the note `arriving` for good: nothing re-sends it (`coordinate_reannounce` re-publishes
  intents only). §15 and §18 carry it.

**Built (S7).** `coordination/voice_live.nim`'s `VoiceRecorder` runs the state machine above
for the seven methods. Start, Stop, Send and Play each run the voice pump first, so each
decides on what the device side has done by now: a playback heard to its end is not `busy`,
and a recording the cap ended is a draft Send can send, whether or not anything read
`voice_status` since (`voice_live_test` §17). `voice_status`'s `peak` is the largest |sample| captured since the
last read, and reading it resets it, raw (its coarsening is still open, §13). `elapsedMs` is
what the device side has captured, at 48 samples a millisecond.

**Polling only.** The `.rep` declares no SIGNAL, the module has no clock
(`docs/design/side-modules.md:66`), and the SDK's `emit` callback is a threadvar, so the audio
thread cannot emit. So:
- `voice_status` drives `voicePump`, as `fileshare_files` drives `fileSharePump`
  (`muster_module.nim:2778`);
- `coordinate_intents` also calls it, from its pump list (`:2854-2861`);
- the UI polls `voice_status` every 250 ms while not idle: a note recording, a draft held (for
  as long as it is held), or a note playing;
- the room's 1 s timer reads it too, so a recording any caller started shows a banner (§13).

Elapsed time on screen comes from a QML clock. The module's cap is the one that counts.

**A refusal shows while it holds.** The UI keeps the last voice call's answer with the room the
call was made in and where `voice_status` stood then (the recording's state, the note playing).
Once another room opens, or `voice_status` moves on (the other recording ended, the note
stopped playing), the answer is no longer shown; a refusal such as `busy` or `room-changed`
describes a state that has gone. The gallery fixture `room-voice-refused` holds both.

## 9. Devices, threads and the build

**The `AudioIo` seam** (built, S2: `module/src/audio/audio_io.nim`). It is built in the shape of
`Transport` and `BlobStore`, and no test mocks it (CLAUDE.md working agreements). Its
implementations:
- `SyntheticAudioIo`: deterministic PCM on a virtual clock, with a collecting sink. It is the
  in-process stand-in, as `LocalBlobStore` is.
- `FileAudioIo`: a 48 kHz mono s16 WAV source (`MUSTER_VOICE_SOURCE`) and a raw PCM sink
  (`MUSTER_VOICE_SINK`), for the offscreen self-test (S9).
- `MiniaudioIo(system | null)`: miniaudio's null backend runs the real device-thread path with
  no device and no permission prompt. The real-device test, `voice_device_e2e` (S11, built),
  sits behind `MUSTER_VOICE_REAL`, in run-suite's E2E list.

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
sources). The module has no unload hook: the generated surface exports none (`muster_gen.nim`:
seven `logos_module_*` entry points and a constructor). So S7 does two things (built):
- **Every stream releases its device when it ends.** At Stop, at the cap, when the pump sees
  `done`, at `voice_play_stop` and at Discard, the recorder stops the stream and closes the
  `AudioIo`: for `MiniaudioIo` that uninitialises the device and the context, so between
  streams nothing is open (`voice_live_test` §13 reads the null device's context back as
  gone; §19 holds Send and Discard while the draft plays, §20 a sink that refuses a write,
  §21 a start the device refuses and `close`). `MiniaudioIo` makes a new context at the next
  start.
- **An exit proc closes what still runs.** `muster_module` registers one (`std/exitprocs`)
  when it makes the recorder, and it calls `VoiceRecorder.close`. It runs at process exit,
  and when the plugin's image is unloaded, since `atexit` ties a handler to the image that
  registered it (Apple's libc by `dladdr`, glibc by the DSO handle). That window, a recording
  or a playback in progress when the host unloads the plugin, is not tested (§15).

**The build** (built, S1–S3; the traps found on the way are in
`docs/labbook/voice-notes-audio-stack.md`):
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
| a module loaded beside Muster (access policy off) | the voice state and peak level; it can start a recording, send or discard the draft, play the draft or a note aloud (§13) | the audio, through any method: no voice method returns it, S6 closed `coordinate_graph`, and `coordinate_proof` refuses a room holding a voice note (below) |
| a module loaded beside another member's Muster from before voice notes (0.3.2 or earlier) (access policy off) | every note's clip, through that member's `coordinate_graph` and `coordinate_proof`, which return each part's value whole (§7; "What still leaks", item 6) | nothing of a note sealed in an epoch that member never held |

**Two methods that returned raw log content.** No voice method returns audio. But a part's
value holds its half of the clip as base64 Opus, and two existing methods handed event values
to any caller:
- **`coordinate_graph`**, the room map, copied every field of a JSON-object value into the
  entry's `content` (`room_graph.nim:198` on `main`), and did so for every entry (`:348` on
  `main`), so a voice part's `part` went with it until S6.
- **`coordinate_proof`** returns every raw log event, value and all (`proof.nim:79`,
  `muster_module.nim:3230`). A proof must carry each value whole: the verifier recomputes
  every event's id from it, and the id hashes the value's text itself (`muster.event.v1`,
  `log.nim:48-58`). So the field cannot simply be left out.

Left as they were, both methods gave any caller the Opus of every note in the room. That
contradicts the decision that audio plaintext never crosses IPC (§18), and §13. The two cases
differ:
- **`coordinate_graph`: S6 strips it.** An entry under `voice/` has as `content` its value's
  `v`, `ts` and `durMs` where each is an integer and its `digest` where that is 64 lowercase
  hex, and nothing else: no `part`, whatever a part holds (`voiceContentOf`,
  `room_graph.nim:208-229` on this branch). `voice_test` §14 pins that field by field, and
  finds no 48-character stretch of any half, taken at every 24-character step and at its end,
  in the map `toJson` gives.
- **`coordinate_proof`: refused until the operator decides** (§18). A room whose raw log
  holds any `voice/` entry, by the key's first segment as the session pads one, and an
  unsigned or malformed one too, exports no proof: `{error: "voice-notes-present", detail}`
  (`voice_live.roomProof`, `voice_live_test` §23). A room with none exports its proof as
  before. That keeps the fixed decision that no hosted method returns audio, at the cost of
  no proof export for a room with a voice note. The operator then picks one of two. One
  option keeps raw values, since a proof accounts for every entry, and says here that a proof
  export carries the audio. That amends the IPC decision for this one explicit export. The
  other is a proof form that carries a voice part as a committed digest. Because today's id
  hashes the value itself, that means a new proof format, and perhaps a new id derivation,
  not a filter on today's.
- **Neither on an older client.** A member on a Muster from before voice notes (0.3.2 or
  earlier) holds the same parts and returns them whole through both methods; nothing in this
  PR reaches their code ("What still leaks", item 6).

**What the code adds** (built, S6). Every one of them takes a part to be what the fold
stands: `voiceStanding` (`voice.nim:246` on this branch), the header pass's standing parts of
the notes it keeps (§6 rules 2 to 4), by event id: exactly the ids `reduceVoice`'s notes name
in `parts`, whatever each note's state. So the flow, provenance and the room map agree with
the fold on what is a part, and an entry under `voice/` that is none, by its key, its value,
an equivocating later copy or a squatted note id, is no part in any of them.
- **A `voice/` branch in `flow.nim`** (`:123-135` on this branch). On `main` an unknown
  prefix falls through to envelope-only rows (`flow.nim:121-124`), which would show the room
  nothing about its own content. With the branch, each part shows:
  - room-member: `voice-note`, `voice-note-length`;
  - store-node: `timing`, `topic`, `fixed-size`.

  An entry under `voice/` that is no note's part shows the store node's three rows alone: the
  sending client's `session.publish` pads every `voice/` frame (§4), whatever its shape.
  Ingest does not check the size of a frame another member sent, so `fixed-size` on another
  member's entry is what an honest client sends. Pinned by `voice_test` §13.
- **The room map.** An entry of kind `voice`, its basis author-signed and its account the
  member its key names (`AuthorSigned`, `room_graph.nim:69`, `:76-77` on this branch). It is
  counted exactly when provenance lists it, so exactly when the fold stands it. An entry under
  `voice/` that is no note's part is still its signer's, since authorship proved who signed
  it, but uncounted (`room_graph.nim:383-388` on this branch), and its facet says so: "the
  fold counts it for nothing; its author signed it, bound to this room". The map's `file/`
  entries, account disclosures and ceremony joins, which provenance never lists and the map
  has always named by their signer, now say the same. The store node's facet
  names the one fixed size, which marks a voice note but not its length
  (`room_graph.nim:110-114` on this branch). Its `content` carries no `part` (above). Pinned
  by `voice_test` §14, the `file/` facet by `swarm_test` §8.
- **Provenance.** A `logProvenance` item (`intents.nim:829`, `:830` on this branch) for each
  standing part, as a peer message in its author's name at the epoch whose key opened it
  (`intents.nim:871-885` on this branch), and none for an entry that is no note's part.
  Pinned by `voice_test` §15.

`voice_test` pins those rows field for field, the way `swarm_test` §8 pins FileShare's.

**The claim** (built, S10: `contracts/claims/registry.json`, step `open-room`, under FS-9 and
worded narrowly; credibility imperative):

> **A voice note's length does not show in its size.** Muster sends each voice note as two
> parts, each one frame of one fixed size whatever the note's length, and a re-send is the same
> size. Each frame is sealed with the room's current key, as text is. So a store node can tell
> that a voice note was sent, to which room's topic and when, but not how long it is. It still
> sees the conversation graph (the gap above).

The claim is worded per frame, not per note: what stays fixed is each frame's size, not how
many frames a note takes, since a retried Send publishes both parts again. Its words keep to
the walkthrough's plain language (`scripts/ui-lint.sh`: no spec id or module name on screen,
and no developer term past `ui/tests/qmllint-baseline.json`), so the claim and the four gaps
below say "the room's key" for the epoch key and "access checks" for Basecamp's access
policy, and name no spec id.

Its test is `module/tests/probes/probe_voice_fixed_size_stepper.nim` (S5), which covers
durations from 0.5 s to 60 s, 0, 1 or 8 heads, and two epochs. It also publishes the same note
twice, so the second pair goes out on the held path (§4), and asserts that the topic carried
exactly four frames for the note, each 90,153 B. It sits beside the existing gap
*The store node still sees the conversation graph* (`contracts/claims/registry.json:83`) and
does not soften it.

**What still leaks.** The design note listed the first five, and the S6 review found the
sixth. Each stays true after this PR:
1. **A voice is a biometric, against FS-7.** FS-7 scopes a member's identity to the room. A
   voice undoes that for everyone who hears it:
   - a listener in two rooms can tell that the same person speaks in both;
   - a voice can tie a member to a real person;
   - nothing stops a listener re-recording playback.

   The draft surface says so before Send (§8).
2. **Size and timing are visible.** The store node sees the two frames at the moment of Send.
   Their size marks them as a voice note: chat frames are far smaller, and the largest
   events the tree sends today, Monero multisig blob parts, are of the same scale. Only the
   length is hidden. That takes the time between the two frames too: sent one part at a
   time, the second frame waited on its own signing, hashing and encoding, about 20 to 30 µs
   more per second of audio (0.36 ms for a 0.5 s note, 2.1 ms for 60 s, measured on
   darwin-arm64 outside the repo), and each Waku message carries its publisher's nanosecond
   timestamp, which the store keeps (`store_catchup.nim:149` on `main`). So Send signs,
   records and seals both parts first and then hands both frames to the transport back to
   back (`session.publishTogether`), with nothing between them whose cost depends on the
   note (`voice_live_test` §25; the same measurement then shows under 1 µs between the two
   calls at every length). What the delivery node adds between two sends of the same size
   on its side of the IPC hop is not measured (§15). Like text, the store keeps the
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
6. **An older client in the room returns the audio over IPC.** A member on a Muster from
   before voice notes (0.3.2 or earlier: every release so far, the published `muster-v0.3.0`
   and `muster-v0.3.2` among them; §18 asks that the release with voice notes be numbered so
   the line stays clear) opens every voice frame sealed in an epoch they hold, and serves
   each part's value whole, the base64 Opus included, to any
   module loaded beside it with the access policy off. Nothing in this PR reaches their code:
   - its session reads a padded frame unchanged: the pad is ASCII spaces after the JSON,
     which `decodeEvent`'s `parseJson` skips (`session.nim:82-90` on `main`);
   - its `authenticEventsWith` passes every event that `authorOf` does not mark authored
     (`authorship.nim:238-240` on `main`), and its `authorOf` has no `voice/` branch, so its
     room view keeps every part, a forged one too;
   - its room map copies every field of a value into `content` (`room_graph.nim:198`, `:348`
     on `main`), so its `coordinate_graph` returns `part`, and its `coordinate_proof` returns
     every raw value.

   So in a room with such a member, "audio plaintext never crosses IPC" (§18) holds on the
   machines of members who run this PR, not on theirs. Only that member's upgrading, or
   `--access-policy enforce` on their machine (§13), closes it. It is put to the operator in
   §18.

S10 carries four of these as gaps of their own in the registry (built, step `open-room`, each
`exposed`), unless the maintainer prefers them folded into existing entries. Item 2 is the
existing gap the claim names, and item 5 makes no claim:
- "A voice can identify the speaker" (status `none`: masking a voice would mean altering the
  audio, which voice notes never do; the party is everyone who plays the note);
- "Modules loaded beside Muster can record and send as you" (`partial`: `--access-policy
  enforce` with `infra/access-policy.json` ships in the host, off by default, and voice has
  not run under it; the party is the co-resident modules);
- "Leaving a room re-keys nothing" (`partial`: the key layer rotates on removal,
  `EpochCrypto.removeMember` (`epoch_crypto.nim:135`, exercised by
  `epoch_crypto_test.nim:61`), and no room path calls it; the party is a former member). It
  is a room-wide gap that no entry named before, and it leaves the F-16 protects claim at the
  top of the same step half true (§18);
- "A Muster from before voice notes hands them to the modules beside it" (`partial`: a
  member who runs a Muster with voice notes serves no audio, and nothing here reaches an
  older member's code; the line is drawn by the feature, with "0.3.2 or earlier" as today's
  releases; the party is the modules loaded beside an older member's Muster, on that
  member's machine).

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

**Outside Basecamp.** An unbundled, nix-built binary is charged to the app macOS holds
responsible for it: the terminal app, or the app that started the shell (S11's run, §17,
names the one it was there). macOS asks the person to grant that app the microphone, and
Core Audio holds the device's start while it asks: in S11 the start had not returned after
20 s, with the prompt unanswered. That the start returns once the person answers is inferred,
since nobody answered. S11's opt-in microphone test runs only with that consent.

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
  envelope of a recording in progress (S7 reports no level for a playback). S7 serves it
  raw; whether to coarsen it (one value per 100 ms, a few levels) is still open (§18).

What it cannot do is read audio through a voice method: none returns it, and `voice_status`
carries state, position and peak only. That is unlike `coordinate_messages`, which serves
room plaintext to any caller (`side-modules.md:104`). Two methods that returned raw log
content, `coordinate_graph` and `coordinate_proof`, would have handed it the clip. S6 closed
the first. The second refuses a room holding a voice note until the operator decides between
an exception and a new proof form (§10, §18). On the machine of a member
who runs a Muster from before voice notes (0.3.2 or earlier), both still return it, and
nothing here reaches that code (§10, "What still leaks", item 6).

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

S1–S10 are built (§17). Of S11, the real-device test is built: its speaker leg passed on this
Mac, and its microphone leg stopped at a permission prompt nobody answered (§17 S11). What is
unverified, built or planned:
- **The audio facts came from a throwaway prototype on an Apple M5.** These are packet sizes,
  the varargs hazard, the null backend, encode and decode cost, and miniaudio compiled through
  `{.compile.}`. None of them has run through the real `logos-module-builder` derivation, and
  none has run on Linux.
- **Microphone capture under Basecamp's hardened runtime.** Neither outcome of §11 is
  observed: zero-filled buffers, or TCC terminating `logos_host`. S11 checks this first. Real
  capture anywhere without the person's grant is unobserved too, and so is real capture with
  it: `voice_device_e2e`'s microphone leg got no frame, because the prompt went unanswered
  (§17 S11).
- **A first `voice_record_start` can hold the module thread on a Mac.** Outside Basecamp, for
  an app with a microphone usage string whose permission is not yet decided, Core Audio held
  the capture device's start while macOS asked (S11: still not returned after 20 s). The
  module starts a device on its own thread (§9), so there every other module call would wait
  for the person's answer too (inferred, not run in a host). No timeout guards the start.
  Whether `logos_host` under Basecamp, with no usage string, is asked at all is §11's check.
- **Linux dlopen** of `libpulse` and `libasound`, from a portable `.lgx`, the AppImage and a
  nix-built runner; and PipeWire.
- **Delivery of two 90,153 B frames:**
  - over the live fleet;
  - with RLN on `logos.test`, where each note spends two sends;
  - under `mix = preferred | required`.

  And a failed delivery is not seen. `DeliveryTransport.publish` is fire-and-forget (§8), so
  if either frame fails on the fleet, `voice_draft_send` returns `{note}` and drops the
  draft, and the note can stay `arriving` for every other member: no path re-sends it
  (§18). The retry of §8 covers only a transport that raises, and
  `voice_live_test` §15 raises through a `LocalTransport` subscriber, a failure the hosted
  module never sees.
- **A half-sent note looks whole to its sender.** `session.publish` logs a part before the
  transport sees it, so after a Send that fails between its parts the sender's own thread
  shows the note complete while the room may hold only its first part (`voice_live_test`
  §15 pins both views). A retry closes it; Discard instead makes the split permanent. S8's
  draft surface answers `too-large` by asking for Send again, which sends the same note; it
  does not warn that the room may hold half of it, nor hide Discard then.
- **A UI from before S8 draws a note as an empty line** (§7). `coordinate_messages` returns a
  note's row with an empty `body`, which the RoomThread on `main` draws as an empty chat line
  under the author's name, as any older UI paired with this module would. S8 (built) draws it
  as a card; S8 and S7 should land in one push.
- **S8 is seen only through the gallery, on a Mac, with no module.** The S8 fixtures
  (`room-voice-forged`, `-notes`, `-record`, `-refused`, `-flow`, and `room-map-voice`) pass
  against the real `Main.qml` and the generated `FakeBackend.qml`, offscreen with Qt 6.9.2's
  software renderer (icons draw blank there) and both design systems, Basecamp 0.3.2's and
  the runner's; their voice rows, `voiceJson`, `voiceResultJson`, `flowJson` and the room
  map's voice entries are typed from the shapes the module's code and tests give, not
  recorded: no runner has recorded them, since S9's self-test has not run (below). No click
  has reached a real `muster_module`: the C++ backend compiles into the `.lgx`, and the Nim backend is
  type-checked only against stubs made from the `.rep` and `muster.lidl` (ui-nim builds on
  Linux only), its voice autopilot run against a fake module (S9, below). Neither UI has drawn a voice note from a real room, on a display or offscreen.
- **The cost of store catch-up.** It returns each payload as a JSON byte array
  (`delivery.nim:309-315`), so a voice frame inside the 60 s lookback is re-fetched as several
  hundred KB of JSON per query. That should be measured before anything is added; a seen-frame
  short-circuit only if it matters.
- **The cost of the fold.** `eventId`'s memo key concatenates the whole value (`log.nim:71-75`),
  and every hosted read re-runs `roomEvents` with no fold cache (the cache is
  `side-modules.md` S4, `exo-ff5.4`, not built). `voice.nim`'s own cost is measured (§6), but
  `roomEvents`' authorship checks over 84 KB values are not, and nor is the whole hosted read.
- **Audio over `coordinate_proof`** (§10). It refuses `voice-notes-present` for a room whose
  raw log holds any `voice/` entry, so no proof of such a room leaves the module until the
  operator decides; `voice_live_test` §23 holds the refusal on `roomProof`, which the hosted
  method calls after its `not-joined` check and a poll. S6 stripped the audio from the room
  map: an entry's content is `v`, `ts`, `durMs` and `digest` at most, and `voice_test` §14
  finds no 48-character stretch of any half, taken at every 24-character step and at its end,
  in the map `toJson` gives. So a leaked stretch of 71 characters or more is caught wherever
  it sits in a half; a shorter one, or the clip in another encoding than its base64, is not
  looked for.
- **Audio over an older client's IPC** (§10, "What still leaks", item 6). A member on a
  Muster from before voice notes (0.3.2 or earlier) returns every part whole through their
  `coordinate_graph` and `coordinate_proof`, to any module loaded beside them. This PR cannot
  change that code, and no test here runs such a client against a voice note: what it does
  is read from `main`'s source.
- **The size budget** (§5) is measured in process only. The record's size is S1's arithmetic,
  and the worst case's JSON and frames are measured over `LocalTransport` (S4, S5). No
  90,153 B frame has crossed the fleet (above).
- **The voice methods through a host** (S7). `voice_live_test` runs `VoiceRecorder` in
  process, on `SyntheticAudioIo`, `FileAudioIo` and miniaudio's null device, with two members
  over `LocalTransport`, and holds the rows `coordinate_messages` serves (`messagesJson`, §22)
  and `coordinate_proof`'s refusal (`roomProof`, §23), the two procs those hosted methods
  call. The marshalling probe compiles the hosted glue in `muster_module.nim` and calls the
  six methods through the generated dispatch with no room joined, each reply checked to the
  byte (`not-joined`, `not-recording`, `no-draft`, `ok`), and `coordinate_messages` and
  `coordinate_proof` beside them; no device opens. With a room joined, the glue's remaining
  lines (the `not-joined` check, a poll, the session and keystore it passes) are not run
  through a host by any test: no harness here joins a room. It was driven once by hand,
  headless, in logosctl 0.3.2's `logos_host`
  on darwin-arm64 (2026-10-21, the S7 `.lgx`, a throwaway room joined on `logos.dev`): with
  `MUSTER_VOICE_SOURCE` a 3 s 1 kHz WAV and `MUSTER_VOICE_SINK` a scratch file,
  `voice_record_start` refused `not-joined` before the join and gave `{ok}` after it, Stop
  made a draft (8,700 ms: the WAV's 3 s, then the silence `FileAudioIo` hears after it),
  `voice_play("draft")` wrote 8,700 ms to the sink with the source's 1 kHz power in its
  first 3 s, and Discard, `busy`, `no-draft`, `unknown-note` and `not-recording` answered as
  §8 says; on `MUSTER_VOICE_BACKEND=null` the null device's zeros were refused at Send as
  `silent` with the macOS note as `detail`, and nothing was posted. No note was sent from a
  host: two members, the live fleet and the thread's voice rows through `coordinate_messages`
  are what S9's self-test drives, and it has not run (below).
- **S9's self-test has not run.** `scripts/voice-self-test.sh` (§17) needs the standalone
  runner, and the runner does not build on this Mac. `BUILD_MEM= make build` on 2026-10-22
  (macOS 26.5, Apple Silicon, Command Line Tools and no Xcode; 1 h 28 min from cold) stopped
  in lez_core 0.5.0's Rust dependencies, `logos-execution-zone-wallet-ffi-deps-0.1.0`:
  `risc0-sys` 1.5.0's build script runs `xcrun --sdk macosx metal`, the Command Line Tools
  carry no Metal compiler (`xcrun: error: unable to find utility "metal"`), and
  `risc0-build-kernel` 2.0.1 panics "Could not build metal kernels". `libmuster_module`, the
  `muster_ui` plugin and `logos-standalone-app` had built by then. So no note has crossed two
  runners on either UI, on `MUSTER_FLEET=local` or a fleet, and the `voice` entry of
  `ui-parity.sh` has not run. What did run, on darwin:
  - the Nim autopilot, in `ui-nim/tests/autovoice/run.sh`, which compiles
    `ui-nim/app/backend.nim` whole against stubs made from the `.rep` and `muster.lidl` and
    a fake module with §8's state machine, and runs its timers in real time, with nim 2.2.12
    from ui-nim's own nixpkgs pin. It was a scratch harness in S9 and is committed since
    S9's review. On `9cc1005`'s backend: no voice call and no `VOICE` line. With S9's: Start,
    Stop a second later and Send, once each; Play for each complete note from another
    member, one at a time, once each, and never for an arriving note, one's own, or a
    message whose body claims a note; a refused Play tried five times, no more. Six mutants
    are each caught: no self check, no played set, no complete check, Play while one plays,
    no limit on tries, and Stop not waiting `VOICE_SECS`;
  - the self-test's audio check, on the tone round-tripped through the shipping libopus
    1.5.2 at §3.1's settings (from 0.25 s to 2.75 s: 1 kHz power 66.6 M of the source's
    67.1 M, at most 2.6 at 500 Hz, 1.5 kHz and 3.1 kHz) and on sinks made to fail it
    (silence, one millisecond short, a 1.5 kHz tone, a quarter of the amplitude, a 3.1 kHz
    tone added, a row arriving or of another length);
  - `scripts/lib/ui-build.sh`'s launch and cleanup with a stand-in runner: macOS has no
    `setsid`, and its `ps` has no session id, so before S9 a self-test launched nothing
    there and could leave a runner's children running;
  - the script itself, under macOS's bash 3.2, against a stand-in runner (not committed)
    that writes the autopilot's log lines for its role and that round-tripped tone as B's
    sink: SUCCESS, and FAIL for a sink one millisecond short, a quarter of the amplitude, a
    send delivery refused, C's note not refused, and A never sending; no process was left.
    S9's review found four holes there, each now closed and each shown red on S9's script
    and green on the fixed one, against the same stand-in: a refused frame whose result
    came back before the UI logged the Send, and no send result at all, passed (the count
    now starts at A's Stop and wants two accepted); C's Stop calling its draft not silent,
    C's thread holding a note of its own, and, on macOS, C's refusal with no `detail`,
    passed; and a `VOICE_SECS` of 2 failed whatever B heard, the filter's window being
    fixed at 0.25 s to 2.25 s (it now ends 0.25 s before the note or the WAV does: 1 and 2
    pass, and 0 or 2.5 is refused before anything launches).

  The C++ autopilot compiles into the `.lgx` and has not run.

  **What the maintainer runs on Linux before S9 counts as done** (the PR stays a draft, and
  this entry stays, until the transcripts exist): `make build && scripts/voice-self-test.sh`;
  the same with `MUSTER_FLEET=local`; `make build-nim` and `MUSTER_UI=nim
  scripts/voice-self-test.sh`; `scripts/ui-parity.sh voice` for each UI; and one red run,
  the script against a runner built from `9cc1005` (no autopilot), which must FAIL with
  "B never played A's note (sent: none".
- **The voice gallery fixtures break the gallery's own rule.** `ui/tests/gallery/CLAUDE.md`
  says fixture data is recorded, never hand-typed. S8's voice fixtures (`room-voice-notes`,
  `-record`, `-refused`, `-flow`, `-forged`, and `room-map-voice`) are typed from the
  module's shapes (above), and S9's recorded ones, the card complete, playing, arriving and
  broken and the message row recording and holding a draft, are not made:
  `scripts/ui-screenshot.sh record scripts/voice-self-test.sh` needs a runner, Xvfb and Qt's
  xcb platform, none of which this Mac has. On Linux that recording's snapshots replace the
  typed fixtures; a forged body, which no runner sends, is added to a recorded snapshot, and
  the fixture says so. Until then the PR lists this as an open breach of that rule.
- **The exit proc at unload** (§9). In that run `module unload muster_module` with a
  recording open on the null device took `logos_host` down with no crash report, and a
  reload answered idle; whether the exit proc ran then, rather than the process being ended
  without it, is not observed. (The daemon's stop afterwards crashed `delivery_module`'s own
  `logos_host`, in `DeliveryModuleCdylibProvider::emitTrampoline` on its event thread. That
  was not investigated, and no run of `origin/main` was made to compare, so whether this
  branch has any part in it is not known.)
- **The time between a note's two frames, past the module.** Muster hands the two frames to
  `delivery_module` back to back (§10, item 2), but each Waku timestamp is set by the
  delivery node, after the IPC hop, and what that node does between two sends of the same
  size (on `logos.test`, an RLN proof each) is not measured, so neither is the spacing a
  store node records.
- **Checks that are Linux-only or the maintainer's:**
  - the runner self-tests and `ui-parity.sh` for both UIs, `scripts/voice-self-test.sh` and
    its `voice` entry among them (S9, above);
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
- **S7 — The hosted surface and its state machine (built).** `voice_live.nim`, the six
  remaining methods, `voicePump`, and `threadRows` in `coordinate_messages`, and `close` before
  the module unloads (§9). The recorder keeps a `VoiceMemo` per room and passes it to every
  `threadRows`; `coordinate_conversations`' `lastTs` reads `threadLastTs` (§6).
  Until the operator decides (§10), `coordinate_proof` refuses a room holding a voice note.
  Test: `voice_live_test` on `SyntheticAudioIo` and `LocalTransport`, which holds §8's type
  rule (no float) in every state, and the marshalling probe's not-joined replies.
- **S8 — The UI (built).** The `.rep` (SLOTs `loadVoice`, `startVoiceRecording`,
  `stopVoiceRecording`, `sendVoiceDraft`, `discardVoiceDraft`, `playVoiceNote(noteId)`,
  `stopVoicePlayback`; PROPs `voiceJson`, `voiceResultJson`), both backends (ADR-019),
  `CardVoiceNote.qml` (pure render from the row's `voice` field), the mic in the message row
  and `RoomVoiceNote.qml` above it (the recording banner whoever started it, the draft with
  Play, Send, Discard and §8's disclosure, the module's refusals and notes), Room's 250 ms
  poll while not idle and `voice_status` on its 1 s tick, the voice words in FlowView and the
  room map, the regenerated gallery `FakeBackend.qml`, and the unknown-kind fallback. The
  gallery fixture `room-voice-forged` holds a forged `voice-note` body, and RoomThread draws
  it as plain text under its poster's name, with no voice card and no Play (§7).
- **S9 — End to end (built, not run: §15).** `scripts/voice-self-test.sh`, in
  `fileshare-self-test.sh`'s shape: two offscreen runners in one room, each with a scratch
  HOME. A records `VOICE_SECS` (3; a whole number, 1 or more, as both autopilots read it)
  seconds from a 3 s 1 kHz WAV the script writes (`MUSTER_VOICE_SOURCE`) and sends; B plays
  the note into a PCM file (`MUSTER_VOICE_SINK`). It passes when A logs the note it sent;
  from A's Stop on, delivery accepted at least two of A's sends (the note's two frames,
  whose results come back whenever they do) and refused none; B's thread holds that note
  complete and B logs it playing then nothing playing; B's file holds exactly the draft's
  samples with the 1 kHz tone (a Goertzel filter over the tone's part of the note: at least
  half the source's power, over 100 times that at 500 Hz, 1.5 kHz and 3.1 kHz); and no log
  has a QML TypeError or ReferenceError. Then C joins on `MUSTER_VOICE_BACKEND=null`: its
  Stop must call the draft silent, its Send must be refused `silent` (on macOS with the
  microphone note as `detail`), its own thread must hold no note of its own after the Send,
  and B must hold one note still (`VOICE_SILENT=0` skips C). The autopilot,
  in both backends (ADR-019): `MUSTER_AUTOVOICE=<seconds>` is the mic's Start, Stop and Send
  once someone else is in the room; `MUSTER_AUTOVOICEPLAY=1` is the card's Play for a
  complete note another member sent, while nothing plays, a refused Play tried again up to
  five times; each tick logs `VOICE` (voice_status), `VOICE-NOTES` (the thread's `voice`
  fields) and each call's `VOICE-RESULT`. The UIs still only trigger and poll.
  `ui-nim/tests/autovoice/run.sh` holds the Nim autopilot's decisions against a fake module,
  on a Mac as on Linux. A `voice` entry in `ui-parity.sh`, which refuses a bash older than 4,
  and `scripts/lib/ui-build.sh` launching and cleaning up on macOS too.
- **S10 — The claim, docs, labbook and layout (built).** The protects claim and four gaps of
  §10 in `contracts/claims/registry.json`, with `ClaimsRegistry.qml` regenerated
  (`ui/tools/gen-claims-qml.py`). Also `docs/labbook/voice-notes-audio-stack.md`, the CLAUDE.md
  layout, and `module/tests/README.md`'s real-device gate. Not done, and not in S8 either: the
  plan's optional mock of the mic and the voice card in `ui/prototype/desktop-v3.html`. It is
  dropped from this PR as optional, as FileShare's card has no mock there; the gallery's
  `room-voice-*` shots show what it would.
- **S11 — Checks on a Mac display, the opt-in device test, and the draft PR.** First, before
  anything relies on the `silent` refusal: under Basecamp 0.3.2, with a throwaway profile,
  does `logos_host` survive `voice_record_start`? If it does not, that goes back to the
  operator (§11).

  **The device test (built): `voice_device_e2e`**, in run-suite's E2E list and gated behind
  `MUSTER_VOICE_REAL`. Without it, it prints a `SKIP` line and exits 0, and run-suite counts it
  as skipped. It opens `MiniaudioIo` on the system backend through the `AudioIo` seam, with
  no mock (`module/tests/README.md` has the details):
  - **The microphone leg** (`MUSTER_VOICE_REAL=mic`, or `1`), only with the person's consent.
    It captures 2 s. The stream must read back as 48 kHz mono s16, frames must arrive at 48 a
    millisecond (±5%), the write index must only grow, and the cap must stop it at exactly
    96,000 frames with `capped` set. Then the capture goes through the module's libopus path
    at §3.1's settings and back, its length kept. It prints only the capture's peak and RMS,
    and writes nothing. An all-zero capture fails, naming the likely cause: the microphone
    permission, or a default input that hears nothing (muted, or a virtual device with
    nothing playing into it). `MUSTER_VOICE_REAL` must name a leg: any other value fails,
    separators alone (`,`) included, which before the review passed with nothing run.
  - **The speaker leg** (`speaker`, or `1`) plays digital silence by default, so nothing can
    be heard; only `MUSTER_VOICE_REAL_AUDIBLE=1` plays 0.5 s of 440 Hz at about -30 dBFS. It
    must run at 48,000 frames a second (±5%), and a short buffer must be `done` only after the
    device's own tail of silence, as on the null device. `audio_io` sets `done` only past that
    tail, so this guards the rule rather than measuring when the sound is heard.
  - **A watchdog thread** ends the test, with a message, when a device call has not returned
    after 20 s. It ends the whole test, so a leg after the one that stalled does not run (the
    speaker leg below was run alone for that reason); a leg that fails a check is recorded,
    and the next leg still runs.

  **Run on this Mac, 2026-10-22** (macOS 26.5.2, Apple Silicon, outside Basecamp, run from Claude
  Code in the Claude desktop app, with the person's consent; `MUSTER_VOICE_REAL=1`, then
  `MUSTER_VOICE_REAL=speaker`):
  - **The speaker leg passed** on Core Audio, playing silence. It read back as 48 kHz mono s16,
    took 48,480 frames in 1,010 ms (48.00 a millisecond), and a 100 ms buffer was `done` after
    130 ms, once 1,920 frames of silence had followed it. That is the tail the device read
    back (40 ms), the same as the null device's: miniaudio's buffer and periods, not Core
    Audio's output latency, which is not measured. A second run, on the committed text, gave
    the same numbers but 127 ms.
  - **The microphone leg got no frame.** macOS asked for the microphone and nobody answered:
    it was the middle of the night. Core Audio held the device's start while it asked, so
    `startCapture` had not returned after 20 s, and the watchdog ended the test. So there is
    no peak, no RMS and no codec round trip from a real microphone yet. tccd's log charged the
    request to Claude Code (`com.anthropic.claude-code`, its own `claude.app`, which the
    Claude desktop app starts through its `disclaimer` helper), not to the Claude desktop
    app: `AUTHREQ_PROMPTING` for `kTCCServiceMicrophone`, then no result. A minute later, a
    preflight for the speaker run still read the permission as not decided (`authValue=1`).
    The microphone leg was not run again. After that run its messages were reworded to name
    Claude Code, and the cap's pace is now timed from the start's return; neither touches the
    step where it stopped. Since the review the messages name the responsible app in general
    terms, not one tool; a review re-run while that prompt still waited stalled the same way,
    and tccd logged only a preflight for it, so the watchdog's log hint now reads the last hour.
  - **Before it, the same test on the null device** (a scratch mutant, not committed: the
    system backend swapped for null): with the backend checks in, both legs FAIL "backend
    Null not in @["Core Audio"]"; with them out, the microphone leg FAILs on its all-zero capture with
    the permission message, after every other check passed (48.13 frames a millisecond, capped
    at exactly 96,000 after 2,010 ms, 101 packets of 40 B, a 4,318 B record decoded back to
    96,000 samples), while its speaker leg passes.

  **To finish it:** answer the prompt, or grant Claude Code the microphone in System Settings >
  Privacy & Security > Microphone, then run `MUSTER_VOICE_REAL=mic module/tests/run-suite.sh
  e2e voice_device_e2e`. Linux has not run it (§12): PulseAudio, then ALSA, with no
  permission prompt there.

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
  as `QString`, `ready.codec` the libopus linked, both devices `"unknown"`. S7 added the six
  other voice methods, `coordinate_messages` and `coordinate_proof`, each with no room joined
  and checked to the byte. The spec's
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
  proof form carries voice parts as committed digests. Until then `coordinate_proof` refuses
  `voice-notes-present` for a room whose raw log holds any `voice/` entry, so such a room
  exports no proof at all;
- **a re-send path for a note the fleet half-delivered** (§8, §15). Delivery's send is
  fire-and-forget, so a part it lost is never seen, and nothing re-publishes a voice part:
  `coordinate_reannounce` re-sends intents only. Options: a voice part joins what
  `coordinate_reannounce` re-sends, or the module keeps a sent note's parts and re-sends a
  part no store query has returned;
- **which room holds the draft** (§8). A draft is refused as `room-changed` in any room but its
  own, and `voice_status` does not yet name that room. S8's draft surface therefore shows a
  draft in whichever room is open, and says so only when Send is refused (`room-changed`:
  "This recording belongs to another room. Send it from there, or discard it.");
- **for the operator: an older client in the room** (§10, "What still leaks", item 6). A member
  on a Muster from before voice notes (0.3.2 or earlier) serves every note's Opus to the
  modules loaded beside them, through `coordinate_graph` and `coordinate_proof`, and nothing
  in this PR can change that. Accept it as a stated gap (S10's registry entry), or keep voice
  notes out of a room until every member runs a version that strips them (nothing in the room
  says today which version a member runs);
- **for the maintainer: the version that carries voice notes.** This PR bumps no version:
  `module/metadata.json` and `ui/metadata.json` still read 0.3.2, the released
  `muster-v0.3.2`, and `RELEASING.md` step 1 bumps at release time. The registry gap and this
  doc draw the line by the feature, "a Muster from before voice notes", with "0.3.2 or
  earlier" as the releases of today. So the release that first carries voice notes should be
  numbered above every 0.3.x, 0.4.0 say, and a release cut from `main` before this PR merges
  moves "0.3.2" in the gap's body and here;
- **for the maintainer: the F-16 claim's last sentence.** The protects claim "A later joiner
  cannot read earlier messages" (`open-room`, the registry's first claim) ends "Removal
  rotates the epoch immediately." That is true of the key layer: `EpochCrypto.removeMember`
  (`epoch_crypto.nim:135`) rotates it, as `epoch_crypto_test.nim:61` shows, and
  `probe_epoch_removal_immediate` shows the same for the epoch model in `crypto/epochs.nim`.
  But no room path removes a member, which is the S10 gap "Leaving a room re-keys nothing" in
  the same step. Reword it (for example "The key layer rotates the epoch on removal; nothing in the
  room removes a member yet, the gap below"), or keep it. This PR leaves it as it is on
  `main`;
- whether to coarsen `voice_status`'s peak for co-resident callers (§13);
- the exact disclosure wording on the draft surface (§8);
- whether the gaps of §10 stay registry entries of their own, as S10 added them, or fold into
  existing ones.
