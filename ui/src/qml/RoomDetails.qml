import QtQuick
import QtQuick.Layouts

import Logos.Theme

// The room's right-hand column (exo-720.3, moved verbatim out of Room.qml):
// connections, accounts, history, who can see what, and the roster. Each `room.x` is
// the Room's own state, as before the move.
// Right: the room's meta-state — its history (how it got here) on top, then
// who can see this (the roster + scope). Both are folds of the same sealed
// log; the handshake signals go to the module through the backend.
ColumnLayout {
    required property var room   // the Room this piece belongs to (Room.qml's roomItem)

    visible: room.joined
    Layout.preferredWidth: 320
    Layout.fillHeight: true
    spacing: Theme.spacing.large

    // The connections and accounts block is taller than a window (Safe, Bitcoin,
    // FROST and LEZ multisig sections), and it used to set the whole room's height —
    // pushing the message row and its "+" below the bottom of a normal window
    // (exo-9a4). It scrolls in its own share of the column now, as the history and
    // the scope below it do; its width stays its natural width. When an add-an-account
    // form opens it scrolls to show it, since the forms sit at the end (exo-dcc.30).
    Flickable {
        id: accountsFlick
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: 2
        implicitWidth: topCol.implicitWidth
        clip: true
        contentWidth: width
        contentHeight: topCol.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        function showEnd() { contentY = Math.max(0, contentHeight - height); }
        // after the layout has taken the newly shown form's height
        Timer { id: accountsFollow; interval: 60; onTriggered: accountsFlick.showEnd() }

    ColumnLayout {
        id: topCol
        width: parent.width
        spacing: Theme.spacing.large

    // What the room depends on, and whether it's actually there (invariant 8).
    ConnectionIndicators {
        Layout.fillWidth: true
        status: room.connectivity
    }

    // The accounts members have disclosed into this room (exo-a50.1.3).
    RoomAccounts {
        Layout.fillWidth: true
        accounts: room.roomAccounts
        // The composer was refused for want of an account this kind can act from:
        // open the form that discloses one (exo-dcc.30).
        wantedFamilies: {
            var e = room.policyError || {};
            if (e.error !== "no-account" || !room.kindNeedsAccount(room.policyKind)) return [];
            var info = room.kindInfo(room.policyKind);
            return (info && info.accountFamilies) ? info.accountFamilies : [];
        }
        discloseResult: room.discloseResult
        suggestionAvailable: {
            try { return JSON.parse(room.backend ? room.backend.accountJson : "{}").available !== false; }
            catch (e) { return true; }
        }
        defaultChainId: {
            try { return String(JSON.parse(room.backend ? room.backend.accountJson : "{}").defaultChainId || "31337"); }
            catch (e) { return "31337"; }
        }
        lezMember: room.lezMember
        lezCreate: room.lezCreate
        frostCeremonies: room.frostCeremonies
        frostCeremony: room.frostCeremony
        onFrostOpenRequested: function (cid, network, t, n) {
            if (room.backend) room.backend.frostCeremonyOpen(cid, network, t, n);
        }
        onFrostJoinRequested: function (cid) { if (room.backend) room.backend.frostCeremonyJoin(cid); }
        onDiscloseRequested: function (accountJson) { if (room.backend) room.backend.discloseAccount(accountJson); }
        onLezMemberRequested: if (room.backend) room.backend.lezMemberAccount("")
        onLezCreateRequested: function (threshold, members) {
            if (room.backend) room.backend.lezCreateMultisig(threshold, members);
        }
        onDiscloseSuggested: if (room.backend) room.backend.discloseSuggestedAccount()
        onFormShown: accountsFollow.restart()
    }
    }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.palette.borderSubtle
    }

    // History first — paramount to the education mission: a member sees the
    // decisions that led to the current state, and each update as it lands.
    ActivityFeed {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: 1     // share the column with the scope panel
        entries: room.activity
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.palette.borderSubtle
    }

    // Who can see what — the information-flow view folded from the same log
    // (exo-002.5). The store node is always listed (FS-9).
    FlowView {
        objectName: "flowView"
        Layout.fillWidth: true
        flow: room.flow
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.palette.borderSubtle
    }

    ScopePanel {
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredHeight: 1
        members: room.members
        pending: room.pending
        topic: room.topic
        joinStatus: room.backend ? String(room.backend.joinStatus || "") : ""
        founder: room.founded
        securityLevels: room.securityLevels
        onRequestJoin: if (room.backend) room.backend.requestJoin()
        onAdmit: function(identityHex) {
            if (!room.backend) return;
            room.backend.admit(identityHex);
            // The admit re-keyed the room to a new epoch the joiner now shares.
            // Anything from before their epoch is unreadable to them (F-16), so
            // re-send it into the new epoch: an unanswered address request, and any
            // open proposal (its card) — otherwise a payment proposed before they
            // joined never reaches them to approve.
            room.resendOutstandingAsk();
            room.backend.reannounce();
        }
    }
}
