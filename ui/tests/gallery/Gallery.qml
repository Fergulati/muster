import QtQuick

// The gallery (exo-720.2): the real Main.qml, rendered against FakeBackend with a
// fixture's PROPs, then screenshot. No module, no network, no runner: the same Qt and
// design system the runner ships (scripts/ui-screenshot.sh puts them on the path).
//
// Arguments after `--`: <fixture.json> <out-prefix> <width> <height>
// A fixture is JSON:
//   { "about": "...",
//     "snapshot": "data/<file>.json",   // optional: PROPs recorded from a real run
//     "load": "Components.qml",          // optional: a page in ui/tests/gallery/ instead of Main.qml
//     "sizes": ["800x700"],              // optional: these sizes instead of the script's
//     "props": { "<PROP>": <string, or any JSON value, which is stringified> },
//     "steps": [ {"view": "room"}, {"set": ["<objectName>", "<prop>", <value>]},
//                {"click": "<objectName>"}, {"props": {...}}, {"wait": 300},
//                {"shot": "<suffix>"} ] }
// With no steps: show the snapshot's recorded view (else home) and shoot once.
// Each shot is <out-prefix>[-<suffix>].png. Prints GALLERY-SHOT / GALLERY-ERROR /
// GALLERY-DONE lines; the script reads them.
Item {
    id: gallery

    readonly property var argv: {
        var a = Qt.application.arguments, i = a.indexOf("--");
        return i < 0 ? [] : a.slice(i + 1);
    }
    readonly property string fixturePath: argv[0] || ""
    readonly property string outPrefix: argv[1] || "gallery"
    width: parseInt(argv[2] || "1440")
    height: parseInt(argv[3] || "900")

    FakeBackend { id: fake }

    // what Main.qml reads off the host's `logos` context object
    property QtObject logos: QtObject {
        signal viewModuleReadyChanged(string moduleName, bool isReady)
        function module(name) { return fake; }
        function isViewModuleReady(name) { return true; }
        function request(capability, params, callback) { fake.record("logos.request", [capability, params]); }
    }

    Rectangle { anchors.fill: parent; color: "#000000" }
    Loader { id: app; anchors.fill: parent; active: false; source: Qt.resolvedUrl("../../src/qml/Main.qml") }

    property var steps: []
    property int stepAt: 0
    property var fixtureDir: ""

    function fail(msg) { console.log("GALLERY-ERROR " + msg); Qt.exit(1); }

    function readJson(url) {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", url, false);
        xhr.send();
        if (xhr.status !== 200 && xhr.status !== 0) throw new Error("cannot read " + url);
        return JSON.parse(xhr.responseText);
    }

    function applyProps(props) {
        for (var k in props) {
            if (!(k in fake) || k === "calls" || k === "contractProps") { fail("not a contract PROP: " + k); return; }
            var v = props[k];
            fake[k] = (typeof v === "string") ? v : JSON.stringify(v);
        }
    }

    function find(item, name) {
        if (!item) return null;
        if (item.objectName === name) return item;
        var kids = item.children || [];
        for (var i = 0; i < kids.length; ++i) {
            var hit = find(kids[i], name);
            if (hit) return hit;
        }
        return null;
    }

    function shoot(suffix) {
        var path = outPrefix + (suffix ? "-" + suffix : "") + ".png";
        // the gallery item itself (a window's contentItem has no engine to grab with); the
        // UI uses no Popup today, so nothing lives on the overlay outside it
        gallery.grabToImage(function (r) {
            if (!r.saveToFile(path)) { fail("cannot write " + path); return; }
            console.log("GALLERY-SHOT " + path);
            next();
        });
    }

    function run(step) {
        if (step.view !== undefined) { app.item.view = step.view; return true; }
        if (step.props !== undefined) { applyProps(step.props); return true; }
        if (step.set !== undefined) {
            var t = find(app.item, step.set[0]);
            if (!t) { fail("no object named " + step.set[0]); return false; }
            t[step.set[1]] = step.set[2];
            return true;
        }
        if (step.click !== undefined) {
            var b = find(app.item, step.click);
            if (!b) { fail("no object named " + step.click); return false; }
            b.clicked();
            return true;
        }
        if (step.wait !== undefined) { pause.interval = step.wait; pause.start(); return false; }
        if (step.shot !== undefined) { settle.start(); return false; }
        fail("unknown step " + JSON.stringify(step));
        return false;
    }

    function next() {
        while (stepAt < steps.length) {
            var step = steps[stepAt++];
            if (step.shot !== undefined) { pendingShot = String(step.shot); settle.start(); return; }
            if (!run(step)) return;
        }
        console.log("GALLERY-DONE");
        Qt.exit(0);
    }
    property string pendingShot: ""

    // a shot waits for bindings and layouts to settle (and the software renderer to draw)
    Timer { id: settle; interval: 600; onTriggered: gallery.shoot(gallery.pendingShot) }
    Timer { id: pause; onTriggered: gallery.next() }

    Component.onCompleted: {
        if (!fixturePath) { fail("usage: qml Gallery.qml -- <fixture.json> <out-prefix> <w> <h>"); return; }
        try {
            var url = Qt.resolvedUrl("file://" + fixturePath);
            var fx = readJson(url);
            var view = "home";
            if (fx.snapshot) {
                var snap = readJson(Qt.resolvedUrl(url.toString().replace(/[^\/]*$/, "") + fx.snapshot));
                applyProps(snap.props || {});
                if (snap.ui && snap.ui.view) view = snap.ui.view;
            }
            applyProps(fx.props || {});
            if (fx.load) { app.source = Qt.resolvedUrl(fx.load); if (!fx.steps) view = ""; }
            steps = fx.steps || (view ? [{ view: view }, { shot: "" }] : [{ shot: "" }]);
        } catch (e) { fail(String(e)); return; }
        app.active = true;
        if (app.status === Loader.Error || !app.item) { fail("Main.qml did not load"); return; }
        next();
    }
}
