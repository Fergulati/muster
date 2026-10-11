import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes

import Logos.Theme
import Logos.Controls
import Logos.Icons

// The room map (epic exo-dde, docs/design/room-map.md; mock ui/prototype/room-map.html):
// the room drawn as a graph from coordinate_graph — members inside the room's boundary,
// the outside observers around it, what left drawn crossing it, and every log entry this
// device holds. It computes no state: each node and edge carries the log position it
// appears at, and the timeline replays the room by showing those at or before it.
//
// Self-contained on purpose, so it can move to its own UI module later: it reads only
// `graph` (coordinate_graph), `intents` (coordinate_intents, for words) and `members`
// (coordinate_members, for names), and says what it wants through two signals.
//
// Positions come from roles, never from a random simulation, so the same log draws the
// same picture on every device and nothing jumps while the timeline moves. Colours keep
// the room's language: blue is what left the room (U-2), a member's colour comes from
// their id (MusterStyle.colorFor), and the store node is always drawn (FS-9).
Rectangle {
    id: map
    objectName: "roomMap"

    property var graph: ({})
    property var intents: []
    property var members: []
    property string lens: "room"          // room · me · leaks · prov · log
    property string focusIntent: ""       // the Provenance lens's intent ("" = the latest)
    property string selected: ""
    property int k: seqMax                // the replay position
    property bool following: true         // k follows the end of the log as it grows
    signal openCard(string intentId)
    signal closeRequested()

    // The replay runs in causal order: each node's seq is its place in log.causalOrder,
    // the order members published in (the `after` each stamped, exo-655), concurrent
    // entries tied by content id. Entries from clients before causal order carry no
    // `after` and fall back to content-id order among themselves. `rankOf[seq]` is an
    // entry's place among the entries; k is that rank.
    readonly property var replayOrder: {
        var es = [];
        var ns = graph && graph.nodes ? graph.nodes : [];
        for (var i = 0; i < ns.length; i++) if (ns[i].kind === "entry") es.push(ns[i]);
        es.sort(function (a, b) { return a.seq - b.seq; });
        return es;
    }
    readonly property var rankOf: {
        var m = {};
        for (var i = 0; i < replayOrder.length; i++) m[replayOrder[i].seq] = i;
        return m;
    }
    function rank(seq) { return seq < 0 ? -1 : (rankOf[seq] !== undefined ? rankOf[seq] : seq); }
    readonly property int seqMax: replayOrder.length - 1
    readonly property string viewer: graph && graph.viewer ? String(graph.viewer) : ""
    readonly property int readFrom: graph && graph.readFrom !== undefined ? Number(graph.readFrom) : 0
    onSeqMaxChanged: if (following || k > seqMax) k = seqMax

    color: Theme.palette.background

    // ── words ───────────────────────────────────────────────────────────────
    function shortId(s) { s = String(s || ""); return s.length > 12 ? s.slice(0, 6) + "…" + s.slice(-4) : s; }
    function memberName(id) {
        var hex = String(id || "").replace(/^m:/, "");
        for (var i = 0; i < map.members.length; i++) {
            var m = map.members[i];
            if (String(m.identity || "").toLowerCase() === hex) {
                if (m.self) return qsTr("You");
                if (String(m.alias || "").length > 0) return String(m.alias);
            }
        }
        if (hex === map.viewer) return qsTr("You");
        return shortId(hex);
    }
    function intentOf(id) {
        for (var i = 0; i < map.intents.length; i++)
            if (String(map.intents[i].id) === id) return map.intents[i];
        return null;
    }
    function intentWord(id) {
        var it = intentOf(id);
        var k = it && it.summary ? String(it.summary.kind || "") : "";
        var words = { "split": qsTr("Split"), "settle-up": qsTr("Settle up"), "payment": qsTr("Payment"),
                      "transfer": qsTr("Payment"), "statement": qsTr("Statement"), "action": qsTr("Action"),
                      "btc-spend": qsTr("Bitcoin payment"), "lez-call": qsTr("LEZ call") };
        if (words[k]) return words[k];
        return k.length > 0 ? k.charAt(0).toUpperCase() + k.slice(1) : qsTr("Proposal");
    }
    // A proposal's state and approvals as of the replay point: the graph carries each
    // intent's state after each of its entries (the fold over the causal prefix).
    function stepAt(n) {
        var a = n.attrs || {}, st = a.steps || [], cur = null;
        for (var i = 0; i < st.length; i++) if (rank(Number(st[i].seq)) <= map.k) cur = st[i];
        return cur ? cur : { state: String(a.state || ""), approvals: Number(a.approvals || 0) };
    }
    function stateWords(n) {
        var a = n.attrs || {};
        var now = stepAt(n);
        var s = String(now.state || "");
        if (s === "final") return qsTr("Final");
        if (s === "submitted") return qsTr("Submitted");
        if (s === "settling") return qsTr("Settling");
        if (s === "executable") return qsTr("Agreed");
        return qsTr("%1 of %2 agreed").arg(Number(now.approvals || 0)).arg(Number(a.threshold || 0));
    }
    function stateTone(n) {
        var s = String(stepAt(n).state || "");
        return s === "final" || s === "executable" ? "settled" : s === "submitted" || s === "settling" ? "warning" : "waiting";
    }
    readonly property var observerWords: ({
        "o:store-node": [qsTr("Store node"), qsTr("keeps every envelope"),
            qsTr("Every entry reaches the room as a sealed envelope on one topic. The store node keeps them, so it sees when each arrived and which topic it belongs to. It holds no epoch key and cannot open one (FS-9).")],
        "o:rpc-provider": [qsTr("RPC provider"), qsTr("each sender's own endpoint"),
            qsTr("The endpoint a member sends through sees that member's signed transaction before the mempool does, and the address it came from. Each member chooses their own (invariant 8).")],
        "o:chain-observer": [qsTr("Chain observer"), qsTr("anyone reading the chain"),
            qsTr("Anyone reading the public ledger. It learns what the driver's manifest declares when the room settles, never before: nothing leaves at propose or approve.")],
        "o:target-module": [qsTr("Target module"), qsTr("the module a call reaches"),
            qsTr("The Logos module an action calls. It sees the call's arguments when the room executes it.")],
        "o:outside": [qsTr("Outside sources"), qsTr("what the room took in"),
            qsTr("Reads the room took in: a chain's answer, a nonce, a rate, a creditor's own check of a payment. Each is recorded as an external read, so its origin is accountable. It is not proof the world agrees (F-10).")]
    })
    function obsWord(id, i) { var w = map.observerWords[id]; return w ? w[i] : id.replace(/^o:/, ""); }
    readonly property var kindWords: ({
        "message": qsTr("message"), "propose": qsTr("proposal"), "policy": qsTr("policy"), "context": qsTr("context"),
        "read": qsTr("outside read"), "sig": qsTr("approval"), "attest": qsTr("commitment"), "binding": qsTr("key binding"),
        "decline": qsTr("decline"), "submit": qsTr("submitted"), "final": qsTr("final"), "admit": qsTr("admission"),
        "material": qsTr("shared material"), "proposer": qsTr("proposer"), "account": qsTr("account"),
        "part-settled": qsTr("paid a part"), "part-confirmed": qsTr("confirmed a part"), "join": qsTr("ceremony join"),
        "open": qsTr("ceremony"), "pmsg1": qsTr("ceremony step"), "pmsg2": qsTr("ceremony step")
    })
    function kindWord(k) { return map.kindWords[k] || String(k || ""); }
    function basisWords(b) {
        return b === "author-signed" ? qsTr("Signed by its author, bound to this room")
             : b === "driver-verified" ? qsTr("Checked by the driver: the signature recovers to a configured signer")
             : b === "key-signed" ? qsTr("Signed by the approving key")
             : qsTr("Sealed to the room; it names no author");
    }
    function clsColor(c) {
        return c === "driver-contribution" ? MusterStyle.settled
             : c === "external-read" ? Theme.palette.textSecondary
             : c === "plugin-block" ? Theme.colors.peach100
             : Theme.palette.textTertiary;
    }

    // ── the graph, as far as the timeline has replayed it ────────────────────
    readonly property var allNodes: graph && graph.nodes ? graph.nodes : []
    readonly property var epochBands: {
        var out = [], eps = graph && graph.epochs ? graph.epochs : [];
        for (var i = 0; i < replayOrder.length; i++) {
            var ep = replayOrder[i].epoch;
            if (out.length > 0 && out[out.length - 1].epoch === ep) continue;
            var who = "";
            for (var j = 0; j < eps.length; j++) if (Number(eps[j].epoch) === ep) who = String(eps[j].admitted || "");
            out.push({ epoch: ep, fromRank: i, admitted: who });
        }
        return out;
    }
    readonly property var allEdges: graph && graph.edges ? graph.edges : []
    readonly property var nodeById: {
        var m = {};
        for (var i = 0; i < allNodes.length; i++) m[allNodes[i].id] = allNodes[i];
        return m;
    }
    // stable orders, over the WHOLE graph, so a position never depends on k
    function idsOfKind(kind) {
        var out = [];
        for (var i = 0; i < allNodes.length; i++) if (allNodes[i].kind === kind) out.push(allNodes[i].id);
        return out;
    }
    readonly property var memberIds: {
        var ids = idsOfKind("member");
        var v = "m:" + viewer;
        var i = ids.indexOf(v);
        if (i > 0) { ids.splice(i, 1); ids.unshift(v); }
        return ids;
    }
    readonly property var intentIds: idsOfKind("intent")
    readonly property var provIntent: {
        if (focusIntent.length > 0 && nodeById["i:" + focusIntent]) return focusIntent;
        for (var i = intentIds.length - 1; i >= 0; i--)
            if (shownAt(nodeById[intentIds[i]])) return intentIds[i].slice(2);
        return "";
    }
    function shownAt(n) { return rank(n.seq) <= map.k; }
    readonly property var visibleNodes: {
        var out = [];
        for (var i = 0; i < allNodes.length; i++) {
            var n = allNodes[i];
            if (!shownAt(n)) continue;
            if (lens === "log") { if (n.kind === "entry") out.push(n); continue; }
            if (lens === "prov") {
                if (n.id === "i:" + provIntent) out.push(n);
                else if (n.kind === "entry" && String((n.attrs || {}).intent || "") === provIntent
                         && provRole(n) !== "") out.push(n);
                continue;
            }
            if (n.kind === "entry") continue;
            out.push(n);
        }
        if (readFrom > 0 && (lens === "room" || lens === "me" || lens === "leaks"))
            out.push({ id: "sealed", kind: "sealed", seq: -1, epoch: readFrom - 1, attrs: {} });
        if (lens === "prov" && provIntent.length > 0)
            out.push({ id: "bytes", kind: "bytes", seq: -1, epoch: 0, attrs: {} });
        return out;
    }
    readonly property var visibleIds: {
        var m = {};
        for (var i = 0; i < visibleNodes.length; i++) m[visibleNodes[i].id] = true;
        return m;
    }
    function provRole(n) {
        var kd = String((n.attrs || {}).kind || "");
        if (kd === "propose" || kd === "policy" || kd === "context" || kd === "read") return "input";
        if (kd === "sig" || kd === "attest") return "approval";
        if (kd === "submit" || kd === "final" || kd === "part-settled" || kd === "part-confirmed") return "outcome";
        return "";
    }
    readonly property var roomEdgeKinds: ["proposed", "approved", "declined", "part", "disclosed", "joined", "bound", "leaves", "enters"]
    readonly property var visibleEdges: {
        var out = [];
        if (lens === "prov") {
            // the provenance lens draws the same facts through the signed bytes: each input
            // reaches them, each approval is over them, each outcome follows the intent
            for (var j = 0; j < visibleNodes.length; j++) {
                var n = visibleNodes[j];
                if (n.kind !== "entry") continue;
                var role = provRole(n);
                if (role === "input") out.push({ src: n.id, dst: "bytes", kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                else if (role === "approval") {
                    out.push({ src: "bytes", dst: n.id, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                    out.push({ src: n.id, dst: "i:" + provIntent, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls } });
                } else if (role === "outcome")
                    out.push({ src: "i:" + provIntent, dst: n.id, kind: "prov", seq: n.seq, attrs: { cls: n.attrs.cls, out: true } });
            }
            return out;
        }
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (rank(e.seq) > k || !visibleIds[e.src] || !visibleIds[e.dst]) continue;
            if (lens === "log") { if (e.kind === "parent") out.push(e); continue; }
            if (roomEdgeKinds.indexOf(e.kind) >= 0) out.push(e);
        }
        return out;
    }
    // what each outside observer learned, up to k
    function learned(obsId) {
        var fs = [];
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (e.kind !== "leaves" || e.dst !== obsId || rank(e.seq) > k) continue;
            var f = (e.attrs && e.attrs.fields) || [];
            for (var j = 0; j < f.length; j++) if (fs.indexOf(f[j]) < 0) fs.push(f[j]);
        }
        return fs;
    }
    readonly property int heldCount: {
        var c = 0;
        return Math.max(0, Math.min(k + 1, replayOrder.length));
    }

    // ── the Me lens: this device's member, its keys, what it did, what of it left ─
    readonly property var mine: {
        var me = "m:" + viewer, keep = {}, keepE = {};
        keep[me] = true;
        for (var i = 0; i < allEdges.length; i++) {
            var e = allEdges[i];
            if (e.src === me) { keep[e.dst] = true; keepE[i] = true; }
        }
        for (var j = 0; j < allEdges.length; j++) {     // my keys' approvals; what left of mine
            var f = allEdges[j];
            if (keep[f.src] && String(f.src).indexOf("k:") === 0) { keep[f.dst] = true; keepE[j] = true; }
        }
        for (var h = 0; h < allEdges.length; h++) {
            var g = allEdges[h];
            if (g.kind === "leaves" && keep[g.src]) { keep[g.dst] = true; keepE[h] = true; }
        }
        return { nodes: keep };
    }
    function dimmed(id) {
        if (hovered.length > 0) return !(id === hovered || neighbours[id]);
        if (lens === "me") return !mine.nodes[id];
        return false;
    }
    property string hovered: ""
    readonly property var neighbours: {
        var m = {};
        if (hovered.length === 0) return m;
        for (var i = 0; i < visibleEdges.length; i++) {
            var e = visibleEdges[i];
            if (e.src === hovered) m[e.dst] = true;
            if (e.dst === hovered) m[e.src] = true;
        }
        return m;
    }

    // ── layout: deterministic, from roles, in a 1000 × 680 stage ─────────────
    readonly property real cx: lens === "leaks" ? 300 : 470
    readonly property real cy: lens === "leaks" ? 345 : 340
    readonly property real ringR: lens === "leaks" ? 205 : 232
    function polar(deg, r, ox, oy) {
        var a = deg * Math.PI / 180;
        return { x: ox + r * Math.sin(a), y: oy - r * Math.cos(a) };
    }
    function computeLayout() {
        var pos = {}, i, n;
        if (lens === "log") {
            var lanes = { "": 150 }, li = intentIds.length;
            var dy = li > 0 ? Math.min(110, 400 / li) : 0;
            for (i = 0; i < li; i++) lanes[intentIds[i].slice(2)] = 270 + i * dy;
            var span = Math.max(1, seqMax);
            for (i = 0; i < visibleNodes.length; i++) {
                n = visibleNodes[i];
                var kd = String((n.attrs || {}).kind || "");
                var lane = lanes[String((n.attrs || {}).intent || "")];
                if (lane === undefined) lane = 150;
                var drop = (kd === "attest" || kd === "part-confirmed" || kd === "binding") ? 26 : 0;
                pos[n.id] = { x: 60 + rank(n.seq) * 890 / span, y: lane + drop };
            }
            return pos;
        }
        if (lens === "prov") {
            var cols = { input: [], approval: [], outcome: [] };
            for (i = 0; i < visibleNodes.length; i++) {
                n = visibleNodes[i];
                if (n.kind === "entry") cols[provRole(n)].push(n.id);
            }
            function column(ids, x, y0, y1) {
                for (var j = 0; j < ids.length; j++)
                    pos[ids[j]] = { x: x, y: ids.length === 1 ? (y0 + y1) / 2 : y0 + j * (y1 - y0) / (ids.length - 1) };
            }
            column(cols.input, 130, 150, 540);
            pos["bytes"] = { x: 360, y: 340 };
            column(cols.approval, 580, 100, 590);
            pos["i:" + provIntent] = { x: 810, y: cols.outcome.length > 0 ? 250 : 340 };
            column(cols.outcome, 810, 450, 610);
            return pos;
        }
        // room · me · leaks: members on a ring inside the boundary, this device first
        var nm = memberIds.length, scale = lens === "leaks" ? 0.86 : 1;
        for (i = 0; i < nm; i++) pos[memberIds[i]] = polar(230 + i * 360 / Math.max(1, nm), 185 * scale, cx, cy);
        // intents in the middle, on a sunflower spiral: adding one never moves another
        for (i = 0; i < intentIds.length; i++) {
            var r = Math.min(120, 46 * Math.sqrt(i + (intentIds.length > 1 ? 0.6 : 0))) * scale;
            pos[intentIds[i]] = polar(i * 137.5 + 300, r, cx, cy);
        }
        var accIdx = 0, keyIdx = {}, cerIdx = 0;
        for (i = 0; i < allNodes.length; i++) {
            n = allNodes[i];
            if (n.kind === "account" || n.kind === "signer" || n.kind === "ceremony") {
                var anchor = null, onIntent = false;
                for (var e = 0; e < allEdges.length; e++) {
                    var ed = allEdges[e];
                    if (n.kind === "account" && ed.kind === "disclosed" && ed.dst === n.id) { anchor = pos[ed.src]; break; }
                    if (n.kind === "signer" && ed.kind === "bound" && ed.dst === n.id) { anchor = pos[ed.src]; break; }
                    if (n.kind === "signer" && ed.kind === "approved" && ed.src === n.id && !anchor) { anchor = pos[ed.dst]; onIntent = true; }
                }
                if (n.kind === "ceremony") {
                    pos[n.id] = polar(180 + (cerIdx++) * 34, 130 * scale, cx, cy);
                } else if (anchor && onIntent) {
                    var kk = "ring" + String(anchor.x) + String(anchor.y);
                    var nn = keyIdx[kk] = (keyIdx[kk] || 0) + 1;
                    pos[n.id] = map.polar(200 + nn * 40, 66 * scale, anchor.x, anchor.y);
                } else if (anchor) {
                    var dx = anchor.x - cx, dyy = anchor.y - cy;
                    var key = n.kind + String(anchor.x) + String(anchor.y);
                    var nth = keyIdx[key] = (keyIdx[key] || 0) + 1;
                    var f = n.kind === "account" ? 0.55 : 1.18;
                    var ang = Math.atan2(dyy, dx) + (nth - 1) * 0.32 * (nth % 2 ? 1 : -1);
                    var rr = Math.sqrt(dx * dx + dyy * dyy) * f;
                    pos[n.id] = { x: cx + rr * Math.cos(ang), y: cy + rr * Math.sin(ang) };
                } else {
                    pos[n.id] = polar(20 + (accIdx++) * 30, 150 * scale, cx, cy);
                }
            }
        }
        pos["sealed"] = polar(165, 150 * scale, cx, cy);
        if (lens === "leaks") {
            var obs = ["o:store-node", "o:rpc-provider", "o:chain-observer", "o:target-module", "o:outside"], row = 0;
            for (i = 0; i < obs.length; i++) if (nodeById[obs[i]]) pos[obs[i]] = { x: 790, y: 90 + (row++) * 135 };
        } else {
            pos["o:store-node"] = { x: 470, y: 42 };
            pos["o:rpc-provider"] = { x: 875, y: 230 };
            pos["o:chain-observer"] = { x: 875, y: 450 };
            pos["o:target-module"] = { x: 80, y: 230 };
            pos["o:outside"] = { x: 860, y: 625 };
        }
        // entries out of view sit on their intent, so they open out of it in the Log lens
        for (i = 0; i < allNodes.length; i++) {
            n = allNodes[i];
            if (n.kind === "entry" && !pos[n.id]) {
                var at = pos["i:" + String((n.attrs || {}).intent || "")];
                pos[n.id] = at ? at : { x: cx, y: cy };
            }
        }
        return pos;
    }
    property var fromPos: ({})
    property var toPos: ({})
    property real t: 1
    function posOf(id) {
        var tt = map.t, b = map.toPos[id], a = map.fromPos[id] || b;
        if (!b) return { x: map.cx, y: map.cy };
        return { x: a.x + (b.x - a.x) * tt, y: a.y + (b.y - a.y) * tt };
    }
    function relayout() {
        var cur = {}, ids = Object.keys(map.toPos);
        for (var i = 0; i < ids.length; i++) cur[ids[i]] = posOf(ids[i]);
        map.fromPos = cur;
        map.toPos = computeLayout();
        tween.restart();
    }
    NumberAnimation { id: tween; target: map; property: "t"; from: 0; to: 1; duration: 520; easing.type: Easing.OutCubic }
    onVisibleNodesChanged: relayoutLater.restart()
    Timer { id: relayoutLater; interval: 0; onTriggered: map.relayout() }
    Component.onCompleted: { map.toPos = computeLayout(); map.fromPos = map.toPos; }

    property real flowPhase
    NumberAnimation on flowPhase { from: 0; to: -20; duration: 1100; loops: Animation.Infinite; running: map.visible }

    // ── header ──────────────────────────────────────────────────────────────
    RowLayout {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.spacing.medium }
        spacing: Theme.spacing.medium
        ColumnLayout {
            spacing: 2
            LogosText {
                text: qsTr("Room map")
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
            LogosText {
                text: qsTr("%n entries you can open", "", map.replayOrder.length)
                      + (map.readFrom > 0 ? qsTr(" · from epoch %1, when you joined").arg(map.readFrom) : "")
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
        }
        Item { Layout.fillWidth: true }
        Repeater {
            model: [["room", qsTr("Room")], ["me", qsTr("Me")], ["leaks", qsTr("Where it left")],
                    ["prov", qsTr("Provenance")], ["log", qsTr("Log")]]
            delegate: ActionButton {
                required property var modelData
                objectName: "roomMapLens_" + modelData[0]
                compact: true
                quiet: map.lens !== modelData[0]
                text: modelData[1]
                onClicked: map.lens = modelData[0]
            }
        }
        IconAction {
            objectName: "roomMapClose"
            label: qsTr("Close the room map")
            icon: LogosIcons.close
            onClicked: map.closeRequested()
        }
    }

    // ── the stage ───────────────────────────────────────────────────────────
    Item {
        id: viewport
        anchors { left: parent.left; right: inspector.left; top: header.bottom; bottom: timeline.top; margins: Theme.spacing.small }
        clip: true
        MouseArea { anchors.fill: parent; onClicked: map.selected = "" }

        Item {
            id: stage
            width: 1000; height: 680
            anchors.centerIn: parent
            scale: Math.min(viewport.width / 1000, viewport.height / 680)

            // the room's boundary: the conversation is the security boundary
            Shape {
                id: membrane
                anchors.fill: parent
                opacity: (map.lens === "room" || map.lens === "me" || map.lens === "leaks") ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 300 } }
                ShapePath {
                    strokeColor: MusterStyle.tint(Theme.palette.primary, 0.45)
                    strokeWidth: 1.5
                    fillGradient: RadialGradient {
                        centerX: map.cx; centerY: map.cy; centerRadius: map.ringR
                        focalX: map.cx; focalY: map.cy
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 0.8; color: MusterStyle.tint(Theme.palette.primary, 0.05) }
                        GradientStop { position: 1.0; color: MusterStyle.tint(Theme.palette.primary, 0.13) }
                    }
                    PathAngleArc { centerX: map.cx; centerY: map.cy; radiusX: map.ringR; radiusY: map.ringR; startAngle: 0; sweepAngle: 360 }
                }
            }
            LogosText {
                visible: membrane.opacity > 0.5
                x: map.cx - width / 2
                y: map.cy - map.ringR - height - 4
                text: qsTr("the room · end-to-end · %n can read", "", map.memberIds.length)
                color: Theme.palette.textTertiary
                font.pixelSize: MusterStyle.badge
                font.family: MusterStyle.mono
            }
            // every envelope reaches the store node (FS-9): strands from the boundary
            Repeater {
                model: (membrane.opacity > 0.5 && map.visibleIds["o:store-node"]) ? [-2, -1, 0, 1, 2] : []
                delegate: Shape {
                    required property int modelData
                    anchors.fill: parent
                    readonly property var a: map.polar(modelData * 14, map.ringR, map.cx, map.cy)
                    readonly property var b: map.posOf("o:store-node")
                    ShapePath {
                        strokeColor: MusterStyle.tint(Theme.palette.warning, 0.4)
                        strokeWidth: Math.max(0.6, Math.log(map.heldCount + 1) * 0.5)
                        fillColor: "transparent"
                        startX: a.x; startY: a.y
                        PathCubic { x: b.x + modelData * 6; y: b.y + 22; control1X: a.x; control1Y: a.y - 40; control2X: b.x + modelData * 6; control2Y: b.y + 60 }
                    }
                }
            }
            // epoch bands behind the Log lens
            Repeater {
                model: map.lens === "log" ? map.epochBands : []
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property real x0: 60 + Number(modelData.fromRank) * 890 / Math.max(1, map.seqMax) - 12
                    x: x0; y: 70; width: 1000 - x0; height: 560
                    Rectangle { anchors.fill: parent; color: index % 2 ? MusterStyle.neutralSoft : "transparent"; opacity: 0.5 }
                    Rectangle { width: 1; height: parent.height; color: Theme.palette.borderSubtle }
                    LogosText {
                        x: 8; y: 6 + (index % 2) * 14
                        text: String(modelData.admitted || "").length === 0 ? qsTr("epoch %1").arg(modelData.epoch)
                                          : qsTr("epoch %1 · %2 admitted").arg(modelData.epoch).arg(map.memberName(modelData.admitted))
                        color: Theme.palette.textTertiary
                        font.pixelSize: MusterStyle.badge
                        font.family: MusterStyle.mono
                    }
                }
            }

            // edges
            Repeater {
                model: map.visibleEdges
                delegate: Shape {
                    id: edge
                    required property var modelData
                    anchors.fill: parent
                    readonly property string kind: modelData.kind
                    readonly property var a: map.posOf(modelData.src)
                    readonly property var b: map.posOf(modelData.dst)
                    readonly property real len: Math.max(1, Math.hypot(b.x - a.x, b.y - a.y))
                    readonly property real ra: map.radiusOf(modelData.src) + 3
                    readonly property real rb: map.radiusOf(modelData.dst) + 3
                    readonly property real sx: a.x + (b.x - a.x) * ra / len
                    readonly property real sy: a.y + (b.y - a.y) * ra / len
                    readonly property real tx: b.x - (b.x - a.x) * rb / len
                    readonly property real ty: b.y - (b.y - a.y) * rb / len
                    readonly property real bend: kind === "prov" ? 0 : kind === "parent" ? 0.12 : 0.13
                    readonly property bool hot: map.hovered.length > 0 && (modelData.src === map.hovered || modelData.dst === map.hovered)
                    opacity: map.hovered.length > 0 ? (hot ? 1 : 0.08)
                           : (map.lens === "me" && (map.dimmed(modelData.src) || map.dimmed(modelData.dst))) ? 0.08 : 1
                    readonly property color ink: kind === "leaves" ? MusterStyle.info
                        : kind === "enters" ? Theme.palette.textSecondary
                        : kind === "parent" ? Theme.palette.textTertiary
                        : kind === "prov" ? (modelData.attrs && modelData.attrs.out ? MusterStyle.info : map.clsColor(modelData.attrs ? modelData.attrs.cls : ""))
                        : kind === "bound" ? Theme.palette.text
                        : (String(modelData.src).indexOf("m:") === 0 ? MusterStyle.colorFor(String(modelData.src).slice(2)) : Theme.palette.textSecondary)
                    ShapePath {
                        strokeColor: edge.ink
                        strokeWidth: edge.kind === "leaves" ? 1.6 + Math.min(4, ((edge.modelData.attrs && edge.modelData.attrs.fields) || []).length * 0.35)
                                   : edge.kind === "parent" ? 1 : edge.kind === "approved" || edge.kind === "part" ? 1.2 : 1.6
                        strokeStyle: (edge.kind === "leaves" || edge.kind === "enters" || edge.kind === "disclosed" || edge.kind === "bound")
                                     ? ShapePath.DashLine : ShapePath.SolidLine
                        dashPattern: edge.kind === "leaves" ? [1.5, 3.5] : edge.kind === "enters" ? [3, 2.5] : [0.8, 2.5]
                        dashOffset: edge.kind === "leaves" ? map.flowPhase / 2 : edge.kind === "enters" ? map.flowPhase / 3 : 0
                        capStyle: ShapePath.RoundCap
                        fillColor: "transparent"
                        startX: edge.sx; startY: edge.sy
                        PathCubic {
                            x: edge.tx; y: edge.ty
                            control1X: edge.kind === "prov" ? (edge.sx + edge.tx) / 2 : (edge.sx + edge.tx) / 2 - (edge.ty - edge.sy) * edge.bend
                            control1Y: edge.kind === "prov" ? edge.sy : (edge.sy + edge.ty) / 2 + (edge.tx - edge.sx) * edge.bend
                            control2X: edge.kind === "prov" ? (edge.sx + edge.tx) / 2 : control1X
                            control2Y: edge.kind === "prov" ? edge.ty : control1Y
                        }
                    }
                }
            }

            // nodes
            Repeater {
                model: map.visibleNodes
                delegate: Item {
                    id: node
                    required property var modelData
                    readonly property string kind: modelData.kind
                    readonly property var p: map.posOf(modelData.id)
                    readonly property real r: map.radiusOf(modelData.id)
                    objectName: "roomMapNode_" + modelData.id
                    x: p.x; y: p.y
                    width: 1; height: 1
                    opacity: map.dimmed(modelData.id) ? 0.18 : 1
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    MouseArea {
                        x: -node.r - 6; y: -node.r - 6; width: 2 * node.r + 12; height: 2 * node.r + 12
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: map.hovered = node.modelData.id
                        onExited: if (map.hovered === node.modelData.id) map.hovered = ""
                        onClicked: {
                            map.selected = map.selected === node.modelData.id ? "" : node.modelData.id;
                            if (node.kind === "intent") map.focusIntent = node.modelData.id.slice(2);
                        }
                    }
                    Rectangle {     // selection ring
                        visible: map.selected === node.modelData.id
                        x: -node.r - 6; y: -node.r - 6; width: 2 * node.r + 12; height: width
                        radius: node.kind === "observer" || node.kind === "outside" || node.kind === "bytes" ? 12 : width / 2
                        color: "transparent"; border.color: Theme.palette.focus; border.width: 2
                    }

                    // a member
                    Loader {
                        active: node.kind === "member"
                        sourceComponent: Item {
                            readonly property string hex: node.modelData.id.slice(2)
                            readonly property bool self: hex === map.viewer
                            Rectangle {
                                visible: parent.self
                                x: -27; y: -27; width: 54; height: 54; radius: 27
                                color: "transparent"; border.color: MusterStyle.colorFor(parent.hex); border.width: 1.5
                            }
                            Avatar { x: -22; y: -22; size: 44; identity: parent.hex; name: map.memberName(node.modelData.id) }
                            LogosText {
                                x: -width / 2; y: 28
                                text: map.memberName(node.modelData.id) + (parent.self ? qsTr(" (this device)") : "")
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                            }
                            LogosText {
                                x: -width / 2; y: 44
                                readonly property int joined: Number((node.modelData.attrs || {}).joined)
                                text: joined >= 0 ? qsTr("joined epoch %1").arg(joined) : ""
                                color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // a proposal
                    Loader {
                        active: node.kind === "intent"
                        sourceComponent: Item {
                            readonly property var a: node.modelData.attrs || {}
                            readonly property string st: String(map.stepAt(node.modelData).state || "")
                            readonly property color ring: st === "final" || st === "executable" ? MusterStyle.settled
                                                        : st === "submitted" || st === "settling" ? MusterStyle.warning : MusterStyle.info
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: Theme.palette.surfaceRaised
                                border.color: parent.ring; border.width: parent.st === "final" ? 3 : 1.6
                            }
                            Repeater {      // the threshold, one slot per needed approval, filled as they land
                                model: Math.max(1, Number(parent.a.threshold || 1))
                                delegate: Rectangle {
                                    required property int index
                                    readonly property int n: Math.max(1, Number(node.modelData.attrs.threshold || 1))
                                    readonly property var at: map.polar(n === 1 ? 0 : -60 + index * 120 / (n - 1), node.r + 9, 0, 0)
                                    x: at.x - 4.5; y: at.y - 4.5; width: 9; height: 9; radius: 4.5
                                    color: index < Number(map.stepAt(node.modelData).approvals || 0) ? MusterStyle.settled : Theme.palette.background
                                    border.color: MusterStyle.settled; border.width: 1
                                }
                            }
                            LogosText {
                                x: -width / 2; y: -height / 2 - 2
                                width: Math.min(implicitWidth, 2 * node.r - 10)
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                                text: map.intentWord(node.modelData.id.slice(2))
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                                font.weight: Theme.typography.weightBold
                            }
                            StatusPill {
                                x: -width / 2; y: node.r + 16
                                text: map.stateWords(node.modelData)
                                tone: map.stateTone(node.modelData)
                            }
                        }
                    }
                    // an account, a signer key, a ceremony
                    Loader {
                        active: node.kind === "account" || node.kind === "signer" || node.kind === "ceremony"
                        sourceComponent: Item {
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width
                                rotation: node.kind === "account" ? 45 : 0
                                radius: node.kind === "ceremony" ? node.r : 3
                                color: Theme.palette.surfaceRaised
                                border.color: node.kind === "signer" ? Theme.palette.text : Theme.palette.textSecondary
                                border.width: 1.2
                            }
                            LogosText {
                                x: -width / 2; y: node.r + 6
                                text: node.kind === "account" ? String((node.modelData.attrs || {}).family || qsTr("account"))
                                    : node.kind === "signer" ? qsTr("key %1").arg(map.shortId(node.modelData.id.slice(2)))
                                    : qsTr("key ceremony")
                                color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // an outside observer
                    Loader {
                        active: node.kind === "observer" || node.kind === "outside"
                        sourceComponent: Item {
                            readonly property bool big: map.lens === "leaks"
                            readonly property var fields: node.kind === "observer" && node.modelData.id !== "o:store-node"
                                                         ? map.learned(node.modelData.id)
                                                         : node.modelData.id === "o:store-node" ? [qsTr("timing"), qsTr("topic")] : []
                            readonly property real w: big ? 210 : 150
                            readonly property real h: big ? 64 + fieldText.implicitHeight : 46
                            Rectangle {
                                x: -parent.w / 2; y: -parent.h / 2; width: parent.w; height: parent.h; radius: 9
                                color: Theme.palette.background
                                border.width: 1.3
                                border.color: node.modelData.id === "o:store-node" ? Theme.palette.warning
                                            : node.kind === "outside" ? Theme.palette.textSecondary
                                            : parent.fields.length > 0 ? MusterStyle.info : Theme.palette.border
                            }
                            LogosText {
                                x: -width / 2; y: -parent.h / 2 + 6
                                text: map.obsWord(node.modelData.id, 0)
                                color: Theme.palette.text; font.pixelSize: MusterStyle.caption
                            }
                            LogosText {
                                x: -width / 2; y: -parent.h / 2 + 22
                                text: map.obsWord(node.modelData.id, 1)
                                color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge
                            }
                            LogosText {
                                id: fieldText
                                visible: parent.big
                                x: -parent.w / 2 + 10; y: -parent.h / 2 + 42
                                width: parent.w - 20
                                wrapMode: Text.Wrap
                                horizontalAlignment: Text.AlignHCenter
                                text: node.kind === "outside" ? qsTr("took in; learned nothing from the room")
                                    : parent.fields.length > 0 ? parent.fields.join(", ") : qsTr("nothing yet")
                                color: parent.fields.length > 0 ? Theme.palette.text : Theme.palette.textTertiary
                                font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                            }
                        }
                    }
                    // a log entry
                    Loader {
                        active: node.kind === "entry"
                        sourceComponent: Item {
                            readonly property var a: node.modelData.attrs || {}
                            readonly property bool wentOut: map.entryLeft(node.modelData)
                            Rectangle {
                                visible: parent.wentOut
                                x: -node.r - 4; y: -node.r - 4; width: 2 * node.r + 8; height: width; radius: width / 2
                                color: "transparent"; border.color: MusterStyle.info; border.width: 1.2
                            }
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: map.clsColor(String(parent.a.cls || ""))
                                opacity: parent.a.counted ? 1 : 0.35
                                border.width: parent.a.account ? 2 : 0
                                border.color: parent.a.account && String(parent.a.account).indexOf("m:") === 0
                                              ? MusterStyle.colorFor(String(parent.a.account).slice(2)) : Theme.palette.text
                            }
                            LogosText {
                                readonly property bool below: map.lens === "prov" || node.modelData.seq % 2 === 0
                                x: -width / 2; y: below ? node.r + 3 : -node.r - height - 3
                                text: map.kindWord(String(parent.a.kind || ""))
                                      + (map.lens === "prov" && parent.a.account ? " · " + map.actorName(parent.a.account) : "")
                                color: Theme.palette.textSecondary; font.pixelSize: map.lens === "prov" ? MusterStyle.caption : 9
                            }
                        }
                    }
                    // before you joined
                    Loader {
                        active: node.kind === "sealed"
                        sourceComponent: Item {
                            Rectangle {
                                x: -node.r; y: -node.r; width: 2 * node.r; height: width; radius: node.r
                                color: Theme.palette.surfaceRecessed
                                border.color: Theme.palette.border; border.width: 1
                                LogosIcon { anchors.centerIn: parent; width: 18; height: 18; source: MusterStyle.icon("lock"); color: Theme.palette.textTertiary }
                            }
                            LogosText {
                                x: -width / 2; y: node.r + 6
                                text: qsTr("Before you joined: sealed to you")
                                color: Theme.palette.textSecondary; font.pixelSize: MusterStyle.badge
                            }
                        }
                    }
                    // the signed bytes (Provenance)
                    Loader {
                        active: node.kind === "bytes"
                        sourceComponent: Item {
                            Rectangle {
                                x: -70; y: -42; width: 140; height: 84; radius: 9
                                color: Theme.palette.background; border.color: MusterStyle.settled; border.width: 1.4
                            }
                            Column {
                                anchors.centerIn: parent
                                spacing: 2
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Signed bytes"); color: Theme.palette.text; font.pixelSize: MusterStyle.caption }
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("materialization + P"); color: Theme.palette.textTertiary; font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono }
                                LogosText { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("re-derived on each device"); color: MusterStyle.settled; font.pixelSize: MusterStyle.badge }
                            }
                        }
                    }
                }
            }
        }

        LogosText {
            anchors { left: parent.left; bottom: parent.bottom; margins: Theme.spacing.small }
            width: Math.min(parent.width - 2 * Theme.spacing.small, 520)
            wrapMode: Text.Wrap
            color: Theme.palette.textSecondary
            font.pixelSize: MusterStyle.caption
            text: map.lens === "me" ? qsTr("You, the keys bound to you, the proposals you took part in, and what of them left the room. Everything else is dimmed.")
                : map.lens === "leaks" ? qsTr("Each outside observer, and exactly the fields it learned, placed at the entry where they left.")
                : map.lens === "prov" ? (map.provIntent.length > 0 ? qsTr("Every input that reached the signed bytes, then the approvals over them. Select a proposal to trace another.")
                                                                   : qsTr("No proposal yet. Provenance traces one proposal's inputs."))
                : map.lens === "log" ? qsTr("Every entry you can open, in the order members saw them; lines are the hash links to what each depends on.")
                : qsTr("Members and what they decided sit inside the boundary. Blue carries information out; grey dashes bring outside reads in.")
        }
    }
    function radiusOf(id) {
        var n = id === "sealed" ? { kind: "sealed" } : id === "bytes" ? { kind: "bytes" } : nodeById[id];
        if (!n) return 10;
        switch (n.kind) {
        case "member": return 24;
        case "intent": return 40;
        case "observer": case "outside": return map.lens === "leaks" ? 64 : 30;
        case "account": return 13;
        case "signer": return 9;
        case "ceremony": return 12;
        case "sealed": return 34;
        case "bytes": return 58;
        case "entry": return map.lens === "prov" ? 12 : 7;
        }
        return 10;
    }
    function entryLeft(n) {
        for (var i = 0; i < allEdges.length; i++)
            if (allEdges[i].kind === "leaves" && allEdges[i].seq === n.seq) return true;
        return false;
    }
    function actorName(id) {
        id = String(id || "");
        if (id.indexOf("m:") === 0) return memberName(id);
        if (id.indexOf("k:") === 0) return qsTr("key %1").arg(shortId(id.slice(2)));
        return shortId(id);
    }

    // ── the inspector ──────────────────────────────────────────────────────
    Rectangle {
        id: inspector
        objectName: "roomMapInspector"
        anchors { right: parent.right; top: header.bottom; bottom: timeline.top; margins: Theme.spacing.small }
        width: Math.min(320, map.width * 0.34)
        radius: 10
        color: Theme.palette.surfaceRaised
        border.color: Theme.palette.borderSubtle

        readonly property var n: map.selected === "sealed" ? { id: "sealed", kind: "sealed", attrs: {} }
                               : map.selected === "bytes" ? { id: "bytes", kind: "bytes", attrs: {} }
                               : map.selected.length > 0 ? map.nodeById[map.selected] || null
                               : map.lens === "me" ? map.nodeById["m:" + map.viewer] || null : null
        readonly property var info: map.describe(n)

        Flickable {
            anchors.fill: parent
            anchors.margins: Theme.spacing.medium
            contentHeight: col.implicitHeight
            clip: true
            ColumnLayout {
                id: col
                width: parent.width
                spacing: Theme.spacing.small
                LogosText {
                    text: inspector.info.kicker
                    color: Theme.palette.textTertiary
                    font.pixelSize: MusterStyle.badge; font.family: MusterStyle.mono
                }
                LogosText {
                    objectName: "roomMapInspectorTitle"
                    Layout.fillWidth: true
                    text: inspector.info.title
                    wrapMode: Text.Wrap
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.subtitle
                    font.weight: Theme.typography.weightBold
                }
                StatusPill { visible: inspector.info.pill.length > 0; text: inspector.info.pill; tone: inspector.info.tone }
                LogosText {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: inspector.info.lead
                    wrapMode: Text.Wrap
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.body
                }
                Repeater {
                    model: inspector.info.rows
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        LogosText {
                            Layout.preferredWidth: 104
                            Layout.alignment: Qt.AlignTop
                            text: modelData[0]
                            color: Theme.palette.textSecondary
                            font.pixelSize: MusterStyle.caption
                        }
                        LogosText {
                            Layout.fillWidth: true
                            text: modelData[1]
                            wrapMode: Text.WrapAnywhere
                            color: modelData.length > 2 && modelData[2] === "out" ? MusterStyle.infoText : Theme.palette.text
                            font.pixelSize: MusterStyle.caption
                            font.family: modelData.length > 2 && modelData[2] === "mono" ? MusterStyle.mono : Theme.typography.publicSans
                        }
                    }
                }
                Rectangle {
                    visible: inspector.info.guarantee.length > 0
                    Layout.fillWidth: true
                    implicitHeight: guarantee.implicitHeight + 2 * Theme.spacing.small
                    radius: 6
                    color: MusterStyle.settledSoft
                    LogosText {
                        id: guarantee
                        anchors { fill: parent; margins: Theme.spacing.small }
                        text: inspector.info.guarantee
                        wrapMode: Text.Wrap
                        color: Theme.palette.text
                        font.pixelSize: MusterStyle.caption
                    }
                }
                RowLayout {
                    spacing: Theme.spacing.small
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "intent"
                        objectName: "roomMapOpenCard"
                        compact: true
                        text: qsTr("Open the card")
                        onClicked: map.openCard(inspector.n.id.slice(2))
                    }
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "intent" && map.lens !== "prov"
                        compact: true; quiet: true
                        text: qsTr("Trace its inputs")
                        onClicked: { map.focusIntent = inspector.n.id.slice(2); map.lens = "prov"; }
                    }
                    ActionButton {
                        visible: inspector.n !== null && inspector.n.kind === "entry"
                        compact: true; quiet: true
                        text: qsTr("Replay to here")
                        onClicked: { map.following = false; map.k = map.rank(inspector.n.seq); }
                    }
                }
            }
        }
    }
    function describe(n) {
        var d = { kicker: "", title: "", pill: "", tone: "waiting", lead: "", rows: [], guarantee: "" };
        var i, e, a;
        if (!n) {
            d.kicker = qsTr("THE ROOM");
            d.title = qsTr("How this room got here");
            d.lead = qsTr("Everything on the map is folded from the room's log. Drag the timeline to replay it; select anything to see what it is and what the code guarantees about it.");
            d.rows.push([qsTr("Members"), String(map.memberIds.length)]);
            d.rows.push([qsTr("Proposals"), String(map.intentIds.length)]);
            d.rows.push([qsTr("You read from"), map.readFrom > 0 ? qsTr("epoch %1, nothing before your admission").arg(map.readFrom) : qsTr("epoch 0, as a founder")]);
            d.rows.push([qsTr("Store node"), qsTr("timing and topic of %n envelopes", "", map.heldCount), "out"]);
            var obs = ["o:rpc-provider", "o:chain-observer", "o:target-module"];
            for (i = 0; i < obs.length; i++) {
                var f = map.learned(obs[i]);
                if (f.length > 0) d.rows.push([map.obsWord(obs[i], 0), f.join(", "), "out"]);
            }
            return d;
        }
        a = n.attrs || {};
        if (n.kind === "member") {
            var hex = n.id.slice(2), self = hex === map.viewer;
            d.kicker = qsTr("MEMBER");
            d.title = map.memberName(n.id) + (self ? qsTr(" · this device") : "");
            d.lead = self ? qsTr("Your keys stay on this device. The room sees what you signed into it, and nothing else.")
                          : qsTr("What the map says about this member is only what they put in the room (invariant 9).");
            d.rows.push([qsTr("Joined"), Number(a.joined) >= 0 ? qsTr("epoch %1").arg(a.joined) : qsTr("not in the roster you hold")]);
            d.rows.push([qsTr("Identity"), map.shortId(hex), "mono"]);
            var did = 0, keys = [];
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.src === n.id && map.rank(e.seq) <= map.k && e.kind === "authored") did++;
                if (e.src === n.id && e.kind === "bound") keys.push(map.shortId(e.dst.slice(2)));
            }
            d.rows.push([qsTr("Signed entries"), String(did)]);
            if (keys.length > 0) d.rows.push([qsTr("Approval keys"), keys.join(", "), "mono"]);
            return d;
        }
        if (n.kind === "intent") {
            var id = n.id.slice(2), it = map.intentOf(id);
            d.kicker = qsTr("PROPOSAL");
            d.title = map.intentWord(id);
            d.pill = map.stateWords(n); d.tone = map.stateTone(n);
            d.lead = it && it.summary ? String(it.summary.text || "") : "";
            d.rows.push([qsTr("Runs as"), String(a.family || "")]);
            d.rows.push([qsTr("Agreed"), qsTr("%1 of %2").arg(Number(map.stepAt(n).approvals || 0)).arg(Number(a.threshold || 0))]);
            if (Number(a.declines || 0) > 0) d.rows.push([qsTr("Declined"), String(a.declines)]);
            var inputs = 0;
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.dst === n.id && e.kind === "input") inputs++;
                if (e.src === n.id && e.kind === "leaves" && map.rank(e.seq) <= map.k)
                    d.rows.push([map.obsWord(e.dst, 0) + qsTr(" at #%1").arg(e.seq), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
            }
            d.guarantee = qsTr("Re-derived on each device from the effect · %n inputs, each traced to its entry in the log", "", inputs);
            return d;
        }
        if (n.kind === "observer" || n.kind === "outside") {
            d.kicker = qsTr("OUTSIDE THE ROOM");
            d.title = map.obsWord(n.id, 0);
            d.lead = map.obsWord(n.id, 2);
            if (n.id === "o:store-node") d.rows.push([qsTr("Learned"), qsTr("timing and topic of %n envelopes", "", map.heldCount), "out"]);
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.dst === n.id && e.kind === "leaves" && map.rank(e.seq) <= map.k)
                    d.rows.push([map.intentWord(e.src.slice(2)) + qsTr(" at #%1").arg(e.seq), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
                if (e.src === n.id && e.kind === "enters" && map.rank(e.seq) <= map.k)
                    d.rows.push([qsTr("Into %1 at #%2").arg(map.intentWord(e.dst.slice(2))).arg(e.seq), map.kindWord(String((e.attrs || {}).kind || ""))]);
            }
            return d;
        }
        if (n.kind === "entry") {
            d.kicker = qsTr("LOG ENTRY #%1 · EPOCH %2").arg(n.seq).arg(n.epoch);
            d.title = map.kindWord(String(a.kind || "")) + (a.account ? qsTr(" by %1").arg(map.actorName(a.account)) : "");
            if (!a.counted) d.lead = qsTr("Not counted: the fold refused this entry, so it names no one.");
            d.rows.push([qsTr("Class"), String(a.cls || qsTr("not classed"))]);
            d.rows.push([qsTr("Attribution"), map.basisWords(String(a.basis || ""))]);
            if (a.attestation) d.rows.push([qsTr("Attestation"), String(a.attestation)]);
            d.rows.push([qsTr("Content id"), map.shortId(n.id.slice(2)), "mono"]);
            if (a.intent) d.rows.push([qsTr("Proposal"), map.intentWord(String(a.intent))]);
            for (i = 0; i < allEdges.length; i++) {
                e = allEdges[i];
                if (e.kind === "leaves" && e.seq === n.seq)
                    d.rows.push([qsTr("Left to %1").arg(map.obsWord(e.dst, 0)), ((e.attrs && e.attrs.fields) || []).join(", "), "out"]);
            }
            d.guarantee = String(a.guarantee || "");
            return d;
        }
        if (n.kind === "account") {
            d.kicker = qsTr("ACCOUNT IN THE ROOM");
            d.title = String(a.family || qsTr("Account"));
            d.rows.push([qsTr("Chain"), String(a.chain || ""), "mono"]);
            d.rows.push([qsTr("Account"), map.shortId(n.id.slice(2)), "mono"]);
            if (Number(a.threshold || 0) > 0) d.rows.push([qsTr("Rule"), qsTr("%1 of %2").arg(a.threshold).arg(a.signers)]);
            if (a.conflict) d.rows.push([qsTr("Note"), qsTr("Members disclosed different configurations for it")]);
            d.guarantee = qsTr("Disclosed by a member, signed by them; each client checks it against the chain before acting from it.");
            return d;
        }
        if (n.kind === "signer") {
            d.kicker = qsTr("APPROVAL KEY");
            d.title = map.shortId(n.id.slice(2));
            var owner = "";
            for (i = 0; i < allEdges.length; i++) if (allEdges[i].kind === "bound" && allEdges[i].dst === n.id) owner = allEdges[i].src;
            d.lead = owner.length > 0 ? qsTr("Bound to %1 by a signed binding the room checked (F-14).").arg(map.memberName(owner))
                                      : qsTr("No binding in the room ties this key to a member, so the map names no one.");
            d.guarantee = qsTr("The driver verified that each approval from this key recovers to a configured signer.");
            return d;
        }
        if (n.kind === "ceremony") {
            d.kicker = qsTr("KEY CEREMONY");
            d.title = qsTr("FROST key ceremony");
            d.lead = qsTr("A group key made in the room. Every member computes the coordinator's steps from the log.");
            return d;
        }
        if (n.kind === "sealed") {
            d.kicker = qsTr("SEALED");
            d.title = qsTr("Before you joined");
            d.lead = qsTr("Entries from epochs before your admission. Your client never held those epochs' keys, so it cannot open them, and this map cannot show them.");
            d.guarantee = qsTr("Membership epochs are real: a joiner reads from its own admission on (invariant 7, F-16).");
            return d;
        }
        if (n.kind === "bytes") {
            d.kicker = qsTr("INVARIANTS 1 AND 10");
            d.title = qsTr("The signed bytes");
            d.lead = qsTr("The materialization of the effect, with the provenance record P committed inside it. Each input on the left is named in P by class, author and log position.");
            d.guarantee = qsTr("Each device re-derives the materialization and refuses on mismatch; signing is refused if any input's origin cannot be accounted for.");
            return d;
        }
        return d;
    }

    // ── the timeline: one tick per entry; drag or play to replay ─────────────
    Rectangle {
        id: timeline
        objectName: "roomMapTimeline"
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.spacing.small }
        height: 74
        radius: 10
        color: Theme.palette.surfaceRaised
        border.color: Theme.palette.borderSubtle

        Timer {
            id: player
            interval: 700; repeat: true
            onTriggered: { if (map.k >= map.seqMax) { stop(); map.following = true; } else map.k = map.k + 1; }
        }
        RowLayout {
            anchors { fill: parent; margins: Theme.spacing.small }
            spacing: Theme.spacing.medium
            ActionButton {
                objectName: "roomMapPlay"
                compact: true
                text: player.running ? qsTr("Pause") : qsTr("Replay")
                enabled: map.seqMax >= 0
                onClicked: {
                    if (player.running) { player.stop(); return; }
                    map.following = false;
                    if (map.k >= map.seqMax) map.k = 0;
                    player.start();
                }
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 4
                Item {
                    id: track
                    Layout.fillWidth: true
                    implicitHeight: 30
                    readonly property real step: map.seqMax > 0 ? width / map.seqMax : 0
                    Rectangle {      // before you joined
                        visible: map.readFrom > 0
                        x: 0; y: 4; width: 10; height: 22; radius: 2
                        color: Theme.palette.surfaceRecessed; border.color: Theme.palette.border
                    }
                    Repeater {
                        model: map.allNodes
                        delegate: Rectangle {
                            required property var modelData
                            visible: modelData.kind === "entry"
                            readonly property bool out: visible && map.entryLeft(modelData)
                            x: (map.readFrom > 0 ? 14 : 0) + map.rank(modelData.seq) * (track.width - (map.readFrom > 0 ? 14 : 0)) / Math.max(1, map.seqMax) - 2
                            y: out ? 2 : 8
                            width: 4; height: out ? 26 : 16; radius: 1.5
                            color: out ? MusterStyle.info : map.clsColor(String((modelData.attrs || {}).cls || ""))
                            opacity: map.rank(modelData.seq) <= map.k ? 1 : 0.25
                        }
                    }
                    Rectangle {
                        x: (map.readFrom > 0 ? 14 : 0) + Math.max(0, map.k) * (track.width - (map.readFrom > 0 ? 14 : 0)) / Math.max(1, map.seqMax) - 1
                        width: 2; height: parent.height
                        color: Theme.palette.text
                    }
                    MouseArea {
                        anchors.fill: parent
                        function seekTo(mx) {
                            var off = map.readFrom > 0 ? 14 : 0;
                            var s = Math.round((mx - off) / Math.max(1, track.width - off) * Math.max(1, map.seqMax));
                            map.following = s >= map.seqMax;
                            map.k = Math.max(0, Math.min(map.seqMax, s));
                        }
                        onPressed: (m) => { player.stop(); seekTo(m.x); }
                        onPositionChanged: (m) => { if (pressed) seekTo(m.x); }
                    }
                }
                LogosText {
                    objectName: "roomMapNow"
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.caption
                    text: {
                        if (map.seqMax < 0) return qsTr("The log is empty.");
                        var n = null;
                        n = map.replayOrder[map.k] || null;
                        var w = n ? map.kindWord(String((n.attrs || {}).kind || "")) + (n.attrs && n.attrs.account ? qsTr(" by %1").arg(map.actorName(n.attrs.account)) : "") : "";
                        return qsTr("%1 of %2 · in the order members saw them").arg(map.k + 1).arg(map.seqMax + 1) + (w.length > 0 ? " · " + w : "")
                               + (n ? qsTr(" · epoch %1").arg(n.epoch) : "");
                    }
                }
            }
        }
    }
}
