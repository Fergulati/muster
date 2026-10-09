# Screenshots of the QML that hold still (2026-10-09)

The UI redesign (epic exo-720) needs to *see* every change, and to prove that a refactor
which only moves code changes no pixel. `nix build` never evaluates QML, and an offscreen
runner never draws it (`qml-errors-are-invisible-to-nix-build.md`). What now works is
`scripts/ui-screenshot.sh` (exo-720.2) and `scripts/ui-lint.sh` (exo-720.1). Each of the
traps below cost a run to find.

## What the harness is

- **A dev runner, no rebuild.** The runner loads its view from a plugin directory on disk
  (`qml/Main.qml` beside `muster_ui_plugin.so`). `scripts/lib/ui-dev.sh` copies a built
  runner's plugin dir as symlinks and puts this tree's `ui/src/qml` in its `qml/`, so a
  QML-only change runs in the real runner without `make build`. Valid while the runner's
  compiled half (the `.rep`, the C++ backend, `muster_module`) matches the tree.
- **Real data, recorded.** `record` runs an existing self-test through a dev runner whose
  view, `Recorder.qml`, wraps `Main.qml` and writes every backend PROP to a JSON snapshot
  once a second. `split-self-test.sh` on `MUSTER_FLEET=local` gave a join request
  pending, a split collecting, agreed, submitted and final, in about 20 s. A fixture
  names a snapshot; no card JSON is ever hand-typed.
- **The gallery.** The real `Main.qml` in a bare `qml` process against `FakeBackend.qml`,
  generated from `muster_ui.rep` (`ui/tools/gen-fake-backend.py --check` keeps it current).
  The runner's own Qt 6.9.2 and Logos design system, read from its closure.

## The traps

- **The offscreen platform never instantiates the runner's view.** Recording needs a real
  X server: Xvfb, `QT_QPA_PLATFORM=xcb`. `ui-build.sh` takes `MUSTER_QPA` and
  `MUSTER_RUNNER` for this; unset, every self-test runs as before.
- **Icons vanish under the software renderer.** `LogosIcon` and `LogosIconButton` tint
  through `MultiEffect`, a shader effect. With `QT_QUICK_BACKEND=software` it draws
  nothing: empty circles, an empty icon row. With GL (Mesa on Xvfb) every icon shows. So
  the gallery renders with GL, and **an icon-only button needs a tooltip or a label**:
  on a host that falls back to software rendering, its icon is gone.
- **Nix's libglvnd finds no GL vendor on Ubuntu.** A bare `qml` on Xvfb fails with
  "neither GLX nor EGL are enabled" and dumps core. The runner's closure carries Mesa;
  `__EGL_VENDOR_LIBRARY_FILENAMES=<mesa>/share/glvnd/egl_vendor.d/50_mesa.json` fixes it.
  `ui_qt_env` finds that file in the closure.
- **Two runs differ by a few pixels, twice over.** Text: the glyph cache fills in hash
  order, and Qt seeds its hash per process, so antialiased glyph edges move by up to 3/255
  between runs. `QT_HASH_SEED=0`. Rasterising: llvmpipe across threads; `LP_NUM_THREADS=1`.
  With both, 36 of 36 shots are identical run to run. Waiting longer before the shot does
  not help; it is not an animation.
- **A window's `contentItem` cannot be grabbed from QML** ("item has no QML engine").
  The gallery grabs its own root item, so a `Popup` on the window overlay would be missing
  from the picture. Today's UI has none. When the redesign adds Menus and Drawers, capture
  the X display instead (`import -window root`), as `census` does.
- **`setsid cmd &` forks when the shell's job is a group leader,** so `$!` is not the
  process to kill. Write the pid from inside: `setsid bash -c 'echo $$ >pidfile; exec …'`.
  And never `pkill -f` a pattern the killing shell's own command line contains.

## What the census and the lint found (2026-10-09)

- **All 17 controls the redesign plans to use render in the real runner,** with zero QML
  warnings: Button, IconButton, Icon, Badge, TabBar/TabButton, ItemDelegate, Switch,
  ComboBox, SearchBar, ScrollView, StackView, Spinner, TextArea, Menu, ToolTip, Dialog,
  Drawer (`scripts/ui-screenshot.sh census`). Basecamp and the Nim host are still to check.
- **`Theme.typography.mono` does not exist** in the design system the runner ships, and
  the QML uses it 136 times. Every "monospace" text (hashes, the room code, addresses)
  silently falls back to the default font.
- **`LogosButton.Variant.Tertiary` does not exist** (4 uses); the enum has only Primary
  and Secondary.
- **`Theme.palette.borderDefault` (6 uses) and `textPrimary` (1) do not exist.** `palette`
  is untyped, so qmllint cannot see these; `ui-lint.sh` checks every key against the
  theme's own property list.

These 147 are `ui/tests/qmllint-baseline.json`. The gate fails only on new ones; U1
(exo-720.5) pays the baseline down.
