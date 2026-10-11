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
    // A status's words on its own tint, at the pill's 11 px, must clear WCAG AA's 4.5:1
    // (U-10): the theme's orange there is 4.4:1 and its blue 3.8:1, so a pill's text is a
    // step lighter — 5.7:1 and 6.1:1 (exo-720.12).
    readonly property color needsText: Qt.lighter(Theme.palette.primary, 1.15)
    readonly property color infoText: Qt.lighter(Theme.palette.info, 1.3)

    // A notice draws its own glyph: the ⚠ / ⏳ the old one-line notices led with go.
    function plain(s) { return String(s || "").replace(/^(⚠|⏳|✓)\uFE0F?\s*/, ""); }

    // ── icons: icons/<name>.svg, stroke icons in the grey LogosIcon tints ─────
    // For what Logos.Icons lacks (more, close, copy, search, warning come from there).
    // An icon draws only where Qt Quick renders with GL (MultiEffect): an icon-only
    // control always carries a label or a tooltip (IconAction does).
    function icon(name) { return Qt.resolvedUrl("icons/" + name + ".svg"); }

    // ── a member's colour: from their id, so it says nothing they did not disclose
    // (invariant 9) and stays the same in every room and on every device ──────
    readonly property var avatarColors: [Theme.colors.orange300, Theme.colors.yellow400, Theme.colors.green400,
                                         Theme.colors.blue400, Theme.colors.cyan400, Theme.colors.red400,
                                         Theme.colors.peach100, Theme.colors.green700]
    function colorFor(id) {
        // FNV-1a, then a final avalanche, so ids that differ in one character spread out
        var s = String(id || "").toLowerCase().replace(/^0x/, ""), h = 0x811c9dc5;
        for (var i = 0; i < s.length; ++i) h = Math.imul(h ^ s.charCodeAt(i), 0x01000193);
        h ^= h >>> 16; h = Math.imul(h, 0x45d9f3b); h ^= h >>> 16;
        return avatarColors[(h >>> 0) % avatarColors.length];
    }
}
