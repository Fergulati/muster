import QtQuick
import Logos.Theme
import Logos.Controls

// LogosButton at the size of its words (exo-720.5). LogosButton is 200×50 with a 16 px
// radius by default: right for one call to action on a page, too loud for the row of
// actions a card or a notice carries. This keeps its look and behaviour and changes three
// things:
//   * sized to its label: 32 px tall (28 with `compact`), radius 6
//   * a Primary label in the dark ground colour: white on the theme's orange is ~2.6:1,
//     under WCAG AA's 4.5:1 (U-10); dark on it is ~7:1
//   * `quiet`: no ground or border until hovered, for a card's secondary actions
// One Primary per view (docs/design/ui-modernization.md §3).
//
// Two design-system releases, one button (2026-10-12): Basecamp 0.3.2 ships
// logos-design-system 88330d0, whose LogosButton names its icon `leadingIcon` (and its
// slots leadingIconItem / trailingIconItem); the runner's newer release names it `icon`
// (iconLeftItem / iconRightItem). QML refuses to compile an assignment to a property the
// type lacks, and one such line blanked the whole view in Basecamp ("Type ActionButton
// unavailable … Cannot assign to non-existent property "icon"": Launch did nothing). So
// an icon is set through `iconSource` / `iconColor` here, and applied at run time to
// whichever slot the installed release has. scripts/ui-lint.sh lints against both.
LogosButton {
    id: btn

    property bool compact: false
    property bool quiet: false
    property url iconSource: ""
    property color iconColor: "transparent"     // transparent: the release's own default

    readonly property bool hasIcon: iconSource.toString().length > 0
    // one release's member, looked up by name at run time: the other release lacks it
    function slot(name) { return btn[name]; }
    readonly property var iconSpec: slot("icon") !== undefined ? slot("icon") : slot("leadingIcon")
    function applyIcon() {
        var spec = btn.iconSpec;
        if (!spec) return;
        spec.source = btn.iconSource;
        spec.size = 16;
        if (btn.iconColor.a > 0) spec.color = btn.iconColor;
    }
    onIconSourceChanged: applyIcon()
    onIconColorChanged: applyIcon()
    Component.onCompleted: {
        // the newer release keeps both slots visible, the unused one at opacity 0: hide
        // them unless there is an icon, so the button is the size of its words
        if (slot("iconLeftItem") !== undefined) {
            slot("iconLeftItem").visible = Qt.binding(function () { return btn.hasIcon; });
            slot("iconRightItem").visible = false;
        }
        applyIcon();
    }

    implicitHeight: compact ? 28 : 32
    // measured in the label's own font (its implicitWidth trails a font change), plus the
    // icon when there is one
    TextMetrics { id: metrics; font: btn.labelItem.font; text: btn.text }
    implicitWidth: Math.max(implicitHeight, Math.ceil(metrics.advanceWidth) + 2 + leftPadding + rightPadding
                            + (hasIcon ? 16 + Theme.spacing.small : 0))
    leftPadding: compact ? Theme.spacing.small + 2 : Theme.spacing.medium + 2
    rightPadding: leftPadding
    // the label centred in the 32 px: Basecamp's release pads 12 px above and below,
    // which left the label 8 px and drew it low
    topPadding: 0
    bottomPadding: 0
    radius: Theme.spacing.radiusMedium

    labelItem.color: !enabled ? Theme.palette.textMuted
                   : variant === LogosButton.Variant.Primary ? Theme.palette.background
                   : quiet && !isActive ? Theme.palette.textSecondary : Theme.palette.text
    labelItem.font.weight: Theme.typography.weightBold
    labelItem.font.pixelSize: compact ? MusterStyle.caption : 13
    backgroundItem.color: !enabled ? Theme.palette.backgroundMuted
                        : variant === LogosButton.Variant.Primary
                          ? (isActive ? Theme.palette.primaryHover : Theme.palette.primary)
                          : quiet ? (isActive ? Theme.palette.backgroundSecondary : "transparent")
                          : (isActive ? Theme.palette.backgroundMuted : Theme.palette.backgroundSecondary)
    // a keyboard focus ring (U-10): LogosButton draws none
    focusPolicy: Qt.StrongFocus
    Keys.onReturnPressed: if (enabled) clicked()
    Keys.onSpacePressed: if (enabled) clicked()
    backgroundItem.border.width: activeFocus ? 2 : 1
    backgroundItem.border.color: activeFocus ? Theme.palette.focus
                               : quiet && variant !== LogosButton.Variant.Primary ? "transparent"
                               : variant === LogosButton.Variant.Primary ? Theme.palette.primary
                               : isActive ? Theme.palette.borderStrong : Theme.palette.border

    Accessible.role: Accessible.Button
    Accessible.name: text
}
