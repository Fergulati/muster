import QtQuick

// The recorder (exo-720.2): the real Main.qml, wrapped. A dev plugin dir
// (scripts/lib/ui-dev.sh, --record) makes this its view, so a real runner, driven by a
// real self-test, writes what the module actually returned into JSON snapshots; the
// gallery replays them as fixtures. Never shipped: the builder copies ui/src/qml only.
//
// Every second it reads the contract's PROPs off the live replica, plus which surface
// Main shows, and writes a snapshot when anything changed. Writing a file from QML takes
// QML_XHR_ALLOW_FILE_WRITE=1, which the dev launcher sets.
Item {
    id: recorder

    readonly property var backend: logos.module("muster_ui")
    // a per-launch tag: two instances sharing one plugin dir never write the same file
    readonly property string tag: Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
    property int seq: 0
    property string last: ""
    property var pending: []

    FakeBackend { id: contract }   // only for its contractProps list

    Loader {
        id: main
        anchors.fill: parent
        source: Qt.resolvedUrl("Main.qml")
    }

    function snapshot() {
        if (!backend) return;
        var props = {};
        for (var i = 0; i < contract.contractProps.length; ++i) {
            var n = contract.contractProps[i];
            props[n] = String(backend[n] === undefined ? "" : backend[n]);
        }
        var ui = main.item ? { view: String(main.item.view || "") } : {};
        var body = JSON.stringify({ props: props, ui: ui });
        if (body === last) return;
        last = body;
        seq += 1;
        var xhr = new XMLHttpRequest();
        // held until the write completes: a request only a local names can be collected
        // mid-write, which left a large snapshot (a long room's map) as an empty file
        recorder.pending.push(xhr);
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                var i = recorder.pending.indexOf(xhr);
                if (i >= 0) recorder.pending.splice(i, 1);
            }
        };
        xhr.open("PUT", Qt.resolvedUrl("snapshots/" + tag + "-" + ("000" + seq).slice(-4) + ".json"));
        xhr.send(JSON.stringify({ tag: tag, seq: seq, at: Date.now(), props: props, ui: ui }, null, 1));
    }

    Timer { interval: 250; running: true; repeat: true; onTriggered: recorder.snapshot() }
    // The room map's graph is fetched only while the map is open, so ask for it here too:
    // every snapshot of a joined room then carries what coordinate_graph returned (exo-dde).
    Timer {
        interval: 2000; running: true; repeat: true
        onTriggered: if (recorder.backend && String(recorder.backend.roomTopic || "").length > 0) recorder.backend.loadGraph("")
    }
}
