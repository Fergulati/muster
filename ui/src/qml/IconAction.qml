import QtQuick
import Logos.Theme
import Logos.Controls

// An icon button that always says what it does (exo-720.5): a tooltip on hover, and the
// same words for assistive tech. Its icon draws only where Qt Quick renders with GL, so
// the label is not optional. `checked` marks a toggle that is on (the details panel open).
Item {
    id: action

    required property string label        // "Room details", "Collapse the sidebar"
    property url icon: ""                  // MusterStyle.icon("…") or a LogosIcons url
    property bool checked: false
    property int size: 32
    property color iconColor: checked || hover.hovered ? Theme.palette.text : Theme.palette.textSecondary
    signal clicked()

    implicitWidth: size
    implicitHeight: size
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: action.clicked()
    activeFocusOnTab: true
    Keys.onSpacePressed: action.clicked()
    Keys.onReturnPressed: action.clicked()

    Rectangle {
        anchors.fill: parent
        radius: Theme.spacing.radiusMedium
        color: action.checked ? Theme.palette.surface
             : hover.hovered || tap.pressed ? Theme.palette.backgroundSecondary : "transparent"
        border.width: action.activeFocus ? 2 : 0
        border.color: Theme.palette.focus
    }
    LogosIcon {
        anchors.centerIn: parent
        width: Math.round(action.size * 0.56)
        height: width
        source: action.icon
        color: action.iconColor
    }
    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
    TapHandler { id: tap; onTapped: action.clicked() }
    LogosToolTip { visible: hover.hovered; text: action.label }
}
