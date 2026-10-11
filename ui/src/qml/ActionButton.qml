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
LogosButton {
    id: btn

    property bool compact: false
    property bool quiet: false

    implicitHeight: compact ? 28 : 32
    // measured in the label's own font (its implicitWidth trails a font change), plus the
    // one icon slot in use: LogosButton keeps both slots visible, the unused one at opacity 0
    TextMetrics { id: metrics; font: btn.labelItem.font; text: btn.text }
    implicitWidth: Math.max(implicitHeight, Math.ceil(metrics.advanceWidth) + 2 + leftPadding + rightPadding
                            + (icon.isVisible ? icon.size + Theme.spacing.small : 0))
    iconLeftItem.visible: icon.isVisible && icon.isLeft
    iconRightItem.visible: icon.isVisible && icon.isRight
    leftPadding: compact ? Theme.spacing.small + 2 : Theme.spacing.medium + 2
    rightPadding: leftPadding
    radius: Theme.spacing.radiusMedium
    icon.size: 16

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
