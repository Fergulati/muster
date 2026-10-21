# Room history and audits: a reviewer's guide

**For:** someone reviewing how Muster shows a room's history and proves what a signature
covered, in enough detail to judge whether to trust it. **As of 2026-10-21, `main`.** The
code and the specs win over this page. Paths are relative to the repository root.

Muster gives a room's members two tools:

1. **The room map**: the room's whole history as a graph, folded from the log each member
   already holds. It shows who did what, what each step rested on, and what left the room.
2. **The audit file**: one downloadable file per proposal that proves, from the file
   alone, every signature on it, what each committed to, where each input came from, and
   how it settled.

Neither adds a fact of its own. Both are pure functions of the room's log and the
member's keys (invariant 4 in [`CLAUDE.md`](../../CLAUDE.md)). That is the property to
check first.

## See it

The landing page's [**See it run**](https://corpetty.github.io/muster/#watch) section has
a clip of each, recorded from the real app: two Basecamp installs, real transactions on
Sepolia.

- `site/media/history.mp4`: the room map on a room with two settled Safe payments:
  Replay, a payment's inspector, then the Trust, Crossings, Provenance and Log lenses.
- `site/media/audit.mp4`: Details › Download audit trail on a settled Safe payment, then
  the standalone verifier accepting the saved file, and refusing it after one character
  of the recipient changes.

How they were recorded: [`scripts/demo/README.md`](../../scripts/demo/README.md).

## 1. The log both tools read

Every member keeps the room as a content-addressed, hash-linked log. An entry's id is the
hash of its canonical bytes, and it names its parents by id. Entries are sealed to the
membership epoch's key, so a member reads only the epochs it was admitted to (invariant 7).

| What | Where |
|---|---|
| The log, content ids, canonical order | `module/src/log/log.nim` (`eventId`, `canonicalOrder`) |
| Deterministic encoding, so one value always hashes the same (invariant 5) | `module/src/dcbor/` |
| Domain-separated hash inputs | `module/src/hashing/hash_input.nim` |
| The authenticated view: author-signed entries checked, forgeries dropped | `module/src/coordination/authorship.nim` (`roomEvents`) |
| Epoch keys, re-keying on admission | `module/src/crypto/epoch_crypto.nim`, `module/src/coordination/session.nim` |

Every view below reads `roomEvents`, never the raw log.

## 2. The room map

**Design:** [`docs/design/room-map.md`](room-map.md) (epic exo-dde). Read §4 for the data
contract and §10 for the trust questions it answers.

**The fold:** `reduceRoomGraph` in `module/src/coordination/room_graph.nim`, served to
the UI as `coordinate_graph(room_topic)` (`module/src/api/muster.lidl`). It joins folds
that already exist:

| Fact on the map | Computed by | Path |
|---|---|---|
| Each entry's class, author, guarantee, epoch | `logProvenance` | `module/src/coordination/intents.nim` |
| Who could see what, per observer | `reduceFlow` | `module/src/coordination/flow.nim` |
| Each proposal's state, approvals, declines, parts | `reduceIntentViews` | `module/src/coordination/intents.nim` |
| The inputs behind a signature (invariant 10) | `intentInputs` | `module/src/coordination/attest.nim` |
| Accounts members disclosed | `reduceAccounts` | `module/src/coordination/accounts.nim` |

Rules the fold keeps, each enforced in `room_graph.nim`:

- Every node and edge carries the canonical position it appears at. Replaying to point k
  filters on that position; the view never computes state.
- Nodes are keyed by content id, never by position, so a late arrival renames nothing.
- An actor is named only where the log proves it: an author signature, a driver-counted
  approval's signer, or a binding whose statement verifies. A refused entry stays on the
  map, unattributed and marked so (invariant 9).
- Two members' graphs of the same log differ only in `viewer` and `readFrom`. A later
  joiner's graph holds nothing from before its admission, because its client never
  decrypted it (invariant 7).

**The view:** `ui/src/qml/RoomMap.qml`, opened from a room's ⋯ › Room map, or from a
card's "Who sees this?". It has seven lenses, a timeline you can scrub, and an inspector
for any node:

| Lens | Answers |
|---|---|
| Room | What is this room, and what state is it in at this point? |
| Me | What does the room know about me, and what did it pass on? |
| Trust | Which connections are enforced by code, and which rest on someone's word? |
| Where it left | Who outside the room learned what, and when? |
| Crossings | Every boundary crossing in causal order: out, in, and each admission |
| Provenance | For one proposal: each input that reached its signed bytes, and from whom |
| Log | The literal hash-linked log, in canonical order, on epoch bands |

The Trust lens uses four classes from the claims registry
(`docs/design/action-manifest.md` §2): **imperative** (the code removes the choice to
defect), **motivational** (a named party could defect but has a reason not to),
**exposed** (an unbound observer learns it), **nothing promised**.
`room_graph.facetsFor` is the one place these are written. Each one restates a guarantee
the code already enforces, and adds none.

**Do two members hold the same room?** Each epoch has a fingerprint: a digest of the ids
of the entries held from that epoch on. Two members who read the same fingerprint aloud
hold the same entries from then on. A member can paste another's fingerprint, and the map
says whether it matches.

The History tab in Room details is the same log as a plain list (`reduceActivity`,
`module/src/coordination/intents.nim`).

## 3. The audit file

**Spec:** `contracts/specs/derived-exo-403.spec.json` (criticality: critical). Its eight
clauses are the contract; read them before the code.

**The code:** `module/src/coordination/audit.nim`, three functions:

| Function | Does |
|---|---|
| `exportAudit` | Reduces this member's log to one canonical-CBOR file for one proposal, signed by the exporting member |
| `verifyAudit` | Reads nothing but the file, re-derives everything it claims, and names the first discrepancy |
| `renderAuditReport` | Renders the file as Markdown for people. It carries the file's digest and is never authoritative. |

**What the file holds** (format `muster.signature-audit.v1`):

- the effect (what was proposed) and its materialization, the exact bytes signers signed;
- the signing context: chain, account, slot and expiry (invariant 2);
- the provenance record: every input that reached the signed bytes, with its class and
  log position (invariant 10);
- the parent-closed lineage of those inputs, as the log entries themselves;
- every approval, with its driver signature, its attestation, and its grade:
  **committed**, **unattested** or **rejected**;
- the settlement entries, with their transaction hash, graded **external read**;
- the claims the log alone cannot prove (threshold, stage, disclosure, first epoch),
  signed by the exporting member.

**What the verifier checks**, with nothing but the file (`verifyAudit`, in this order):

1. It is canonical CBOR in the known format.
2. Every entry's id is the hash of its content, the lineage is in canonical order, and no
   entry names a parent the file does not carry.
3. The effect, policy and intent id agree with the proposal in the lineage.
4. The materialization re-derives from the effect (invariant 1).
5. The provenance record matches the lineage, and every input is accounted for.
6. The signing payload P re-derives.
7. Each approval's signature is by the contributor it names, over the materialization;
   no signature appears twice or under another approval.
8. Each grade is recomputed from the attestations, and must equal the one claimed.
9. Each part report on a split is by the member the driver names for that step.
10. The exporter's signature over the claims.

**What it refuses to export:** an intent whose history reaches an entry this member
cannot read, from an earlier epoch or never shared. The export is refused, never silently
truncated.

**What the file does not prove**, and says so in its report: that each signer is a Safe
owner or a room member, and that the chain agrees. Settlement is an external read. The
verifier never reports it as checked against the chain.

**In the app:** a proposal card's Details › **Download audit trail** saves two files,
`muster-audit-<id>.cbor` (what verifies) and `muster-audit-<id>.md` (the report), to the
Downloads folder (or `MUSTER_AUDIT_DIR`). The wiring is `downloadAudit` in
`ui/src/muster_ui_backend.cpp`.

**The standalone verifier:** `module/tools/muster_audit_verify.nim`. No log, no keys, no
network, no running Muster. Exit 0 when the file verifies, 1 when refused, 2 on usage
errors; `--report` also prints the rendered report.

## 4. Why trust it

Muster's rule is that invariant tests are append-only, and a claim with no test is a gap,
not a guarantee. Here is what holds each of the claims above.

**The audit file** (spec `derived-exo-403`, the probes in `module/tests/probes/`):

| Claim | Held by |
|---|---|
| The file covers every approval, input and settlement entry | `probe_audit_completeness_stepper` |
| Any one-field change, at every field class, is refused | `probe_audit_tamper_stepper` |
| Byte-identical under any log order or duplication; export writes nothing | `probe_audit_deterministic` |
| It names exactly the signers who contributed | `probe_audit_signer_names_stepper` |
| It holds only epochs the exporter holds, or refuses | `probe_audit_epoch_scope_stepper` |
| Settlement is an external read, never "verified" | `probe_audit_settlement_stepper` |
| The report is a pure function of the file | `probe_audit_report_derived` |
| The download, end to end: the saved file verifies standalone | `scripts/audit-download-self-test.sh` |

Unit tests: `module/tests/audit_counted_sig_test.nim`, `audit_declined_test.nim`,
`audit_linked_test.nim`, `audit_record_closed_test.nim`.

**The room map** (spec `derived-exo-dde`, criticality: catastrophic):

| Claim | Held by |
|---|---|
| A later joiner's map holds nothing it did not decrypt | `probe_room_map_joiner_stepper` (20 cases over real sessions) |
| The same log draws the same map, whatever the order or duplication | `probe_room_map_same_log_stepper` (24 cases) |
| The causal-order annotation never reaches state or a signed byte | `probe_after_never_reaches_state_stepper` (21 cases) |

Each probe is an oracle of its spec's clause, and the specs are graded by
`scripts/grade-specs.sh exo-403` and `scripts/grade-specs.sh exo-dde`. The design doc
records that each room-map probe was shown red by a mutation before being trusted.

**The invariants underneath** ([`CLAUDE.md`](../../CLAUDE.md)): 1 (the client re-derives
the materialization and refuses on mismatch), 2 (every signing payload binds environment,
account, slot and expiry), 4 (state is `reduce(log)`), 5 (deterministic bytes), 7 (epochs
are real), 9 (only what a member disclosed), and 10 (nothing signed whose inputs cannot be
accounted for).

**Known limits:**

- Muster's signature attestation (invariants 2 and 10) is still shown to the person as an
  opaque digest in the Logos Signer. Its typed, readable form is
  ADR-017 in `docs/02-implementation-plan.md`; the builders and verifiers have landed
  (`module/src/coordination/attest_typed.nim`) and the wiring into the signer has not
  (exo-149.6).
- The map orders entries as members saw them. A sealed entry's ordering hint is any
  member's claim (room-map.md §9).
- The map does not yet count envelopes sealed to you, only says they exist (§9).

## 5. Try it yourself

```bash
# every unit test and invariant probe, including all of the above
module/tests/run-suite.sh

# only the audit and room-map tests
module/tests/run-suite.sh audit
module/tests/run-suite.sh room_map

# grade the two specs with their own oracles
scripts/grade-specs.sh exo-403
scripts/grade-specs.sh exo-dde

# the download, end to end, in a real runner (needs `make build`)
scripts/audit-download-self-test.sh
```

**Verify a downloaded audit file yourself.** Build the verifier against the Nim
closure the module pins (this is how the clip's verifier was built, and what
`scripts/audit-download-self-test.sh` does):

```bash
P=$(module/tools/nim-closure.sh)
{ read -r SODIUM; read -r NIXGCC; } < <(nix build nixpkgs#libsodium.out nixpkgs#gcc.out --no-link --print-out-paths)
export PATH="$NIXGCC/bin:$PATH"
(cd module && nim c -d:release --threads:on \
   --path:$P/nim-secp256k1 --path:$P/nim-stew --path:$P/nim-results --path:$P/nimcrypto \
   --path:$P/nim-stint --path:$P/nim-intops/src \
   --passL:"$SODIUM/lib/libsodium.so" --passL:"-Wl,-rpath,$SODIUM/lib" \
   -o:../muster-audit-verify tools/muster_audit_verify.nim)

./muster-audit-verify ~/Downloads/muster-audit-<id>.cbor --report
```

In the clip, the file for a settled 2-of-2 Safe payment on Sepolia verifies with both
approvals `committed`, stage `final`, and settlement graded `external-read`. Then
`sed 's/0xA9D043f3/0xB9D043f3/'` changes one character of the recipient, and the copy
is refused: "the effect does not match the proposal in the lineage".

Change any byte of the `.cbor` and run it again: it is refused, and names what no longer
matches. Edit the `.md` report instead and nothing changes: the file is what verifies.

**Look at the map's data directly.** `coordinate_graph("")` on a running module returns
the JSON the view draws (room-map.md §4). The gallery fixtures in
`ui/tests/gallery/fixtures/room-map*.json` are recorded maps of a real split.
