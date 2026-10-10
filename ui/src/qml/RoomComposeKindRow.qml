import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The composer's kind row (exo-720.3, moved verbatim out of RoomComposer.qml): Payment,
// Statement, Action, Split, Request. `room` is the Room, as before the move.
// ── kind: the effect type (the ACTION is pluggable) ───────────
// A payment (a transfer) or a statement the room ratifies — the same
// propose/contribute/fold path coordinates either.
RowLayout {
    required property var room

    Layout.fillWidth: true
    spacing: Theme.spacing.small

    LogosText {
        text: qsTr("Kind")
        color: Theme.palette.textTertiary
        font.family: MusterStyle.mono
        font.pixelSize: MusterStyle.caption
        font.weight: Theme.typography.weightMedium
    }

    LogosButton {
        objectName: "roomKindPayment"
        Layout.preferredWidth: 110
        text: qsTr("Payment")
        variant: room.composeType === "payment"
                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        onClicked: room.composeType = "payment"
    }

    LogosButton {
        objectName: "roomKindStatement"
        Layout.preferredWidth: 120
        text: qsTr("Statement")
        variant: room.composeType === "statement"
                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        onClicked: room.composeType = "statement"
    }

    // a generic module action (P-D4): coordinate calling a loaded
    // module's method — the room endorses it, the core invokes it.
    LogosButton {
        objectName: "roomKindAction"
        Layout.preferredWidth: 110
        text: qsTr("Action")
        variant: room.composeType === "action"
                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        onClicked: room.composeType = "action"
    }

    // a split (exo-a90): you fronted a bill; each person named pays you back
    // their own share from their own wallet — no shared account.
    LogosButton {
        objectName: "roomKindSplit"
        Layout.preferredWidth: 90
        text: qsTr("Split")
        variant: room.composeType === "split" && !room.splitRequest
                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        onClicked: { room.splitRequest = false; room.composeType = "split"; }
    }

    // a payment request (exo-dcc.5): one person pays you, and you're not in it
    LogosButton {
        objectName: "roomKindRequest"
        Layout.preferredWidth: 110
        text: qsTr("Request")
        variant: room.composeType === "split" && room.splitRequest
                 ? LogosButton.Variant.Primary : LogosButton.Variant.Secondary
        onClicked: { room.splitRequest = true; room.composeType = "split"; }
    }

    Item { Layout.fillWidth: true }
}
