import QtQuick
import Logos.Theme

// Three dots that pulse in turn (exo-ba0): something is on its way. Shown where an answer
// is awaited, beside words that say what is awaited — never alone, and never where the
// answer is simply "nothing".
Row {
    id: loading
    property bool running: true
    property color color: Theme.palette.textSecondary
    spacing: 5
    Accessible.role: Accessible.Animation
    Accessible.name: qsTr("Loading")

    Repeater {
        model: 3
        delegate: Rectangle {
            id: dot
            required property int index
            width: 7; height: 7; radius: 3.5
            color: loading.color
            SequentialAnimation on opacity {
                running: loading.running && loading.visible
                loops: Animation.Infinite
                PauseAnimation { duration: dot.index * 160 }
                NumberAnimation { from: 0.25; to: 1; duration: 320 }
                NumberAnimation { to: 0.25; duration: 320 }
                PauseAnimation { duration: (2 - dot.index) * 160 }
            }
        }
    }
}
