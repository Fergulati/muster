import QtQuick
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls
import Logos.Icons

// The control census (exo-720.1, docs/design/ui-modernization.md §4 U0a): every
// design-system control the redesign plans to use, in the host that will run it.
// Today's UI uses three (LogosText, LogosButton, LogosTextField), because a QML error
// blanks a view without failing the build; this is the evidence for lifting that rule.
//
// Run by `scripts/ui-screenshot.sh census` as a dev runner's view on Xvfb. It shows the
// in-place controls, then opens the popups one phase at a time (a Menu with a ToolTip,
// a Dialog, a Drawer) and after each writes census/phase-N.json, so the script captures
// the X display at the right moment. Each phase file also says which controls were
// created, so a control that fails to load is named rather than missing from a picture.
Item {
    id: census
    width: 1024; height: 768

    property int phase: 0
    property var created: ({})
    function made(name, obj) { var c = created; c[name] = !!obj; created = c; }

    Rectangle { anchors.fill: parent; color: Theme.palette.background }

    GridLayout {
        id: grid
        anchors.fill: parent
        anchors.margins: 24
        columns: 3
        rowSpacing: 18
        columnSpacing: 24

        component Cell: ColumnLayout {
            property alias label: lbl.text
            default property alias content: holder.data
            spacing: 6
            Layout.alignment: Qt.AlignTop
            LogosText { id: lbl; color: Theme.palette.textTertiary; font.pixelSize: Theme.typography.secondaryText }
            Item { id: holder; implicitWidth: childrenRect.width; implicitHeight: childrenRect.height }
        }

        Cell { label: "LogosButton · Primary / Secondary"
            Row { spacing: 8
                LogosButton { text: "Primary"; variant: LogosButton.Variant.Primary; Component.onCompleted: census.made("LogosButton", this) }
                LogosButton { text: "Secondary" } } }
        Cell { label: "LogosIconButton (tinted by MultiEffect)"
            Row { spacing: 8
                LogosIconButton { iconSource: LogosIcons.more; Component.onCompleted: census.made("LogosIconButton", this) }
                LogosIconButton { iconSource: LogosIcons.close; iconColor: Theme.palette.primary }
                LogosIconButton { iconSource: LogosIcons.search; size: 32; iconSize: 16 } } }
        Cell { label: "LogosIcon · LogosIcons (17)"
            Flow { width: 260; spacing: 6
                Repeater {
                    model: ["arrowLeft","arrowRight","triangleDown","refresh","install","trash","more","search","close","copy","grid","list","pages","warning"]
                    delegate: LogosIcon { required property string modelData; width: 20; height: 20; source: LogosIcons[modelData]
                                          Component.onCompleted: census.made("LogosIcon", this) } } } }
        Cell { label: "LogosBadge"
            Row { spacing: 8
                LogosBadge { text: "3"; Component.onCompleted: census.made("LogosBadge", this) }
                LogosBadge { text: "Needs you"; color: Theme.palette.primary } } }

        Cell { label: "LogosTabBar · LogosTabButton"
            LogosTabBar { width: 300; Component.onCompleted: census.made("LogosTabBar", this)
                LogosTabButton { text: "People" } LogosTabButton { text: "Accounts" }
                LogosTabButton { text: "History" } LogosTabButton { text: "Privacy" } } }
        Cell { label: "LogosItemDelegate (a room row)"
            Column { width: 260
                LogosItemDelegate { width: 260; text: "Dinner at Ana's"; Component.onCompleted: census.made("LogosItemDelegate", this) }
                LogosItemDelegate { width: 260; text: "Ops Safe"; highlighted: true } } }
        Cell { label: "LogosSwitch · LogosComboBox"
            Row { spacing: 12
                LogosSwitch { checked: true; Component.onCompleted: census.made("LogosSwitch", this) }
                LogosComboBox { width: 160; model: ["logos.dev", "logos.test"]; Component.onCompleted: census.made("LogosComboBox", this) } } }
        Cell { label: "LogosSearchBar (Jump to…)"
            LogosSearchBar { width: 260; placeholderText: "Jump to…"; shortcutHint: "Ctrl K"; Component.onCompleted: census.made("LogosSearchBar", this) } }

        Cell { label: "LogosScrollView"
            LogosScrollView { width: 260; height: 90; clip: true; Component.onCompleted: census.made("LogosScrollView", this)
                Column { Repeater { model: 8; LogosText { required property int index; text: "row " + index; color: Theme.palette.text } } } } }
        Cell { label: "LogosStackView"
            LogosStackView { width: 260; height: 60; initialItem: Rectangle { color: Theme.palette.surface; LogosText { anchors.centerIn: parent; text: "a pushed page"; color: Theme.palette.text } }
                             Component.onCompleted: census.made("LogosStackView", this) } }
        Cell { label: "LogosSpinner · LogosTextArea"
            Row { spacing: 12
                LogosSpinner { running: true; Component.onCompleted: census.made("LogosSpinner", this) }
                LogosTextArea { width: 180; height: 60; placeholderText: "Say something"; Component.onCompleted: census.made("LogosTextArea", this) } } }
        Cell { label: "Popups: Menu + ToolTip, Dialog, Drawer"
            LogosButton { id: menuAnchor; text: "⋯ More" } }
    }

    LogosMenu {
        id: menu
        Component.onCompleted: census.made("LogosMenu", this)
        LogosMenuItem { text: "Rename" }
        LogosMenuItem { text: "Room details" }
        LogosMenuSeparator {}
        LogosMenuItem { text: "Leave room…" }
    }
    LogosToolTip { id: tip; parent: menuAnchor; text: "Room details (Esc closes)"; Component.onCompleted: census.made("LogosToolTip", this) }
    LogosDialog {
        id: dialog
        anchors.centerIn: parent
        title: "Leave this room?"
        message: "It stops showing here, and this device stops following it."
        Component.onCompleted: census.made("LogosDialog", this)
    }
    LogosDrawer {
        id: drawer
        edge: Qt.RightEdge
        width: 360; height: census.height
        Component.onCompleted: census.made("LogosDrawer", this)
        LogosText { x: 16; y: 16; text: "Room details"; color: Theme.palette.text; font.pixelSize: Theme.typography.subtitleText }
    }

    function writePhase() {
        var xhr = new XMLHttpRequest();
        xhr.open("PUT", Qt.resolvedUrl("census/phase-" + phase + ".json"));
        xhr.send(JSON.stringify({ phase: phase, created: created }));
    }

    // phase 0: in-place controls · 1: Menu + ToolTip · 2: Dialog · 3: Drawer. One tick
    // writes the current phase's file (the script captures the display then), the next
    // moves to the following phase.
    property int tick: 0
    Timer {
        interval: 1500; running: true; repeat: true
        onTriggered: {
            census.tick += 1;
            if (census.tick % 2 === 1) { census.writePhase(); if (census.phase === 3) stop(); return; }
            census.phase += 1;
            if (census.phase === 1) { menu.popup(menuAnchor, 0, menuAnchor.height); tip.visible = true; }
            else if (census.phase === 2) { menu.close(); tip.visible = false; dialog.open(); }
            else if (census.phase === 3) { dialog.close(); drawer.open(); }
        }
    }
}
