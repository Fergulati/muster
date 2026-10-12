# Basecamp ships its own design system, and it is older than the runner's

**Found 2026-10-12, Part B of the UI redesign review (`docs/runbooks/ui-redesign-review.md`).** Muster installed from the catalogue into Basecamp 0.3.2, and clicking **Launch** did nothing. No window opened and no message was shown.

## What happened

Basecamp's log said why:

```
Failed to compile ui_qml view "muster_ui" : "Main.qml:420:5: Type Home unavailable
Home.qml:112:17: Type ActionButton unavailable
ActionButton.qml:31:5: Cannot assign to non-existent property "icon"
```

- **Where the controls come from.** Basecamp resolves every plugin's `Logos.Theme`, `Logos.Controls` and `Logos.Icons` imports to its own copy of the design system, compiled into `main_ui.so`. It never uses the plugin's copy or the runner's. The log says so: "Redirected Logos.Controls probe away from plugin tree … shared Logos.* modules resolve from the vetted design-system dir".
- **The version.** Basecamp 0.3.2 ships `logos-design-system` 88330d0 (Settings → Dashboard → Commits). The standalone runner uses a newer release.
- **The difference.** In 88330d0, `LogosButton` names its icon `leadingIcon` / `trailingIcon`, and its slots `leadingIconItem` / `trailingIconItem`. In the newer release it is `icon`, with `iconLeftItem` / `iconRightItem`.
- **Why it blanks the view.** QML refuses to compile an assignment to a property the type lacks. One such line in `ActionButton.qml` made `ActionButton` unavailable, then `Home`, then `Main`.
- **Why nothing caught it.** The gallery, `scripts/ui-lint.sh` and the runner all use the runner's design system, so none of them could see it.

Fixed in `ActionButton.qml`:
- An icon is set through its own `iconSource` / `iconColor`, applied at run time to whichever slot the installed release has. A member is looked up by name through `slot(name)`, so neither the compiler nor `qmllint` binds to a member only one release has.
- Basecamp's release also pads a button 12 px top and bottom, which drew the label low in a 32 px button, so `ActionButton` sets the vertical padding to 0.

## What holds it now

- `infra/basecamp/release-0.3.2.env` pins `BASECAMP_DESIGN_SYSTEM_REV`.
- `scripts/ui-lint.sh` fetches that revision once into `~/.cache/muster/` and lints `ui/src/qml` against it too. Its findings are tagged `basecamp-0.3.2`. Against the `ActionButton.qml`, `Home.qml` and `RoomHeader.qml` from before the fix, it reports the 13 errors above.
- When Muster targets a newer Basecamp, update the env file to that release's design-system commit.

## Checked

`scripts/basecamp-local-catalogue.sh review --fresh --xvfb :95` on bugger. Basecamp 0.3.2 installed Muster 0.2.2 from the local catalogue with every dependency from Logos Official, and before the fix Launch logged the failure above. With the fixed files, Basecamp logged "Successfully loaded UI module: muster_ui". Needs you, Start something and a room all render.

The only warning from the plugin was a deprecated signal-handler parameter injection (`Main.qml` `onCreateRoom`), now fixed. Under Xvfb's software renderer every icon draws blank (`MultiEffect`), so icon-only buttons are invisible there; a real display draws them.
