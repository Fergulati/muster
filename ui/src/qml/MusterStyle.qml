pragma Singleton
import QtQuick
import Logos.Theme

// Muster's design tokens, on top of Logos.Theme (exo-720.5, docs/design/ui-modernization.md
// §4 U1). Logos.Theme stays the source of every colour and size it has; this adds only
// what it lacks, and names the scale the redesign uses, so a view says `caption`, never a
// pixel count. Reference build: ui/prototype/desktop-v3.html.
QtObject {
    // ── type ──────────────────────────────────────────────────────────────
    // Monospace for what is data: hashes, addresses, the room code, amounts in base units.
    // Bundled (DM Mono, SIL OFL 1.1, fonts/OFL.txt) so it reads the same on every host;
    // Logos.Theme ships no mono face, and `MusterStyle.mono` never existed.
    readonly property FontLoader monoRegular: FontLoader { source: Qt.resolvedUrl("fonts/DMMono-Regular.ttf") }
    readonly property FontLoader monoMedium: FontLoader { source: Qt.resolvedUrl("fonts/DMMono-Medium.ttf") }
    readonly property string mono: monoRegular.status === FontLoader.Ready ? monoRegular.name : "monospace"

    // The scale. Theme.typography's sizes, plus one it lacks: `badge` for counts and pills.
    // Theme.typography.badgeText (8 px) is too small to read and is not used for text.
    readonly property int title: Theme.typography.panelTitleText    // 24: a page's title
    readonly property int subtitle: Theme.typography.subtitleText   // 16: a section, a room's name
    readonly property int body: Theme.typography.primaryText        // 14: what people read
    readonly property int caption: Theme.typography.secondaryText   // 12: what explains it
    readonly property int badge: 11                                 // counts and status pills

    // ── colour: the theme's, with the tints a status needs ────────────────
    function tint(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color needs: Theme.palette.primary            // waits on you
    readonly property color needsSoft: tint(Theme.palette.primary, 0.16)
    readonly property color settled: Theme.colors.green400          // done; readable on dark
    readonly property color settledSoft: tint(Theme.colors.green400, 0.14)
    readonly property color refused: Theme.colors.red400            // blocked, refused
    readonly property color refusedSoft: tint(Theme.colors.red400, 0.14)
    readonly property color warning: Theme.palette.warning
    readonly property color warningSoft: tint(Theme.palette.warning, 0.10)
    readonly property color info: Theme.palette.info                // what left the room (U-2)
    readonly property color infoSoft: tint(Theme.palette.info, 0.16)
    readonly property color neutralSoft: tint(Theme.colors.white, 0.07)
}
