import QtQuick
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// The room's header (exo-720.3, moved verbatim out of Room.qml): its title and
// rename, Leave and what leaving does, the room code, and the join row shown until a
// room is joined. Each `room.x` is the Room's own state, as before the move.
ColumnLayout {
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    Layout.fillWidth: true
    spacing: Theme.spacing.medium

    // ── header ────────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        LogosText {
            objectName: "roomTitleText"
            visible: !renameRow.visible
            Layout.fillWidth: true
            text: room.joined ? (room.roomTitle.length > 0 ? room.roomTitle : qsTr("Unnamed room"))
                              : qsTr("Join a room")
            color: Theme.palette.text
            font.family: Theme.typography.publicSans
            font.pixelSize: Theme.typography.primaryText
            font.weight: Theme.typography.weightBold
            elide: Text.ElideRight
        }

        // Rename: the name is yours, kept on this device, never sent to the room.
        RowLayout {
            id: renameRow
            property bool open: false
            visible: room.joined && open
            Layout.fillWidth: true
            spacing: Theme.spacing.small
            LogosTextField {
                id: renameField
                objectName: "roomRenameField"
                Layout.fillWidth: true
                placeholderText: qsTr("A name for this room (only you see it)")
            }
            LogosButton {
                id: renameSave
                objectName: "roomRenameSave"
                text: qsTr("Save")
                onClicked: { room.renameRequested(room.topic, renameField.text); renameRow.open = false; }
            }
        }

        LogosButton {
            objectName: "roomRenameButton"
            visible: room.joined && !renameRow.open
            text: qsTr("Rename")
            variant: LogosButton.Variant.Secondary
            onClicked: { renameField.text = room.roomTitle; renameRow.open = true; renameField.forceActiveFocus(); }
        }

        LogosButton {
            objectName: "leaveRoomButton"
            visible: room.joined
            text: qsTr("Leave")
            variant: LogosButton.Variant.Secondary
            onClicked: leaveConfirm.visible = true
        }

        LogosText {
            objectName: "roomMembersLabel"
            visible: room.joined
            text: qsTr("%1 in the room").arg(room.members.length)
            color: Theme.palette.textTertiary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
        }
    }

    // ── leaving: say what it does before doing it (exo-dcc.28) ─────────
    RowLayout {
        id: leaveConfirm
        objectName: "leaveConfirm"
        visible: false
        Layout.fillWidth: true
        spacing: Theme.spacing.small
        LogosText {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            text: qsTr("Leave this room? It stops showing here, and this device stops following it. "
                       + "The others are not told and still count you in. Join it again with its room code.")
            color: Theme.palette.textSecondary
            font.pixelSize: Theme.typography.secondaryText
        }
        LogosButton {
            objectName: "leaveRoomConfirm"
            text: qsTr("Leave room")
            onClicked: { leaveConfirm.visible = false; room.leaveRequested(room.topic); }
        }
        LogosButton {
            text: qsTr("Stay")
            variant: LogosButton.Variant.Secondary
            onClicked: leaveConfirm.visible = false
        }
    }

    // ── the room code: what someone else needs to find this room (exo-dcc.25) ──
    // In full and copyable: the random tail is the part that names the room, so it is
    // never elided. Whoever joins with it asks to join; a person you invite from Home's
    // composer is let in by the invite itself.
    RowLayout {
        visible: room.joined
        Layout.fillWidth: true
        spacing: Theme.spacing.small
        LogosText {
            text: qsTr("Room code")
            color: Theme.palette.textTertiary
            font.pixelSize: MusterStyle.caption
        }
        TextEdit {
            id: roomCode
            objectName: "roomTopicText"
            Layout.fillWidth: true
            readOnly: true
            selectByMouse: true
            wrapMode: TextEdit.WrapAnywhere
            text: room.topic
            color: Theme.palette.textSecondary
            selectionColor: Theme.palette.primary
            font.family: MusterStyle.mono
            font.pixelSize: MusterStyle.caption
        }
        LogosButton {
            id: copyCode
            objectName: "copyRoomTopic"
            property bool copied: false
            text: copied ? qsTr("Copied") : qsTr("Copy room code")
            variant: LogosButton.Variant.Secondary
            onClicked: { roomCode.selectAll(); roomCode.copy(); roomCode.deselect(); copied = true; copiedReset.restart(); }
            Timer { id: copiedReset; interval: 2000; onTriggered: copyCode.copied = false }
        }
    }

    // ── join (until a room is joined) ─────────────────────────────────
    RowLayout {
        visible: !room.joined
        Layout.fillWidth: true
        spacing: Theme.spacing.small

        LogosTextField {
            id: topicField
            objectName: "roomTopicField"
            Layout.fillWidth: true
            placeholderText: qsTr("room code, e.g. /muster/1/muster.room.6ac8ea9cdc366149/proto")
        }

        LogosButton {
            objectName: "joinRoomButton"
            text: qsTr("Join")
            enabled: topicField.text.length > 0
            onClicked: {
                room.founded = false;   // joined by name: maybe someone else's room
                if (room.backend) room.backend.joinRoom(topicField.text);
            }
        }
    }
}
