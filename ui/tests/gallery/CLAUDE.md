# ui/tests/gallery — seeing the QML without a screen (exo-720.1, exo-720.2)

Driven by `scripts/ui-screenshot.sh` (gallery · record · census · compare) and checked by `scripts/ui-lint.sh`. Traps and findings: `docs/labbook/screenshots-of-the-qml-that-hold-still.md`. Plan: `docs/design/ui-modernization.md` §4 U0.

- `FakeBackend.qml` is **generated** from `ui/src/muster_ui.rep` by `ui/tools/gen-fake-backend.py`. Never edit it; rerun the generator after a `.rep` change (`--check` fails on drift).
- `Gallery.qml` renders the real `ui/src/qml/Main.qml` against the fake, with a fixture's PROPs, and screenshots it. `Recorder.qml` and `Census.qml` are dev-runner views (`scripts/lib/ui-dev.sh`); none of these files ships, because the builder copies `ui/src/qml` only.
- **Fixture data is recorded, never hand-typed.** `fixtures/data/*.json` are snapshots a real runner wrote while a self-test drove it (`scripts/ui-screenshot.sh record scripts/split-self-test.sh`). To cover a new state, record the self-test that reaches it, then copy the snapshot and name the fixture after the state.
- A pure code move must leave every gallery shot identical: `scripts/ui-screenshot.sh gallery --out A` before, `--out B` after, then `compare A B`. The harness pins `QT_HASH_SEED=0` and `LP_NUM_THREADS=1`, and renders with GL (Mesa on Xvfb) so icons draw; keep all three.
