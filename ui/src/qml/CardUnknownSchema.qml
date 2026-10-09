import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// A card whose schema this app does not recognize (exo-720.3, moved verbatim out of
// MusterCard.qml; exo-1ec.3). `cardRoot` is the MusterCard, as before the move.
// ── schema unknown (exo-1ec.3) ─────────────────────────────────────
// A proposal whose effect declares a schema muster does not recognize. We
// render a NAMED failure — what was declared, and why nothing is shown from it
// — rather than coercing it to a payment or leaving a blank pane. There is no
// Approve here: you cannot endorse bytes the app cannot re-derive (F-4).
ColumnLayout {
    required property var cardRoot

    objectName: "cardSchemaUnknown"
    visible: cardRoot.kind === "intent-propose" && !cardRoot.schemaKnown
    Layout.fillWidth: true
    spacing: Theme.spacing.tiny

    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("⚠ Schema unknown")
        color: Theme.palette.warning
        font.family: Theme.typography.publicSans
        font.pixelSize: Theme.typography.primaryText
        font.weight: Theme.typography.weightBold
    }
    LogosText {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        text: qsTr("This activity declares “%1”, a schema this app does not recognize. "
                 + "Nothing is rendered from it — an activity is shown only from a "
                 + "declared, versioned schema, so it is never displayed as something "
                 + "it is not.").arg(cardRoot.schemaId.length > 0 ? cardRoot.schemaId
                                                                  : qsTr("an unknown effect"))
        color: Theme.palette.textSecondary
        font.pixelSize: Theme.typography.badgeText
    }
}
