import QtQuick
import QtQuick.Controls

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
//                {"shot": "<suffix>"},
//                {"expect": {"slot": "<SLOT>", "args": [...]}}   // the UI made this module call
//                                       //   (an arg "~text" matches any argument containing it)
//                {"expectProp": ["<objectName>", "<prop>", <value>]}   // "~s" contains s, "!s" lacks it
//                {"expectMax": ["<objectName>", "<prop>", <number>]}   // a size that must not exceed
//                {"emit": ["<objectName>", "<signal>"]}         // e.g. a MenuItem's triggered
//                {"dumpCalls": true} ] }                        // print every call (GALLERY-CALLS)
// A failed expectation is a GALLERY-ERROR: the fixture fails. Arguments after the size:
// an optional path to another Main.qml (an older tree's), to compare what the UI asks.
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
    Loader { id: app; anchors.fill: parent; active: false
             source: argv[4] ? Qt.resolvedUrl("file://" + argv[4]) : Qt.resolvedUrl("../../src/qml/Main.qml") }

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

    // by objectName, through visual children and `data` (where a Popup lives), and into a
    // Popup's contentItem (reparented to the window's overlay, so no `children` reach it)
    function find(item, name, seen) {
        if (!item) return null;
        seen = seen || [];
        if (seen.indexOf(item) >= 0) return null;
        seen.push(item);
        if (item.objectName === name) return item;
        var kids = item.data || item.children || [];
        for (var i = 0; i < kids.length; ++i) {
            var hit = find(kids[i], name, seen);
            if (hit) return hit;
        }
        if (item.contentItem && item.contentItem !== item) return find(item.contentItem, name, seen);
        return null;
    }

    // a Popup lives on the window's overlay, outside this item, and a window's contentItem
    // cannot be grabbed from QML; while one is open the script captures the X display
    // instead (GALLERY-XSHOT), and the shot waits for that file to appear
    function popupOpen() {
        var ov = gallery.Overlay.overlay;
        if (!ov) return false;
        for (var i = 0; i < ov.children.length; ++i)
            if (ov.children[i].visible && ov.children[i].width > 0 && ov.children[i].height > 0) return true;
        return false;
    }
    function fileThere(path) {
        try {
            var xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("file://" + path), false);
            xhr.send();
            return (xhr.status === 200 || xhr.status === 0) && xhr.responseText.length > 0;
        } catch (e) { return false; }
    }
    Timer {
        id: xwait
        property string path: ""
        property int tries: 0
        interval: 100; repeat: true
        onTriggered: {
            if (gallery.fileThere(xwait.path)) {
                xwait.stop();
                console.log("GALLERY-SHOT " + xwait.path);
                gallery.next();
            } else if (++xwait.tries > 100) { xwait.stop(); gallery.fail("no X capture for " + xwait.path); }
        }
    }

    function shoot(suffix) {
        var path = outPrefix + (suffix ? "-" + suffix : "") + ".png";
        if (gallery.popupOpen()) {
            console.log("GALLERY-XSHOT " + path);
            xwait.path = path; xwait.tries = 0; xwait.start();
            return;
        }
        // the gallery item itself (a window's contentItem has no engine to grab with)
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
        if (step.emit !== undefined) {     // a signal other than clicked (a MenuItem's triggered)
            var e = find(app.item, step.emit[0]);
            if (!e) { fail("no object named " + step.emit[0]); return false; }
            e[step.emit[1]]();
            return true;
        }
        if (step.expect !== undefined) {
            var want = step.expect, args = want.args || [];
            var hit = fake.calls.some(function (c) {
                if (c.slot !== want.slot) return false;
                for (var a = 0; a < args.length; ++a) {
                    var got = String(c.args[a]), exp = String(args[a]);
                    if (exp.charAt(0) === "~" ? got.indexOf(exp.slice(1)) < 0 : got !== exp) return false;
                }
                return true;
            });
            if (!hit) { fail("expected the call " + JSON.stringify(want) + "; the UI made " + JSON.stringify(fake.calls.map(function (c) { return c.slot; }))); return false; }
            console.log("GALLERY-PASS " + JSON.stringify(want));
            return true;
        }
        if (step.expectProp !== undefined) {
            var o = find(app.item, step.expectProp[0]);
            if (!o) { fail("no object named " + step.expectProp[0]); return false; }
            var v = o[step.expectProp[1]], want2 = step.expectProp[2];
            var ok = (typeof want2 === "string" && want2.charAt(0) === "~") ? String(v).indexOf(want2.slice(1)) >= 0
                   : (typeof want2 === "string" && want2.charAt(0) === "!") ? String(v).indexOf(want2.slice(1)) < 0
                   : JSON.stringify(v) === JSON.stringify(want2);
            if (!ok) { fail(step.expectProp.join(".") + " is " + JSON.stringify(v)); return false; }
            console.log("GALLERY-PASS " + JSON.stringify(step.expectProp));
            return true;
        }
        if (step.expectMax !== undefined) {
            var om = find(app.item, step.expectMax[0]);
            if (!om) { fail("no object named " + step.expectMax[0]); return false; }
            var vm = Number(om[step.expectMax[1]]);
            if (!(vm <= step.expectMax[2])) { fail(step.expectMax.join(".") + " is " + vm); return false; }
            console.log("GALLERY-PASS " + JSON.stringify(step.expectMax));
            return true;
        }
        if (step.dumpCalls !== undefined) {
            console.log("GALLERY-CALLS " + JSON.stringify(fake.calls));
            return true;
        }
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
