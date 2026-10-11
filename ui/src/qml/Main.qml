import QtQuick
import QtQuick.Layouts
import QtCore as Prefs   // qualified: Settings here is also our own Settings.qml surface

import Logos.Theme
import Logos.Controls

// P4 — increment 2: propose → review the real re-materialization strip.
//
// ADR-011 resolved: built on Logos.Theme / Logos.Controls, so this looks like
// the rest of the platform and inherits U-10's contrast / reduced-motion.
//
// What this slice does, and does honestly:
//   • describe()  → the Safe account this walkthrough coordinates (chainId,
//                   safe, threshold) — shown, never assumed by the view.
//   • propose()   → the module canonicalizes the effect to the EIP-712
//                   safeTxHash and returns an intent id.
//   • txhash()    → those exact bytes, re-derived by the module from the effect.
//
// The strip shows the effect we sent against the hash the module re-derived from
// it. They agree by construction, which is the honest "matches" state — the
// first time this check runs against a real driver rather than the prototype's
// simulated hashes. A genuine MISMATCH is the module core's to refuse (F-4 /
// invariant 1); it only becomes demonstrable with a divergent input source (the
// plugin runtime, P5), so it is never simulated here.
//
// What this slice deliberately does NOT do: collect approvals. An approval is an
// owner signature over the safeTxHash, and the UI/core never holds keys — owners
// sign on their own devices. Collecting across owners is the multi-instance step
// (P3); until then the card stops honestly at "here are the bytes each owner
// will sign."
//
// NB: nix build does not evaluate QML — this needs qmllint against the
// design-system import path AND a launch to be believed
// (docs/labbook/qml-errors-are-invisible-to-nix-build.md).
Item {
    id: root

    readonly property var backend: logos.module("muster_ui")
    // Main passed down to the surfaces that read its state (AccountPage), as `root`:
    // `root: root` there would bind the surface's own property to itself.
    readonly property Item mainItem: root
    property bool ready: false

    // Whether the account card's owner list is expanded (Account view, "dive in").
    property bool ownersOpen: false

    // Which surface is showing. The product opens on "home" (the action list);
    // "compose" (create a room from an action), "room" (the conversation),
    // "dashboard" (the Safe lifecycle spike), "walkthrough" (the claims registry).
    property string view: "home"
    // describe() is read once at start, possibly before the platform's chain registry
    // answers; a room's Safe form reads it, so read it again on the way in (R6, 2026-10-07)
    onViewChanged: if (view === "room" && backend) backend.loadAccount()

    // Enter a room by topic: join it in the module, then show the room surface.
    // When `verb` is given (a freshly composed room), PRIME the conversation — the
    // intention implies what to ask participants for. A money verb needs an address
    // exchange, so the room opens with an address-request naming the intent; whoever
    // holds the needed address answers it with address-share (the card's button).
    // "talk" primes nothing. Re-opening an existing room passes no verb → no priming.
    function enterRoom(topic, verb, policy, draftJson, invitee) {
        if (!root.backend || !topic)
            return;
        // Reset per-room auto-admit state on every entry; onCreateRoom re-sets the
        // expected member right after when a person was named. A plain Home re-open
        // (no verb) leaves it cleared, so it never auto-admits into the wrong room.
        roomSurface.expectedMember = "";
        roomSurface.autoAdmitted = ({});
        // A room opened from the composer (a verb) is this member's own: it asks no one
        // to join it (below), and its scope panel offers no "Ask to join" (exo-dcc.30).
        roomSurface.founded = String(verb || "").length > 0;
        root.backend.joinRoom(topic);
        // A person named in the composer (their 64-byte chat id, 128 hex chars) is invited
        // now, before the room says anything: the invite admits them (exo-dcc.29), so they
        // arrive a member, never ask to join, and read the room's opening lines. Pass the
        // RAW topic; both sides normalize it to the same content topic on join. A pasted
        // address (not a chat id) is skipped.
        var inv = String(invitee || "").replace(/^0x/i, "");
        if (inv.length >= 128)
            root.backend.sendInvite(invitee, topic, String(verb || ""));
        root.view = "room";
        // Set the room to coordinate under the intent's chosen policy (its driver).
        var p = String(policy || "");
        // Through the room, so its coherePolicy judges by this choice until the module's
        // answer arrives — not by the previous room's policy (exo-dcc.5).
        if (p.length > 0)
            roomSurface.choosePolicy(p);
        var v = String(verb || "");
        // Seed the room to the ACTIVITY chosen in the composer, so each verb opens a
        // genuinely different room rather than all landing on the same chat:
        //   • pay    → the payment composer (amount + recipient), Safe policy;
        //   • decide → the statement composer (what the room ratifies), threshold policy;
        //   • talk   → just the conversation, no proposal composer.
        // Without this the room always defaulted to the payment kind, and coherePolicy
        // then even snapped a decision's threshold policy back to Safe.
        if (v === "pay")
            roomSurface.composeType = "payment";
        else if (v === "decide")
            roomSurface.composeType = "statement";
        else if (v === "split" || v === "request") {
            // you fronted it: the split composer (exo-a90); a request is one of one person
            // who pays you, and you not in it (exo-dcc.5)
            roomSurface.composeType = "split";
            roomSurface.splitRequest = v === "request";
        }
        // Auto-ask to join UNLESS this is a fresh composer creation (a verb): a joiner
        // entering a room someone else already founded can't see them (their epoch is
        // sealed), so without this they'd have no idea they must ask. Requesting is
        // harmless if the room is empty or we're already admitted — the retry loop
        // stops as soon as the roster grows past just us (or after a bounded wait).
        // The founder (verb present) doesn't ask itself in; it admits the joiner.
        if (v.length === 0)
            root.backend.requestJoin();
        // A split asks nobody for an address: the person who fronted the bill is paid at
        // their own, which the split carries (exo-a90) — and so does a payment request,
        // whose address the requester's own wallet makes (exo-dcc.5). Only a payment
        // primes an ask.
        var purpose = v === "pay" ? qsTr("Pay someone") : "";
        if (purpose.length > 0)
            root.backend.postMessage(JSON.stringify({
                kind: "address-request", intent: v, purpose: purpose
            }));
        // The composer's third step (F-18, exo-45e K6): if it composed a first payment
        // (account + asset + destination), PRE-FILL the in-room composer with it — never
        // propose it straight away, because a proposal must wait until the room has the
        // people to act on it (the Propose gate); proposing into an empty room strands
        // the card where a later joiner can't read it (F-16). An empty draft just opens
        // the composer to the right kind. Talk opens the conversation (no composer).
        var d = String(draftJson || "");
        if (d.length > 0) {
            try {
                var o = JSON.parse(d);
                roomSurface.prefillPayment(String(o.to || ""),
                                           (o.value !== undefined ? String(o.value) : ""));
            } catch (e) { roomSurface.composing = true; }
        } else if (v === "pay" || v === "decide" || v === "split" || v === "request") {
            roomSurface.composing = true;
        }
    }

    // Backend PROPs, aliased so bindings read cleanly. The backend is the only
    // writer; these are all reads.
    readonly property string health: backend ? backend.health : "(no backend)"
    readonly property bool healthy: root.health === "ok"
    readonly property string accountJson: backend ? backend.accountJson : ""
    readonly property string intentId: backend ? backend.intentId : ""
    readonly property string intentEffect: backend ? backend.intentEffect : ""
    readonly property string intentTxhash: backend ? backend.intentTxhash : ""
    readonly property string intentState: backend ? backend.intentState : ""
    readonly property string lastError: backend ? backend.lastError : ""
    readonly property string balancesJson: backend ? backend.balancesJson : "[]"

    readonly property bool hasIntent: root.intentId.length > 0

    // Still collecting signatures: show the approve affordance until the driver
    // reports the threshold met (executable) or the intent has moved on-chain.
    readonly property bool collectable: root.hasIntent
        && root.intentState !== "executable" && root.intentState !== "submitted"
        && root.intentState !== "settling" && root.intentState !== "final"

    // The post-collection legs: executable (ready to submit), submitting (on-chain,
    // awaiting the receipt), and final (executed, finality read from the chain).
    readonly property bool isExecutable: root.intentState === "executable"
    readonly property bool isSubmitting: root.intentState === "submitted" || root.intentState === "settling"
    readonly property bool isFinal: root.intentState === "final"

    // Parsed views of the JSON the module handed us. A parse failure yields null
    // rather than a guess, so a broken value renders as absent, not as fiction.
    readonly property var account: {
        try { return root.accountJson ? JSON.parse(root.accountJson) : null; }
        catch (e) { return null; }
    }
    readonly property var effect: {
        try { return root.intentEffect ? JSON.parse(root.intentEffect) : null; }
        catch (e) { return null; }
    }
    // The wallet balances, parsed. A parse failure yields [] (absent), not fiction.
    readonly property var balances: {
        try { return root.balancesJson ? JSON.parse(root.balancesJson) : []; }
        catch (e) { return []; }
    }

    // Room state, aliased for the home fold.
    readonly property string roomTopic: backend ? backend.roomTopic : ""

    // A room's topic is public, so it names nothing (exo-661.7; Composer.derivedTopic).
    // What this instance knows about a room it opened or was invited to — the activity,
    // who it is with — is kept here for Home's titles instead: this session only, keyed
    // by the room's content topic. A room without a label shows its topic.
    property var roomLabels: ({})
    function contentTopicOf(t) {
        // The module's toContentTopic, so a raw name keys the same room it joins.
        t = String(t || "");
        var parts = t.split("/");
        if (t.charAt(0) === "/" && parts.length === 5 && parts[1] && parts[2] && parts[3] && parts[4])
            return t;
        var name = t.replace(/^\/+|\/+$/g, "").replace(/\//g, ".");
        return "/muster/1/" + (name.length ? name : "room") + "/proto";
    }
    function labelRoom(topic, label) {
        if (!topic || !label)
            return;
        var m = Object.assign({}, root.roomLabels);   // reassign so bindings re-evaluate
        m[root.contentTopicOf(topic)] = label;
        root.roomLabels = m;
        // kept by the module too, beside the joined rooms, so a relaunch shows it (exo-dcc.25)
        if (root.backend)
            root.backend.setRoomTitle(topic, label);
    }
    // A room's name: this member's own, from the module (it survives a relaunch), else
    // what this session labelled it; empty when it has none.
    // A room with no name is told apart by the tail of its code ("Room 9cdc366149").
    function shortRoom(topic) {
        var parts = root.contentTopicOf(topic).split("/");
        var name = String(parts[3] || "");
        var tail = name.split(".").pop();
        return qsTr("Room %1").arg(tail.length > 10 ? tail.slice(-10) : tail);
    }
    function titleOf(topic) {
        var t = root.contentTopicOf(topic);
        var convs = root.conversations;
        for (var i = 0; i < convs.length; ++i)
            if (String(convs[i].topic || "") === t && String(convs[i].title || "").length > 0)
                return String(convs[i].title);
        return root.roomLabels[t] || "";
    }
    function shortId(s) {
        s = String(s || "").replace(/^0x/i, "");
        return s.length > 12 ? s.slice(0, 8) + "…" : s;
    }

    // Every joined conversation (multi-room), from coordinate_conversations.
    readonly property var conversations: {
        try { return JSON.parse(backend ? backend.conversationsJson : "[]"); }
        catch (e) { return []; }
    }

    // The home surface is a query over intents (F-18, exo-ed5): the module classes every
    // intent in every joined room for THIS member — needs-you, waiting-on-others,
    // settled — from the room's log and this member's own keys. One row per intent that
    // waits on you, then one per room for the rest; needs-you first, then in flight,
    // then settled, then the quiet rooms. Opening a row re-joins (re-activates) that room.
    function needsHeadline(what) {
        return what === "agree" ? qsTr("Needs your agreement")
             : what === "pay" ? qsTr("Pay your share")
             : what === "approve" ? qsTr("Needs your approval")
             : what === "submit" ? qsTr("Agreed — ready to settle")
             : qsTr("Waiting on you");
    }
    readonly property var homeActions: {
        var needs = [], waiting = [], settled = [], idle = [];
        var convs = root.conversations;
        for (var i = 0; i < convs.length; ++i) {
            var c = convs[i];
            var topic = String(c.topic || "");
            var title = root.titleOf(topic) || root.shortRoom(topic);
            var ns = Array.isArray(c.needs) ? c.needs : [];
            for (var j = 0; j < ns.length; ++j)
                needs.push({ topic: topic, title: title, action: root.needsHeadline(String(ns[j].what || "")),
                             state: "needs", detail: String(ns[j].text || "") });
            var w = Number(c.waiting || 0), d = Number(c.settled || 0);
            if (ns.length > 0) continue;       // the room is already on the list, by what waits on you
            if (w > 0)
                waiting.push({ topic: topic, title: title, action: qsTr("Waiting on others"), state: "waiting",
                               detail: w === 1 ? qsTr("1 in progress") : qsTr("%1 in progress").arg(w) });
            else if (d > 0)
                settled.push({ topic: topic, title: title, action: qsTr("Done"), state: "settled",
                               detail: d === 1 ? qsTr("1 settled") : qsTr("%1 settled").arg(d) });
            else
                idle.push({ topic: topic, title: title, action: c.active ? qsTr("Talking") : qsTr("Open"),
                            state: "idle",
                            detail: c.lastTs ? qsTr("last active · %1").arg(c.lastTs) : qsTr("no proposals yet") });
        }
        return needs.concat(waiting, settled, idle);
    }
    // Keep the list current while it is on screen — what waits on you changes when
    // someone else agrees, pays or proposes, in any room.
    Timer {
        interval: 2000
        repeat: true
        // the sidebar shows every room and what waits on you, on every view (exo-720.6)
        running: root.backend !== null
        onTriggered: root.backend.loadConversations()
    }

    Connections {
        target: logos
        function onViewModuleReadyChanged(moduleName, isReady) {
            if (moduleName === "muster_ui")
                root.ready = isReady && root.backend !== null;
        }
    }
    Component.onCompleted: {
        root.ready = root.backend !== null && logos.isViewModuleReady("muster_ui");
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.palette.background
    }

    // ── the sidebar (Sidebar.qml), and in a narrow window the strip that opens it ──
    // It replaces the top bar of seven buttons (exo-720.6). Where it sits is the person's
    // choice, kept on this device only: collapsed to a rail or full. Until they choose, a
    // window under 1180 px (Basecamp's, beside its own sidebar) starts with the rail
    // (decision §6.1); under 900 px it is a drawer, opened from the strip.
    Prefs.Settings {
        id: uiPrefs
        category: "MusterUi"
        property int sidebarCollapsed: -1      // -1: not chosen yet · 0: full · 1: rail
    }
    property bool sidebarOpen: false           // the drawer, in a narrow window
    readonly property string sideMode: root.width < 900 ? "drawer"
        : uiPrefs.sidebarCollapsed === 1 ? "rail"
        : uiPrefs.sidebarCollapsed === 0 ? "full"
        : root.width < 1180 ? "rail" : "full"

    Rectangle {
        id: drawerStrip
        visible: root.sideMode === "drawer"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: visible ? 48 : 0
        color: Theme.palette.backgroundTertiary
        z: 5
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.palette.borderSubtle }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spacing.small
            anchors.rightMargin: Theme.spacing.medium
            spacing: Theme.spacing.small
            IconAction {
                objectName: "sidebarOpen"
                label: qsTr("Open the sidebar")
                icon: MusterStyle.icon("menu")
                onClicked: root.sidebarOpen = true
            }
            LogosText {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: root.view === "room" ? (root.titleOf(root.roomTopic) || (root.roomTopic.length > 0 ? root.shortRoom(root.roomTopic) : qsTr("Join a room")))
                    : root.view === "home" || root.view === "compose" ? qsTr("Needs you")
                    : root.view === "dashboard" ? qsTr("Wallet")
                    : root.view === "lez" ? qsTr("Wallet")
                    : root.view === "contacts" ? qsTr("Contacts")
                    : root.view === "walkthrough" ? qsTr("Learn")
                    : root.view === "settings" ? qsTr("Settings") : ""
                color: Theme.palette.text
                font.pixelSize: MusterStyle.subtitle
                font.weight: Theme.typography.weightBold
            }
        }
    }

    // Every surface fills this, beside the sidebar (or under the strip).
    Item {
        id: contentArea
        anchors.top: drawerStrip.visible ? drawerStrip.bottom : parent.top
        anchors.left: root.sideMode === "drawer" ? parent.left : sidebar.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    // the drawer's scrim: a tap outside closes it
    Rectangle {
        visible: root.sideMode === "drawer" && root.sidebarOpen
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        z: 19
        TapHandler { onTapped: root.sidebarOpen = false }
    }

    // ── keyboard (exo-720.12, U-10) ──────────────────────────────────────
    // Ctrl+K: jump to a room by name, from anywhere.
    RoomSwitcher { id: roomSwitcher; app: mainItem }
    Shortcut {
        sequences: ["Ctrl+K"]
        context: Qt.ApplicationShortcut
        onActivated: roomSwitcher.opened ? roomSwitcher.close() : roomSwitcher.open()
    }
    // A Shortcut fires only while Qt counts the window active, which a host embedding this
    // view may not report; the key itself still reaches the focused item and bubbles up
    // here, so take it then too (whichever comes first consumes it).
    Keys.onPressed: function (event) {
        if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
            roomSwitcher.opened ? roomSwitcher.close() : roomSwitcher.open();
            event.accepted = true;
        }
    }

    Sidebar {
        id: sidebar
        objectName: "sidebar"
        app: mainItem
        mode: root.sideMode
        z: root.sideMode === "drawer" ? 20 : 10
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        x: root.sideMode !== "drawer" || root.sidebarOpen ? 0 : -width
        width: implicitWidth
        onCollapseToggled: uiPrefs.sidebarCollapsed = (root.sideMode === "rail" ? 0 : 1)
        onCloseRequested: root.sidebarOpen = false
        onJumpRequested: roomSwitcher.open()
    }

    // ── the product surfaces (one shown at a time), below the nav bar ─────
    // Home: the action list. Opening a row joins that room; "Start something"
    // goes to the composer.
    Home {
        objectName: "homeSurface"
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "home"
        actions: root.homeActions
        setup: root.homeSetup
        onManageAccounts: {
            if (typeof logos !== "undefined" && typeof logos.request === "function")
                logos.request("evm.accounts.manage", {}, function (res) {});
            else root.view = "settings";
        }
        onOpenSettings: root.view = "settings"
        invites: {
            try { return JSON.parse(root.backend ? root.backend.invitesJson : "[]"); }
            catch (e) { return []; }
        }
        onActivated: root.enterRoom(topic)
        onJoinCode: function (topic) { root.enterRoom(topic); }   // joiner path → asks to join
        onJoinInvite: function(topic) {   // joiner path → auto-asks to join
            // Title the room from the sealed invite (its note and sender), never its topic.
            for (var i = 0; i < invites.length; ++i) {
                var inv = invites[i];
                if (String(inv.topic || "") === topic) {
                    root.labelRoom(topic, String(inv.note || "room") + " · from " +
                                   (inv.fromAlias ? String(inv.fromAlias) : root.shortId(inv.from)));
                    break;
                }
            }
            root.enterRoom(topic);
        }
        onDismissInvite: function(topic) { if (root.backend) root.backend.dismissInvite(topic); }
        onNewActivity: {
            root.view = "compose";
            if (root.backend) root.backend.loadContacts();   // so "who with" can pick a name
        }
    }

    // Poll the inbox for room invites while on Home, so an invite that arrives (over the
    // store, ~1s) shows up without a manual refresh. Cheap: one module read per tick.
    Timer {
        interval: 2000
        // the sidebar counts invitations on every view (exo-720.6)
        running: root.backend !== null
        repeat: true
        onTriggered: if (root.backend) root.backend.loadInvites()
    }

    // Compose: create a room from an action (what → who). "who" can be a tap on an
    // address-book name, fed in here from the host's contactsJson.
    Composer {
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "compose"
        contacts: {
            try { return JSON.parse(root.backend ? root.backend.contactsJson : "[]"); }
            catch (e) { return []; }
        }
        backend: root.backend
        onCreateRoom: {
            root.labelRoom(topic, String(verb || "room") + (peer ? " · with " + root.shortId(peer) : ""));
            // the invite (and with it their admission) goes out inside enterRoom
            root.enterRoom(topic, verb, policy, draftJson, peer);
            // Should a join request from them still arrive (an inviter on an older Muster,
            // which did not admit on invite), admit it without a manual Admit.
            var p = String(peer || "").replace(/^0x/i, "");
            roomSurface.expectedMember = p.length >= 128 ? String(peer) : "";
        }
    }

    // The conversation surface. Reads its state from the module through the backend.
    Room {
        id: roomSurface
        // the session title for this room (never its topic, which names nothing)
        roomTitle: roomSurface.topic.length > 0 ? (root.titleOf(roomSurface.topic) || root.shortRoom(roomSurface.topic)) : ""
        // Leave (exo-dcc.28): the module forgets the room; back to Home, where it no
        // longer shows. Rename (exo-dcc.25): this member's own name for it.
        onLeaveRequested: function (topic) {
            if (root.backend) root.backend.leaveRoom(topic);
            root.view = "home";
        }
        onRenameRequested: function (topic, title) { root.labelRoom(topic, title); }
        // A card remedy that lives in Settings (repoint the RPC): hop to the view.
        onSettingsRequested: {
            root.view = "settings";
            if (root.backend) root.backend.loadSettings();
        }
        // Install what a proposal needs (exo-dcc.10): the card or the form asks, the shell
        // raises the request, and every answer comes back down in packageRequests.
        packageRequests: root.packageRequests
        onPackageInstallRequested: function (pkg) { root.requestPackageInstall(pkg); }
        onPackageShowRequested: function (pkg) { root.showPackage(pkg); }
        // open the Monero wallet (exo-dcc.5): the same, for monero.wallet.unlock / manage
        moneroWallet: root.moneroWallet
        onMoneroWalletRequested: function (wallet) { root.openMoneroWallet(wallet); }
        objectName: "roomSurface"
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "room"
        backend: root.backend
    }

    // The teaching surface (ADR-012 claims registry).
    Walkthrough {
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "walkthrough"
    }

    // The config-shell start: identity + user-configurable infrastructure (inv 8).
    Settings {
        objectName: "settingsSurface"
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "settings"
        backend: root.backend
        // the account link waits on the Logos Signer (exo-dcc.27): Settings shows where its
        // request stands, opens the signer on it, and offers to install the signer app
        keystoreRequests: root.keystoreRequests
        signerPackage: root.signerPackage
        signerInstall: root.packageRequests[root.signerPackage] || ({})
        onOpenSignerRequested: function (handle) { root.openSigner(handle); }
        onSignerInstallRequested: root.requestPackageInstall(root.signerPackage)
    }

    // The address book — name the ids you coordinate with (aliases resolve into the
    // roster and the join prompt).
    AddressBook {
        objectName: "addressBookSurface"
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "contacts"
        backend: root.backend
    }

    // ── the Wallet (exo-720.11, decision §6.3): the Account surface and Send on LEZ, as two
    // tabs of one page. The local test Safe on the Account surface already shows only where
    // the local dev chain (31337) answers — a fresh install never sees it.
    Rectangle {
        id: walletHeader
        objectName: "walletHeader"
        visible: root.view === "dashboard" || root.view === "lez"
        anchors.top: contentArea.top
        anchors.left: contentArea.left
        anchors.right: parent.right
        height: visible ? walletHeaderCol.implicitHeight : 0
        color: Theme.palette.background
        ColumnLayout {
            id: walletHeaderCol
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: 0
            ColumnLayout {
                Layout.leftMargin: Theme.spacing.xxlarge
                Layout.topMargin: Theme.spacing.xlarge
                spacing: 2
                LogosText {
                    text: qsTr("Wallet")
                    color: Theme.palette.text
                    font.pixelSize: MusterStyle.title
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    text: qsTr("What you hold on the chains you set up, each balance saying whether your own client checked it.")
                    color: Theme.palette.textSecondary
                    font.pixelSize: MusterStyle.body
                }
            }
            LogosTabBar {
                Layout.leftMargin: Theme.spacing.xxlarge - Theme.spacing.small
                Layout.topMargin: Theme.spacing.medium
                currentIndex: root.view === "lez" ? 1 : 0
                LogosTabButton {
                    objectName: "walletBalancesTab"
                    text: qsTr("Balances")
                    onClicked: {
                        root.view = "dashboard";
                        if (root.backend) { root.backend.loadAccount(); root.backend.loadBalances(); }
                    }
                }
                LogosTabButton {
                    objectName: "lezToggle"
                    text: qsTr("Send on LEZ")
                    onClicked: {
                        root.view = "lez";
                        if (root.backend) root.backend.loadWalletAccounts();
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.palette.borderSubtle }
        }
    }

    // Send assets via Logos (the LEZ) — Mode A: request → share → send.
    LezSend {
        objectName: "lezSendSurface"
        anchors.top: walletHeader.bottom
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.view === "lez"
        backend: root.backend
    }

    // The Account surface (AccountPage.qml).
    AccountPage {
        root: mainItem
        anchors.top: walletHeader.bottom
        anchors.left: contentArea.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
    }

    // ── the platform's signer (exo-d4d.2 R1) ─────────────────────────────
    // An approval made with a keystore_module account waits on a person in the platform's
    // signer (evm_signer_ui). The module answers "awaiting-approval" and lists the request;
    // here the view raises evm.signing.approve {handle} once per request, so the signer
    // comes forward with it. The callback is advisory: the request's state comes from the
    // module's poll (keystore_requests), which also advances it. `unavailable` means no
    // signer is installed (or access was denied): the person can still open it by hand, so
    // nothing is cancelled. In the standalone runner there is no intent broker at all.
    // What a fresh install still needs before money can move (exo-d4d.6): only where the
    // platform holds the keys (keystore_module attests muster); the runner shows nothing.
    readonly property var homeKeystore: {
        try { return JSON.parse(backend ? backend.keystoreStatusJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    readonly property var homeSetup: {
        var k = root.homeKeystore;
        if (!k.identity || k.identity.kind !== "module") return ({});
        if ((k.accounts || []).length === 0)
            return { show: true, action: "accounts", title: qsTr("Set up an Ethereum account"),
                     detail: qsTr("Your keys live in the Logos keystore, not in Muster. Create or import an account there; Muster asks it to sign, and you approve each signature in the Signer.") };
        if (!k.selected)
            return { show: true, action: "settings", title: qsTr("Choose the account Muster approves with"),
                     detail: qsTr("In Settings, pick one of your keystore accounts: it is what you pay from, what you are paid at, and what approves for you.") };
        if (k.binding !== "valid" && k.binding !== "expiring")
            return { show: true, action: "settings", title: qsTr("Link your account to your room identity"),
                     detail: qsTr("Approve the link in the Signer (Settings → Use for approvals), so the people in your rooms can tell your approvals are yours.") };
        return ({});
    }
    Timer {
        interval: 5000
        repeat: true
        triggeredOnStart: true
        running: root.ready && root.backend !== null && root.view === "home"
        onTriggered: root.backend.loadKeystoreStatus()
    }

    readonly property var keystoreRequests: {
        try { return JSON.parse(backend ? backend.keystoreRequestsJson : "{}") || ({}); }
        catch (e) { return ({}); }
    }
    property var escorted: ({})          // handle → what the shell answered
    property string signerNote: ""
    readonly property bool canRaiseIntents: typeof logos !== "undefined" && typeof logos.request === "function"
    function openSigner(handle) {
        if (!root.canRaiseIntents) {
            root.signerNote = qsTr("Approve it in the Logos Signer (this host has no app-to-app requests).");
            return;
        }
        logos.request("evm.signing.approve", { handle: handle }, function (res) {
            var e = String((res && res.error) || "");
            // No signer app answered, or the person turned down Basecamp's offer to install
            // one (exo-dcc.27): the request waits on an app that is not there, so say which
            // one and offer to install it.
            root.signerMissing = (e === "unavailable" || e === "cancelled");
            if (root.signerMissing)
                root.signerNote = qsTr("No Logos Signer answered: it is a separate app (evm_signer_ui). Install or open it, then approve there.");
            else if (e === "not_declared" || e === "bad_request" || e === "timeout" || e === "failed")
                root.signerNote = qsTr("The signer could not be opened (%1). Open the Logos Signer by hand.").arg(e);
        });
    }

    // Install what a proposal needs (exo-dcc.10). A card or the proposal form asks
    // Basecamp's Package Manager to open on a package (packages.install); the person
    // confirms in Basecamp's own install dialog. Muster installs nothing. An ok answer
    // means "Package Manager is open on it", never "installed": readiness says when the
    // module runs. One entry per package, shared by every card and the form:
    //   { state: "asking" | "open" | "unavailable" | "failed" | "cancelled" | "error",
    //     error, at (ms, when it answered), showError ("" or why packages.show failed) }
    // The answer is { ok, data, error } (the app-to-app broker's shape, as for the signer).
    property var packageRequests: ({})
    function notePackage(pkg, fields) {
        var m = Object.assign({}, root.packageRequests);
        m[pkg] = Object.assign({}, m[pkg] || {}, fields);
        root.packageRequests = m;
    }
    function requestPackageInstall(pkg, done) {
        var name = String(pkg || "");
        if (name.length === 0) return;
        var finish = function (res) {
            var e = String((res && res.error) || "");
            var ok = !!(res && res.ok);
            var st = ok ? "open" : (e === "unavailable" || e === "failed" || e === "cancelled") ? e : "error";
            root.notePackage(name, { state: st, error: e, at: Date.now(), showError: "" });
            if (typeof done === "function") done({ ok: ok, data: (res && res.data) || ({}), error: e });
        };
        // no app-to-app requests here (the standalone runner): there is no Package Manager
        if (!root.canRaiseIntents) { finish({ ok: false, data: ({}), error: "unavailable" }); return; }
        root.notePackage(name, { state: "asking", error: "", at: Date.now(), showError: "" });
        try { logos.request("packages.install", { name: name }, finish); }
        catch (x) { finish({ ok: false, data: ({}), error: "unavailable" }); }
    }
    // Open the Monero wallet (exo-dcc.5). A Monero request is vouched for and confirmed by
    // the requester's OWN open wallet, which muster never unlocks: it asks Monero Wallet.
    // With a wallet's registry name, monero.wallet.unlock opens that wallet's password
    // sheet and answers ok only once that wallet is open. The module names the wallet
    // (list_wallets, exo-dcc.20): the open one, or the one on the request's network, or —
    // several — the person picks one; only when none exists (or the list did not answer)
    // is none named, and monero.accounts.manage brings the app up to set one up.
    // The answer: { intent, wallet, state: "asking" | "open" | "unavailable" | "failed" |
    // "cancelled" | "error", error, at }.
    property var moneroWallet: ({})
    function openMoneroWallet(wallet) {
        var w = String(wallet || "");
        var intent = w.length > 0 ? "monero.wallet.unlock" : "monero.accounts.manage";
        var finish = function (res) {
            var e = String((res && res.error) || "");
            var ok = !!(res && res.ok);
            root.moneroWallet = { intent: intent, wallet: w, error: e, at: Date.now(),
                                  state: ok ? "open" : (e === "unavailable" || e === "cancelled") ? e
                                         : e.length > 0 ? "failed" : "error" };
        };
        if (!root.canRaiseIntents) { finish({ ok: false, error: "unavailable" }); return; }
        root.moneroWallet = { intent: intent, wallet: w, state: "asking", error: "", at: Date.now() };
        try { logos.request(intent, w.length > 0 ? { wallet: w } : ({}), finish); }
        catch (x) { finish({ ok: false, error: "unavailable" }); }
    }
    // Show the package in Package Manager (packages.show): offered when the install
    // request found nothing, so the person can check the catalogues there.
    function showPackage(pkg, done) {
        var name = String(pkg || "");
        if (name.length === 0) return;
        var finish = function (res) {
            var e = String((res && res.error) || "");
            var ok = !!(res && res.ok);
            root.notePackage(name, { showError: ok ? "" : (e.length > 0 ? e : "failed") });
            if (typeof done === "function") done({ ok: ok, data: (res && res.data) || ({}), error: e });
        };
        if (!root.canRaiseIntents) { finish({ ok: false, data: ({}), error: "unavailable" }); return; }
        try { logos.request("packages.show", { name: name }, finish); }
        catch (x) { finish({ ok: false, data: ({}), error: "unavailable" }); }
    }
    // The signer app the keystore names as its approver (exo-dcc.27): approvals and the
    // account's link to this identity wait on it, and it is not installed by default.
    property bool signerMissing: false
    readonly property string signerPackage: {
        try {
            var k = JSON.parse(root.backend ? root.backend.keystoreStatusJson : "{}") || ({});
            var a = Array.isArray(k.approvers) ? k.approvers : [];
            return a.length > 0 ? String(a[0]) : "evm_signer_ui";
        } catch (e) { return "evm_signer_ui"; }
    }
    function escortNew() {
        var rs = (root.keystoreRequests.requests || []);
        var open = 0;
        for (var i = 0; i < rs.length; i++) {
            var r = rs[i];
            var waiting = r.state === "waiting" || r.state === "shown";
            if (waiting) open++;
            // "shown" too: in Basecamp the Signer keeps running once opened, so it renders a
            // new request at once while the person is still in Muster (R6, 2026-10-07)
            if (waiting && r.handle && !root.escorted[r.handle]) {
                var m = Object.assign({}, root.escorted); m[r.handle] = true; root.escorted = m;
                root.signerNote = r.intentId ? qsTr("Approve this in the Logos Signer.")
                                             : qsTr("Approve linking this account to your room identity in the Logos Signer.");
                root.openSigner(r.handle);
            }
        }
        if (open === 0 && root.signerNote.length > 0 && rs.length > 0) {
            var last = rs[rs.length - 1];
            root.signerNote = last.state === "approved" ? ""
                : (last.state ? qsTr("Signer: %1 %2").arg(last.state).arg(last.reason || "") : "");
        }
    }
    onKeystoreRequestsChanged: escortNew()
    Timer {
        // reading keystore_requests advances them; while any waits, read every 1.5 s, else
        // every 5 s so a request made elsewhere (Settings' account link) is still escorted
        interval: (root.keystoreRequests.requests || []).some(function (r) { return r.state === "waiting" || r.state === "shown"; }) ? 1500 : 5000
        repeat: true
        running: root.ready && root.backend !== null
        onTriggered: root.backend.loadKeystoreRequests()
    }
    Rectangle {
        visible: root.signerNote.length > 0
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spacing.medium
        z: 100
        radius: 8
        color: Theme.palette.surface
        border.color: Theme.palette.warning
        implicitWidth: Math.min(signerRow.implicitWidth + 2 * Theme.spacing.medium, parent.width - 2 * Theme.spacing.medium)
        implicitHeight: signerRow.implicitHeight + 2 * Theme.spacing.small
        width: implicitWidth
        height: implicitHeight
        RowLayout {
            id: signerRow
            anchors.centerIn: parent
            spacing: Theme.spacing.small
            LogosText {
                text: root.signerNote
                color: Theme.palette.textSecondary
                font.pixelSize: MusterStyle.caption
            }
            ActionButton {
                objectName: "signerInstall"
                visible: root.signerMissing
                text: qsTr("Install the Logos Signer")
                onClicked: root.requestPackageInstall(root.signerPackage)
            }
            ActionButton {
                text: qsTr("Dismiss")
                onClicked: root.signerNote = ""
            }
        }
    }
}
