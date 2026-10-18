import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui
import "poker.js" as Poker

// Texas Hold'em for omarchy-shell. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.omarchyholdem
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// Five seats: the human always sits at the bottom, one to four bots fill the
// rest, and the dealer — the deck, the muck and the button — lives in the
// middle. No-limit betting, 10/20 blinds, 1,000 buy-in.
//
// The engine is NOT in this file. poker.js holds the whole game as pure,
// serialisable functions over one state object; this file is the table that
// state sits on: it drives the engine (human actions from the buttons, bot
// actions from a timer), re-renders from it, and writes it to disk. Because
// the state is plain JSON, a hand in progress survives a shell restart and
// resumes on the exact seat that was due to act.
//
// Rendering follows the solitaire panel's architecture, which worked: the
// model is 52 card ids; one pure layout function turns the state into a
// position record per card bound through `rev`; delegates bind to their
// record with a Behaviour, so every deal, muck and reveal animates itself.
// Dealing is not modelled — cards sit on the deck in the layout until a
// pacing counter releases them, so the deal is a pure visual lag.

Item {
    id: root

    property bool opened: false

    readonly property string selfId: "nosignal.omarchyholdem"

    // Injected by the shell host after the Loader resolves. Used to keep the
    // host's open-flag honest on close(), and to self-restore if the host's
    // panel Instantiator rebuild destroys a visibly-open instance.
    property var shell: null
    onShellChanged: {
        if (!root.opened && root.shell && root.shell.openPanelIds && root.shell.openPanelIds[root.selfId] === true)
            root.open("{}");
    }

    // ------------------------------------------------------------------ theme
    //
    // Shares the [menu] surface tokens so themes that style the menu style this
    // panel too. The chrome around the felt follows the theme; the felt itself
    // is pinned casino green — see the felt property below.
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color border: Color.menu.border
    property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
    property color accent: Color.accent
    property color urgent: Color.urgent
    readonly property int cornerRadius: Style.cornerRadius
    property string fontFamily: Style.font.menuFamily
    property int contentMargin: Style.spacing.panelPadding

    // Winner's gold and a warm cream, both pinned — the table keeps casino
    // colours the way a casino floor does, whatever the desktop wears. Theme
    // text runs blue-white on some themes and reads cold against the felt.
    readonly property color gold: "#d9b45a"
    readonly property color cream: "#f0e7d4"

    function mix(a, b, t) {
        var bb = typeof b === "string" ? Qt.color(b) : b;
        return Qt.rgba(a.r + (bb.r - a.r) * t, a.g + (bb.g - a.g) * t, a.b + (bb.b - a.b) * t, 1);
    }
    // The felt is a pinned casino green — a poker table is green whatever the
    // desktop wears. The chrome around it (header, buttons, borders) keeps
    // following the theme, but the table itself is where you sat down to play.
    // Markings mix up toward a pale green the way the classic felt does.
    readonly property color felt: "#2f6a4d"
    readonly property color feltLine: root.mix(root.felt, "#eaf7ef", 0.30)

    // ------------------------------------------------------- self-registration

    // `omarchy plugin enable` only writes the bar.layout entry for a
    // panel+bar-widget plugin, so the keybinding dies with the bar icon unless
    // the plugin claims its own plugins[] entry. Upstream fix is PR #6510; until
    // it lands, self-register on first open. Idempotent, jq-guarded.
    //
    // Harness: sh -c <script> plugin-selfref <id> — $0 is the label, $1 the id.
    // The id arrives as an argument rather than spliced into the script, so no
    // text is ever interpolated into shell code. The rewrite refuses to follow a
    // symlink, keeps the working copy private, and carries the original file's
    // mode across so a hand-tightened shell.json is not widened by the swap.
    property bool selfRefEnsured: false
    readonly property string ensureSelfRefScript: ['umask 077', 'id="$1"', 'f="$HOME/.config/omarchy/shell.json"', '[ -f "$f" ] || exit 0', '[ -L "$f" ] && exit 0', 'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0', 'tmp="$f.selfref.$$"', 'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {', '  rm -f "$tmp"; exit 1;', '}', '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }', 'chmod --reference="$f" "$tmp" 2>/dev/null || chmod 600 "$tmp"', 'mv "$tmp" "$f"'].join("\n")

    function ensureSelfReference() {
        if (root.selfRefEnsured)
            return;
        root.selfRefEnsured = true;
        Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId]);
    }

    // ------------------------------------------------------------- game state
    //
    // `g` is the engine's state object, deep-copied on every commit so QML sees
    // a fresh reference and every binding re-evaluates. Nothing in QML mutates
    // it — the engine owns the rules, this file owns the timers and the paint.

    property var g: null
    property int rev: 0
    property int lastSeenHand: -1

    function commit(ng) {
        root.g = JSON.parse(JSON.stringify(ng));
        root.rev++;
        syncPacing();
        // A bot-to-bot chain keeps botTurn true through the handover, so the
        // timer would ride a stale interval; restart it for a fresh think each
        // time the action moves.
        if (root.botTurn)
            botThink.restart();
        root.save();
    }

    function seat(s) {
        return root.g ? root.g.seats[s] : null;
    }

    // Money is dollars. Every value on the table — stacks, blinds, bets, the
    // pot, winnings — goes through here, so the sign lives in one place.
    function fmt(n) {
        var s = Math.round(n).toString();
        var out = "";
        while (s.length > 3) {
            out = "," + s.slice(-3) + out;
            s = s.slice(0, -3);
        }
        return "$" + s + out;
    }

    // --------------------------------------------------------- pacing the deal
    //
    // Two lag counters release cards from the deck: hole cards walk out two
    // rounds around the table, board cards drop one at a time. The engine
    // deals instantly; this is pure theatre for the eye.

    property int holeShown: 0
    property int shownCommunity: 0
    property int holeTarget: 0
    property int commTarget: 0
    property var dealSeq: []          // [{seat, j}] in deal order

    function syncPacing() {
        if (!root.g) {
            root.holeTarget = 0;
            root.commTarget = 0;
            return;
        }
        if (root.g.handNum !== root.lastSeenHand) {
            root.lastSeenHand = root.g.handNum;
            root.holeShown = 0;
            root.shownCommunity = 0;
            buildDealSeq();
        }
        var sitting = 0;
        for (var i = 0; i < 5; i++)
            if (root.g.seats[i].sitting)
                sitting++;
        root.holeTarget = 2 * sitting;
        root.commTarget = root.g.community.length;
    }

    function buildDealSeq() {
        var seq = [];
        if (!root.g || root.g.sbSeat < 0) {
            root.dealSeq = seq;
            return;
        }
        var cur = root.g.sbSeat;
        for (var round = 0; round < 2; round++) {
            for (var n = 0; n < 5; n++) {
                if (root.g.seats[cur].sitting)
                    seq.push({
                        seat: cur,
                        j: round
                    });
                cur = (cur + 1) % 5;
            }
        }
        root.dealSeq = seq;
    }

    // Deal order is rounds of seats, each seat's pair dealt card by card, so a
    // card's ordinal is its index in that walk.
    function holeOrdinal(s, j) {
        for (var i = 0; i < root.dealSeq.length; i++) {
            var d = root.dealSeq[i];
            if (d.seat === s && d.j === j)
                return i;
        }
        return 999;
    }

    Timer {
        id: dealPacer
        interval: 90
        repeat: true
        running: root.opened && (root.holeShown < root.holeTarget || root.shownCommunity < root.commTarget)
        onTriggered: {
            if (root.holeShown < root.holeTarget)
                root.holeShown++;
            else if (root.shownCommunity < root.commTarget)
                root.shownCommunity++;
        }
    }

    // ------------------------------------------------------------ table turns

    readonly property bool humanTurn: root.g !== null && root.g.phase === "betting" && root.g.actor === 0
    readonly property var humanLegal: humanTurn ? Poker.legalActions(root.g) : null

    // The raise stepper. Reset to a sane three-quarters-pot default every time
    // the turn comes around; the presets and arrows move it from there.
    property int raiseTo: 0

    onHumanTurnChanged: {
        if (!humanTurn || !humanLegal)
            return;
        var pot = humanLegal.potNow;
        var want = humanLegal.toCall + root.round10(pot * 0.75);
        if (want < humanLegal.minTo)
            want = humanLegal.minTo;
        if (want > humanLegal.maxTo)
            want = humanLegal.maxTo;
        root.raiseTo = want;
    }
    function round10(x) {
        return Math.max(10, Math.round(x / 10) * 10);
    }

    function humanAct(type, amount) {
        if (!humanTurn)
            return;
        if (amount !== undefined)
            commit(Poker.act(root.g, type, amount));
        else
            commit(Poker.act(root.g, type));
    }

    function adjustRaise(delta) {
        if (!humanLegal)
            return;
        var to = root.raiseTo + delta;
        if (to > humanLegal.maxTo)
            to = humanLegal.maxTo;
        if (to < humanLegal.minTo)
            to = humanLegal.minTo;
        root.raiseTo = to;
    }

    function presetRaise(frac) {         // frac 0 = min, 1 = all-in
        if (!humanLegal)
            return;
        var to;
        if (frac <= 0)
            to = humanLegal.minTo;
        else if (frac >= 1)
            to = humanLegal.maxTo;
        else
            to = humanLegal.toCall + root.round10(humanLegal.potNow * frac);
        root.raiseTo = Math.max(humanLegal.minTo, Math.min(humanLegal.maxTo, to));
    }

    // Bots act on a timer so their raises land at a human pace. The delay is
    // redrawn each commit, so long tanks and snap calls both happen.
    readonly property bool botTurn: root.g !== null && root.g.phase === "betting" && root.g.actor >= 0 && root.g.seats[root.g.actor].bot
    property int botDelay: 700

    Timer {
        id: botThink
        interval: root.botDelay
        running: root.opened && root.botTurn
        onTriggered: {
            if (!root.botTurn)
                return;
            var d = Poker.botDecision(root.g);
            commit(Poker.act(root.g, d.type, d.amount !== undefined ? d.amount : 0));
        }
    }
    onBotTurnChanged: if (botTurn)
        root.botDelay = 600 + Math.floor(Math.random() * 750)

    // Between hands the next deal is deliberate — Space or the button — so a
    // showdown can be read before the chips vanish into the next blind.
    function nextHand() {
        if (!root.g)
            return;
        if (root.g.phase === "handOver")
            commit(Poker.startHand(root.g));
    }

    function startSession(botCount) {
        var stats = root.g ? root.g.stats : null;
        var fresh = Poker.newSession(botCount);
        if (stats)
            fresh.stats = stats;
        Poker.startHand(fresh);
        commit(fresh);
    }

    function newSession() {
        root.g = null;
        root.rev++;
        root.save();
    }

    // ------------------------------------------------------------- persistence

    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: root.home + "/.local/state/omarchy-holdem"
    readonly property string statePath: root.stateDir + "/state.json"
    property bool stateLoaded: false

    function save() {
        if (!root.stateLoaded)
            return;
        saveTimer.restart();
    }

    // Debounced: bot turns fire a commit every second at most, and this keeps
    // even a frantic run to one atomic write per pause.
    Timer {
        id: saveTimer
        interval: 400
        repeat: false
        onTriggered: {
            var payload = JSON.stringify({
                version: 2,
                g: root.g
            }, null, 2) + "\n";
            stateFile.setText(payload);
        }
    }

    // A saved session is only trusted if every one of the 52 cards is accounted
    // for exactly once across deck, board, hands and muck — a truncated or
    // hand-edited file sends the player back to the setup screen instead of
    // half a table.
    function validState(g) {
        if (!g || typeof g !== "object" || g.v !== 2)
            return false;
        if (!Array.isArray(g.seats) || g.seats.length !== 5)
            return false;
        if (["idle", "betting", "handOver", "sessionOver"].indexOf(g.phase) < 0)
            return false;
        var seen = {};
        var n = 0;
        function claim(arr) {
            if (!Array.isArray(arr))
                return false;
            for (var i = 0; i < arr.length; i++) {
                var v = arr[i];
                if (typeof v !== "number" || v < 0 || v > 51 || seen[v])
                    return false;
                seen[v] = true;
                n++;
            }
            return true;
        }
        if (!claim(g.deck) || !claim(g.community) || !claim(g.mucked))
            return false;
        for (var i = 0; i < 5; i++) {
            var s = g.seats[i];
            if (!s || typeof s !== "object")
                return false;
            if (typeof s.chips !== "number" || s.chips < 0)
                return false;
            if (!claim(s.hole))
                return false;
        }
        if (n !== 52)
            return false;
        return true;
    }

    function applyState(raw) {
        var st = null;
        try {
            st = JSON.parse(String(raw || "").trim());
        } catch (e) {}

        if (st && typeof st === "object" && st.version === 2 && validState(st.g)) {
            root.g = st.g;
            root.lastSeenHand = root.g.handNum;
            buildDealSeq();
            var sitting = 0;
            for (var i = 0; i < 5; i++)
                if (root.g.seats[i].sitting)
                    sitting++;
            root.holeTarget = 2 * sitting;
            root.holeShown = root.holeTarget;
            root.commTarget = root.g.community.length;
            root.shownCommunity = root.commTarget;
            root.stateLoaded = true;
            return;
        }

        root.stateLoaded = true;       // fresh setup screen; session starts on pick
    }

    FileView {
        id: stateFile
        path: root.statePath
        atomicWrites: true
        printErrors: false
        onLoaded: root.applyState(text())
        onLoadFailed: function (err) {
            root.applyState("");
        }
    }

    // Make sure the state dir exists, then (re)load the state file.
    Process {
        id: mkStateDir
        command: ["mkdir", "-p", root.stateDir]
        onExited: stateFile.reload()
    }

    Component.onCompleted: mkStateDir.running = true

    // ------------------------------------------------------------- open/close

    function open(payloadJson) {
        root.opened = true;
        root.ensureSelfReference();
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        if (!root.opened)
            return;
        root.opened = false;
        if (root.stateLoaded)
            saveTimer.restart();   // flush anything not yet written
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.selfId);
    }

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.open("{}");
    }

    // ------------------------------------------------------------------ layout
    //
    // One pure function turns the model into 52 positioned records plus the
    // plate and board geometry. Everything visual reads out of here.

    readonly property real tableW: table.width
    readonly property real tableH: table.height

    readonly property int cardW: {
        var byWidth = root.tableW / 13.5;
        var byHeight = (root.tableH / 5.0) / 1.4;
        return Math.max(44, Math.floor(Math.min(byWidth, byHeight)));
    }
    // 5:7, the aspect the bundled deck is drawn at.
    readonly property int cardH: Math.round(root.cardW * 1.4)

    // Seat anchors, as fractions of the table, filled from the middle out: the
    // human holds bottom centre, the first two bots flank them close, and the
    // last pair sits outboard. Every addition keeps the arc as symmetric as
    // the count allows.
    readonly property var seatPos: [
        { x: 0.50, y: 0.87 },
        { x: 0.32, y: 0.78 },
        { x: 0.68, y: 0.78 },
        { x: 0.12, y: 0.62 },
        { x: 0.88, y: 0.62 }
    ]

    readonly property var layout: root.computeLayout(root.rev, root.cardW, root.cardH, root.tableW, root.tableH)

    function computeLayout(rev, cw, ch, tw, th) {
        var g = root.g;
        var cards = [];
        var i;
        for (i = 0; i < 52; i++)
            cards.push({
                x: 0,
                y: 0,
                z: 0,
                up: false,
                pile: "none",
                idx: -1
            });

        var gap = Math.max(4, Math.round(cw * 0.12));
        var commW = 5 * cw + 4 * gap;
        var commLeft = Math.round((tw - commW) / 2);
        var commY = Math.round(th * 0.24) - Math.round(ch / 2);
        // The dealer spot: centre of the board. Undealt and pending cards wait
        // there face down and fly out from it — there is no visible deck pile.
        var dealerX = Math.round(tw / 2 - cw / 2);

        // plate geometry, shared with the seat delegates. `pairs` is where each
        // seat's hole cards land — the ghost outlines sit exactly there, so a
        // dealt hand fills its outline.
        var pw = Math.max(130, Math.min(200, Math.round(tw * 0.155)));
        var ph = Math.max(40, Math.min(50, Math.round(th * 0.062)));
        var plates = [];
        var pairs = [];
        for (i = 0; i < 5; i++) {
            var p = root.seatPos[i];
            plates.push({
                x: Math.round(p.x * tw - pw / 2),
                y: Math.round(p.y * th - ph / 2),
                w: pw,
                h: ph
            });
            pairs.push({
                x: Math.round(p.x * tw - cw - 3),
                y: Math.round(p.y * th - ph / 2 - ch - 8),
                visible: false
            });
        }

        if (!g) {
            return {
                cards: cards,
                plates: plates,
                pairs: pairs,
                commLeft: commLeft,
                commY: commY,
                gap: gap,
                cw: cw,
                ch: ch,
                dealerX: dealerX,
                potY: commY + ch + 12,
            };
        }

        // Board cards: at the dealer until the pacer releases them, then their
        // slot.
        for (i = 0; i < g.community.length; i++) {
            var c = g.community[i];
            var onTable = i < root.shownCommunity;
            cards[c] = {
                x: onTable ? commLeft + i * (cw + gap) : dealerX,
                y: commY,
                z: onTable ? 200 + i : 30 + i,
                up: true,
                pile: "comm",
                idx: i
            };
        }

        // Hole cards, dealt from the dealer spot down to the seats. Every seat
        // hangs its pair above its plate, toward the dealer — the arc opens
        // upward, so one rule places all five and nothing collides.
        for (var s = 0; s < 5; s++) {
            var seat = g.seats[s];
            if (!seat || !seat.sitting)
                continue;
            pairs[s].visible = true;
            for (var j = 0; j < seat.hole.length; j++) {
                var ord = root.holeOrdinal(s, j);
                var shown = ord < root.holeShown;
                var pl = plates[s];
                var up = s === 0 || seat.revealed === true;
                cards[seat.hole[j]] = {
                    x: shown ? Math.round(pl.x + pl.w / 2 - cw - 3 + j * (cw + 6)) : dealerX,
                    y: shown ? Math.round(pl.y - ch - 8) : commY,
                    z: shown ? 100 + s * 10 + j : 40 + ord,
                    up: up,
                    pile: "hole" + s,
                    idx: j
                };
            }
        }

        // Mucked cards fly to the dealer and fade out — the delegate renders the
        // "muck" pile at zero opacity, so the flight is all the discard shows.
        for (i = 0; i < g.mucked.length; i++)
            cards[g.mucked[i]] = {
                x: dealerX,
                y: commY,
                z: 50 + i,
                up: false,
                pile: "muck",
                idx: i
            };

        return {
            cards: cards,
            plates: plates,
            pairs: pairs,
            commLeft: commLeft,
            commY: commY,
            gap: gap,
            cw: cw,
            ch: ch,
            dealerX: dealerX,
            potY: commY + ch + 12,
        };
    }

    // --------------------------------------------------------- log formatting
    //
    // The action ticker reads the engine's event log. Cards appear as letters
    // ("Kh 9s 4d") — the Unicode suit glyphs resolve through font fallback and
    // do not all land in the same font, the same trap the solitaire notes hit.

    function seatName(s) {
        var st = root.seat(s);
        return st ? st.name : "?";
    }

    function formatEvent(ev) {
        if (ev.k === "hand")
            return "— Hand #" + ev.n + " —";
        if (ev.k === "blind")
            return root.seatName(ev.seat) + " posts " + ev.label + " of " + root.fmt(ev.amount);
        if (ev.k === "act") {
            var n = root.seatName(ev.seat);
            if (ev.type === "fold")
                return n + " folds";
            if (ev.type === "check")
                return n + " checks";
            if (ev.type === "call")
                return n + " calls " + root.fmt(ev.amount) + (ev.allIn ? ", all-in" : "");
            if (ev.type === "raise")
                return n + (ev.allIn ? " is all-in for " : " raises to ") + root.fmt(ev.to);
        }
        if (ev.k === "street") {
            var label = ev.street === 1 ? "Flop" : ev.street === 2 ? "Turn" : "River";
            return label + ": " + ev.cards.join(" ");
        }
        if (ev.k === "reveal")
            return "Hands on their backs";
        if (ev.k === "win")
            return root.seatName(ev.seat) + " wins " + root.fmt(ev.amount) + (ev.name ? " — " + ev.name : "");
        if (ev.k === "return")
            return root.fmt(ev.amount) + " returned to " + root.seatName(ev.seat);
        if (ev.k === "elim")
            return root.seatName(ev.seat) + " busts out";
        if (ev.k === "bust")
            return "You are felted.";
        if (ev.k === "swept")
            return "The table is yours.";
        return "";
    }

    // Last three events, newest first, for the ticker in the felt's corner.
    function recentLog() {
        var out = [];
        if (!root.g)
            return out;
        for (var i = root.g.log.length - 1; i >= 0 && out.length < 3; i--) {
            var t = root.formatEvent(root.g.log[i]);
            if (t !== "")
                out.push(t);
        }
        return out;
    }

    // Each seat's most recent action this hand, for the badge on its plate.
    function lastActionFor(s) {
        if (!root.g)
            return null;
        for (var i = root.g.log.length - 1; i >= 0; i--) {
            var ev = root.g.log[i];
            if (ev.k === "hand")
                return null;
            if (ev.k === "blind" && ev.seat === s)
                return {
                    text: (ev.label === "small blind" ? "Small blind " : "Big blind ") + root.fmt(ev.amount)
                };
            if (ev.k === "act" && ev.seat === s) {
                if (ev.type === "fold")
                    return {
                        text: "Fold"
                    };
                if (ev.type === "check")
                    return {
                        text: "Check"
                    };
                if (ev.type === "call")
                    return {
                        text: "Call " + root.fmt(ev.amount) + (ev.allIn ? " · all-in" : "")
                    };
                if (ev.type === "raise")
                    return {
                        text: (ev.allIn ? "All-in " : "Raise to ") + root.fmt(ev.to)
                    };
            }
            if (ev.k === "win" && ev.seat === s)
                return {
                    text: "Wins " + root.fmt(ev.amount),
                    gold: true
                };
        }
        return null;
    }

    function isWinner(s) {
        if (!root.g || !root.g.results)
            return false;
        for (var i = 0; i < root.g.results.wins.length; i++)
            if (root.g.results.wins[i].seat === s)
                return true;
        return false;
    }

    // Card artwork — the bundled deck, same as ever. Files are named by the
    // standard card code (AH, 10D, QC, KS …), which the engine's rank and suit
    // indices address directly.
    readonly property url backImage: Qt.resolvedUrl("cards/back.png")
    readonly property url tableImage: Qt.resolvedUrl("cards/table.png")
    function cardImage(cid) {
        var letters = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"];
        var suits = ["S", "H", "D", "C"];
        return Qt.resolvedUrl("cards/" + letters[Poker.rankOf(cid) - 1] + suits[Poker.suitOf(cid)] + ".png");
    }

    // Suits are drawn, not typed. The Unicode suit characters come from
    // whichever font in the fallback chain happens to own them, and that is not
    // the same font for all four — hearts arrived outlined while the other three
    // were solid — nor the same on anyone else's machine. These are outlines in
    // a 100x100 box, filled by Shape, so all four match at any size and take
    // their colour from the theme. The felt's ghost pips under the board are
    // the one place they still appear.
    readonly property var suitPaths: [
        // spade: inverted heart over a splayed stem
        "M 50 6 C 50 6 94 40 94 60 C 94 72 85 80 75 80 C 66 80 58 74 55 66" + " C 55 74 58 86 65 94 L 35 94 C 42 86 45 74 45 66 C 42 74 34 80 25 80" + " C 15 80 6 72 6 60 C 6 40 50 6 50 6 Z",
        // heart
        "M 50 92 C 50 92 6 61 6 33 C 6 18 18 8 30 8 C 40 8 47 14 50 21" + " C 53 14 60 8 70 8 C 82 8 94 18 94 33 C 94 61 50 92 50 92 Z",
        // diamond
        "M 50 5 L 91 50 L 50 95 L 9 50 Z",
        // club: three lobes over a stem
        "M 50 5 C 61 5 70 14 70 25 C 70 29 69 33 67 36 C 70 34 74 33 78 33" + " C 89 33 98 42 98 53 C 98 64 89 73 78 73 C 68 73 60 66 58 57" + " C 57 68 60 84 66 95 L 34 95 C 40 84 43 68 42 57 C 40 66 32 73 22 73" + " C 11 73 2 64 2 53 C 2 42 11 33 22 33 C 26 33 30 34 33 36" + " C 31 33 30 29 30 25 C 30 14 39 5 50 5 Z"]

    // A suit, filled, scaled into whatever box it is given.
    component SuitPip: Item {
        id: pipRoot
        property int suit: 0
        property color pipColor: "#000000"
        Shape {
            width: 100
            height: 100
            transform: Scale {
                xScale: pipRoot.width / 100
                yScale: pipRoot.height / 100
            }
            ShapePath {
                fillColor: pipRoot.pipColor
                strokeWidth: 0
                strokeColor: "transparent"
                PathSvg {
                    path: root.suitPaths[pipRoot.suit]
                }
            }
        }
    }

    // A poker chip, drawn: gold body, a thin ring in from the rim, and the
    // four classic edge spots as short arcs. Pure shapes so it stays crisp
    // at any size and keeps the casino palette.
    component ChipIcon: Item {
        id: chipRoot
        property color bodyColor: root.gold
        property color spotColor: "#173826"

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: chipRoot.bodyColor
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.56
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1, parent.width * 0.06)
            border.color: chipRoot.spotColor
        }
        Shape {
            anchors.fill: parent
            ShapePath {
                fillColor: "transparent"
                strokeColor: chipRoot.spotColor
                strokeWidth: chipRoot.width * 0.14
                PathAngleArc {
                    centerX: chipRoot.width / 2
                    centerY: chipRoot.height / 2
                    radiusX: chipRoot.width * 0.42
                    radiusY: chipRoot.width * 0.42
                    startAngle: 270
                    sweepAngle: 42
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: chipRoot.spotColor
                strokeWidth: chipRoot.width * 0.14
                PathAngleArc {
                    centerX: chipRoot.width / 2
                    centerY: chipRoot.height / 2
                    radiusX: chipRoot.width * 0.42
                    radiusY: chipRoot.width * 0.42
                    startAngle: 0
                    sweepAngle: 42
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: chipRoot.spotColor
                strokeWidth: chipRoot.width * 0.14
                PathAngleArc {
                    centerX: chipRoot.width / 2
                    centerY: chipRoot.height / 2
                    radiusX: chipRoot.width * 0.42
                    radiusY: chipRoot.width * 0.42
                    startAngle: 90
                    sweepAngle: 42
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: chipRoot.spotColor
                strokeWidth: chipRoot.width * 0.14
                PathAngleArc {
                    centerX: chipRoot.width / 2
                    centerY: chipRoot.height / 2
                    radiusX: chipRoot.width * 0.42
                    radiusY: chipRoot.width * 0.42
                    startAngle: 180
                    sweepAngle: 42
                }
            }
        }
    }

    // ------------------------------------------------------------------- panel

    PanelWindow {
        id: panel
        visible: root.opened
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        WlrLayershell.namespace: "omarchy-holdem"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        exclusionMode: ExclusionMode.Ignore

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        BorderSurface {
            id: surface
            width: Math.min(Style.space(1272), panel.width - Style.gapsOut * 2)
            height: Math.min(Style.space(912), panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2)
            anchors.centerIn: parent
            radius: root.cornerRadius
            color: root.background
            borderSpec: root.borderSpec
            padding: root.contentMargin
            clip: true

            // Swallow clicks so the felt doesn't fall through to the close-on-click
            // backdrop.
            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true
                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
                        root.close();
                    } else if (event.key === Qt.Key_Space) {
                        if (root.g === null || root.g.phase === "idle")
                            root.startSession(setup.botCount);
                        else
                            root.nextHand();
                    } else if (event.key === Qt.Key_N) {
                        root.newSession();
                    } else if (event.key === Qt.Key_F) {
                        root.humanAct("fold");
                    } else if (event.key === Qt.Key_C) {
                        if (root.humanLegal)
                            root.humanAct(root.humanLegal.canCheck ? "check" : "call");
                    } else if (event.key === Qt.Key_R || event.key === Qt.Key_Enter || event.key === Qt.Key_Return) {
                        if (root.humanLegal && root.humanLegal.canRaise)
                            root.humanAct("raise", root.raiseTo);
                    } else if (event.key === Qt.Key_A) {
                        root.presetRaise(1);
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Right) {
                        root.adjustRaise(root.g ? root.g.bb : 20);
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Left) {
                        root.adjustRaise(-(root.g ? root.g.bb : 20));
                    } else {
                        return;
                    }
                    event.accepted = true;
                }
            }

            // ------------------------------------------------------------- header
            Item {
                id: header
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: surface.contentTopInset
                anchors.leftMargin: surface.contentLeftInset
                anchors.rightMargin: surface.contentRightInset
                height: Math.max(title.implicitHeight, controls.implicitHeight)

                Text {
                    id: title
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "♠  Omarchy Hold'em"
                    color: root.gold
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                }

                Row {
                    id: controls
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.sm

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.g && root.g.handNum > 0 ? "Hand " + root.g.handNum + "  ·  Small blind " + root.fmt(root.g.sb) + "  ·  Big blind " + root.fmt(root.g.bb) : "No-limit Texas Hold'em  ·  Small blind " + Poker.SB + "  ·  Big blind " + Poker.BB + "  ·  Buy-in " + root.fmt(Poker.START_STACK)
                        color: root.foreground
                        opacity: 0.55
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                    }

                    Button {
                        accent: root.gold
                        text: "New session"
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: "Back to the setup screen  (n)"
                        onClicked: root.newSession()
                    }
                }
            }

            Item {
                id: statusRow
                anchors.top: header.bottom
                anchors.left: header.left
                anchors.right: header.right
                anchors.topMargin: Style.spacing.xs
                height: statusLeft.implicitHeight + Style.spacing.sm

                Text {
                    id: statusLeft
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (!root.g)
                            return "";
                        var bits = [];
                        if (root.g.phase === "betting" || root.g.phase === "handOver")
                            bits.push("Pot " + root.fmt(Poker.potNow(root.g)));
                        if (root.g.seats[0].sitting)
                            bits.push("Your stack " + root.fmt(root.g.seats[0].chips));
                        var s = root.g.stats;
                        if (s && s.hands > 0)
                            bits.push("Hands " + s.hands + "  ·  Biggest pot " + root.fmt(s.biggestPot));
                        return bits.join("   ·   ");
                    }
                    color: root.foreground
                    opacity: 0.65
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "f fold · c call · r raise · space next hand · esc close"
                    color: root.foreground
                    opacity: 0.4
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }

            PanelSeparator {
                id: sep
                anchors.top: statusRow.bottom
                anchors.left: header.left
                anchors.right: header.right
                anchors.topMargin: Style.spacing.sm
            }

            // ------------------------------------------------------------ controls
            // The action bar lives at the bottom of the panel, under the felt —
            // where the player's eye already is.
            Item {
                id: controlsRow
                anchors.bottom: parent.bottom
                anchors.left: header.left
                anchors.right: header.right
                anchors.bottomMargin: surface.contentBottomInset
                height: 48

                Row {
                    id: actionButtons
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.sm

                    // Waiting on a bot — say so, so the table never looks stuck.
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.botTurn
                        text: root.seatName(root.g ? root.g.actor : -1) + " is thinking…"
                        color: root.foreground
                        opacity: 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.g !== null && root.g.phase === "handOver"
                        text: "Space deals the next hand"
                        color: root.foreground
                        opacity: 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }

                    Button {
                        accent: root.gold
                        text: "Next hand"
                        bordered: true
                        fontFamily: root.fontFamily
                        visible: root.g !== null && root.g.phase === "handOver"
                        onClicked: root.nextHand()
                    }

                    Button {
                        accent: root.gold
                        text: "Fold"
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: "Give up the hand  (f)"
                        visible: root.humanTurn
                        onClicked: root.humanAct("fold")
                    }
                    Button {
                        accent: root.gold
                        text: root.humanLegal && root.humanLegal.canCheck ? "Check" : root.humanLegal && root.humanLegal.toCall >= (root.g ? root.g.seats[0].chips : 0) ? "Call " + root.fmt(root.humanLegal.toCall) + " · all-in" : "Call " + (root.humanLegal ? root.fmt(root.humanLegal.toCall) : "")
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: root.humanLegal && root.humanLegal.canCheck ? "Pass the action  (c)" : "Match the bet  (c)"
                        visible: root.humanTurn
                        onClicked: root.humanAct(root.humanLegal.canCheck ? "check" : "call")
                    }

                    // ------------------------------------------------ raise cluster
                    Button {
                        accent: root.gold
                        text: "Min"
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: "Smallest legal raise"
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.presetRaise(0)
                    }
                    Button {
                        accent: root.gold
                        text: "½ pot"
                        bordered: true
                        fontFamily: root.fontFamily
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.presetRaise(0.5)
                    }
                    Button {
                        accent: root.gold
                        text: "Pot"
                        bordered: true
                        fontFamily: root.fontFamily
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.presetRaise(1.0)
                    }
                    Button {
                        accent: root.gold
                        text: "−"
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: "Lower the raise  (↓)"
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.adjustRaise(-(root.g ? root.g.bb : 20))
                    }
                    Button {
                        accent: root.gold
                        text: "+"
                        bordered: true
                        fontFamily: root.fontFamily
                        tooltipText: "Raise the raise  (↑)"
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.adjustRaise(root.g ? root.g.bb : 20)
                    }
                    Button {
                        accent: root.gold
                        text: root.humanLegal && root.raiseTo >= root.humanLegal.maxTo ? "All-in " + root.fmt(root.humanLegal.maxTo) : (root.humanLegal && root.humanLegal.toCall === 0 ? "Bet " : "Raise to ") + root.fmt(root.raiseTo)
                        bordered: true
                        selected: true
                        fontFamily: root.fontFamily
                        tooltipText: "Confirm the raise  (r)"
                        visible: root.humanTurn && root.humanLegal.canRaise
                        onClicked: root.humanAct("raise", root.raiseTo)
                    }
                }
            }

            // -------------------------------------------------------------- table
            Rectangle {
                id: feltSurface
                anchors.top: sep.bottom
                anchors.left: header.left
                anchors.right: header.right
                anchors.bottom: controlsRow.top
                anchors.topMargin: Style.spacing.sm
                radius: Math.max(2, root.cornerRadius)
                color: root.felt
                clip: true

                // The table tile. sourceSize sets how big one repeat lands, since
                // Image.Tile repeats at the resolved source size rather than scaling
                // to fit.
                Image {
                    id: tableTile
                    readonly property int tileSize: Math.max(160, Math.round(feltSurface.width * 0.34))

                    anchors.fill: parent
                    source: root.tableImage
                    fillMode: Image.Tile
                    sourceSize.width: tableTile.tileSize
                    sourceSize.height: tableTile.tileSize
                    smooth: true
                    cache: true
                }

                // The vignette. A real felt darkens toward the rail under table
                // light; this is the same trick as a radial gradient from clear
                // centre to deep green-black at the corners.
                Shape {
                    anchors.fill: parent
                    ShapePath {
                        fillGradient: RadialGradient {
                            centerX: feltSurface.width / 2
                            centerY: feltSurface.height / 2
                            centerRadius: Math.max(1, Math.hypot(feltSurface.width, feltSurface.height) / 2)
                            focalX: centerX
                            focalY: centerY
                            focalRadius: 0
                            GradientStop {
                                position: 0
                                color: Qt.rgba(0.02, 0.10, 0.06, 0)
                            }
                            GradientStop {
                                position: 0.62
                                color: Qt.rgba(0.02, 0.10, 0.06, 0.10)
                            }
                            GradientStop {
                                position: 1
                                color: Qt.rgba(0.01, 0.07, 0.04, 0.42)
                            }
                        }
                        strokeColor: "transparent"
                        strokeWidth: 0
                        PathSvg {
                            path: "M 0 0 L " + feltSurface.width + " 0 L " + feltSurface.width + " " + feltSurface.height + " L 0 " + feltSurface.height + " Z"
                        }
                    }
                }

                Item {
                    id: table
                    anchors.fill: parent
                    anchors.margins: Math.max(Style.spacing.sm, Math.round(feltSurface.width * 0.013))

                    // ---------------------------------------------------- the racetrack
                    // The betting line: a double-walled stadium shape across the
                    // middle of the felt, the board inside it and the seats' ghost
                    // pairs on its edge. Painted in the felt's own pale green, the way
                    // the classic table does its markings.
                    Rectangle {
                        x: Math.round(parent.width * 0.05)
                        y: Math.round(parent.height * 0.09)
                        width: Math.round(parent.width * 0.90)
                        height: Math.round(parent.height * 0.72)
                        radius: height / 2
                        color: "transparent"
                        border.width: 2
                        border.color: root.feltLine
                        opacity: 0.62
                    }
                    Rectangle {
                        x: Math.round(parent.width * 0.05) + 7
                        y: Math.round(parent.height * 0.09) + 7
                        width: Math.round(parent.width * 0.90) - 14
                        height: Math.round(parent.height * 0.72) - 14
                        radius: (height) / 2
                        color: "transparent"
                        border.width: 1
                        border.color: root.feltLine
                        opacity: 0.35
                    }

                    // ------------------------------------------------- seat ghost pairs
                    // Two outlined cards at every occupied seat, exactly where the
                    // hole cards land — an empty table still reads as five seats
                    // waiting, and a dealt hand drops straight into its outline.
                    Repeater {
                        model: 5
                        delegate: Item {
                            readonly property var pair: root.layout.pairs[index]
                            readonly property var st: root.seat(index)

                            visible: pair && pair.visible && st && st.sitting
                            x: pair ? pair.x : 0
                            y: pair ? pair.y : 0
                            width: root.cardW * 2 + 6
                            height: root.cardH
                            z: 1

                            Repeater {
                                model: 2
                                delegate: Rectangle {
                                    x: index * (root.cardW + 6)
                                    width: root.cardW
                                    height: root.cardH
                                    radius: Math.max(2, root.cardW * 0.09)
                                    color: "transparent"
                                    border.width: 1
                                    border.color: root.feltLine
                                    opacity: 0.55
                                }
                            }
                        }
                    }

                    // --------------------------------------------------------- the pips
                    // A quiet row of suits under the board, the classic felt marking.
                    Row {
                        x: table.width / 2 - width / 2
                        y: root.layout.potY + Math.round(root.cardH * 0.42)
                        spacing: Math.round(root.cardW * 0.16)

                        Repeater {
                            model: 4
                            delegate: SuitPip {
                                width: Math.max(10, Math.round(root.cardH * 0.17))
                                height: width
                                suit: index
                                pipColor: root.feltLine
                                opacity: 0.6
                            }
                        }
                    }

                    // ------------------------------------------------- board + dealer
                    // Outline where the dealer puts the board. Cards fly out from
                    // behind it — there is no deck pile anywhere on the table.
                    Row {
                        id: boardRow
                        x: root.layout.commLeft
                        y: root.layout.commY
                        spacing: root.layout.gap

                        Repeater {
                            model: 5
                            delegate: Rectangle {
                                width: root.cardW
                                height: root.cardH
                                radius: Math.max(2, root.cardW * 0.09)
                                color: "transparent"
                                border.width: 1
                                border.color: root.feltLine
                                opacity: 0.55
                            }
                        }
                    }

                    // The pot: chip icon and amount on a dark pill, so the number
                    // that matters most on the table is the easiest to find.
                    Rectangle {
                        id: potBox
                        visible: root.g && root.g.phase === "betting" && Poker.potNow(root.g) > 0
                        x: table.width / 2 - width / 2
                        y: root.layout.potY
                        width: potRow.width + Style.spacing.xl * 2
                        height: potRow.height + Style.spacing.sm * 2
                        radius: height / 2
                        color: Qt.rgba(0.0, 0.07, 0.03, 0.5)
                        border.width: 1
                        border.color: Qt.rgba(root.gold.r, root.gold.g, root.gold.b, 0.4)

                        Row {
                            id: potRow
                            x: Style.spacing.xl
                            y: (parent.height - height) / 2
                            // a touch more than the row default: the chip's round
                            // edge reads tighter to the text than a flat box would
                            spacing: Style.spacing.lg

                            ChipIcon {
                                width: Math.max(16, Math.round(root.cardH * 0.20))
                                height: width
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: visible ? "Pot " + root.fmt(Poker.potNow(root.g)) : ""
                                visible: potBox.visible
                                color: root.cream
                                font.family: root.fontFamily
                                font.pixelSize: Math.max(12, Math.round(root.cardH * 0.17))
                                font.bold: true
                            }
                        }
                    }

                    // ------------------------------------------------- action ticker
                    // Top-left corner: the seats own the bottom half and the rails.
                    // Capped and elided so a long line never runs under the board.
                    Column {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.margins: Style.spacing.md
                        spacing: 2
                        width: Math.max(0, root.layout.commLeft - Style.spacing.md * 2)

                        Repeater {
                            model: root.recentLog()
                            delegate: Text {
                                text: modelData
                                color: root.cream
                                opacity: 0.55 - index * 0.14
                                elide: Text.ElideRight
                                width: parent.width
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }
                        }
                    }

                    // --------------------------------------------------- seat plates
                    Repeater {
                        model: 5
                        delegate: Item {
                            id: seatPlate
                            readonly property int s: index
                            readonly property var st: root.seat(s)
                            readonly property var pl: root.layout.plates[s]
                            readonly property bool occupied: st !== null && st.everSat
                            readonly property bool acting: root.g !== null && root.g.phase === "betting" && root.g.actor === s
                            readonly property bool won: root.isWinner(s)
                            readonly property var lastAct: root.lastActionFor(s)

                            visible: occupied
                            x: pl ? pl.x : 0
                            y: pl ? pl.y : 0
                            width: pl ? pl.w : 0
                            height: pl ? pl.h : 0
                            z: 5
                            opacity: st && st.sitting ? 1 : 0.35

                            Rectangle {
                                anchors.fill: parent
                                radius: Math.max(3, root.cornerRadius * 0.6)
                                color: seatPlate.acting ? root.mix(root.felt, root.gold, 0.18) : root.mix(root.felt, "#0c2418", 0.45)
                                border.width: seatPlate.acting || seatPlate.won ? 2 : 1
                                border.color: seatPlate.won ? root.gold : seatPlate.acting ? root.cream : root.feltLine
                            }

                            // Two rows, padded off both edges: who you are and what
                            // you have, then what you last did. Full words throughout —
                            // a new player should never have to decode the table.
                            Column {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.leftMargin: Style.spacing.xl
                                anchors.rightMargin: Style.spacing.xl
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 3

                                Item {
                                    width: parent.width
                                    height: Math.max(nameText.implicitHeight, chipsText.implicitHeight)

                                    Text {
                                        id: nameText
                                        anchors.left: parent.left
                                        text: seatPlate.st ? seatPlate.st.name : ""
                                        color: seatPlate.won || seatPlate.s === 0 ? root.gold : root.cream
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                        font.bold: seatPlate.s === 0 || seatPlate.won
                                    }
                                    Text {
                                        id: chipsText
                                        anchors.right: parent.right
                                        text: seatPlate.st && seatPlate.st.sitting ? "Chips " + root.fmt(seatPlate.st.chips) : (seatPlate.st && seatPlate.st.everSat ? "Busted" : "")
                                        color: root.cream
                                        opacity: 0.85
                                        font.family: root.fontFamily
                                        font.pixelSize: Style.font.caption
                                    }
                                }

                                Text {
                                    width: parent.width
                                    visible: seatPlate.lastAct !== null
                                    text: seatPlate.lastAct ? seatPlate.lastAct.text : ""
                                    color: seatPlate.lastAct && seatPlate.lastAct.gold === true ? root.gold : root.cream
                                    opacity: seatPlate.lastAct !== null ? 1 : 0
                                    elide: Text.ElideRight
                                    font.family: root.fontFamily
                                    font.pixelSize: Math.max(10, Style.font.caption - 1)
                                }
                            }

                            // The dealer button floats off the plate's right edge,
                            // clear of every text row.
                            Rectangle {
                                visible: root.g && root.g.button === seatPlate.s && (root.g.phase === "betting" || root.g.phase === "handOver")
                                width: Math.max(16, root.cardW * 0.22)
                                height: width
                                radius: width / 2
                                x: parent.width + 4
                                y: (parent.height - height) / 2
                                color: root.gold
                                Text {
                                    anchors.centerIn: parent
                                    text: "D"
                                    color: root.felt
                                    font.family: root.fontFamily
                                    font.pixelSize: parent.width * 0.55
                                    font.bold: true
                                }
                            }
                        }
                    }

                    // ------------------------------------------------------- cards
                    Repeater {
                        model: 52
                        delegate: Item {
                            id: cardItem

                            readonly property int cid: index
                            readonly property var info: root.layout.cards[cid]

                            visible: info.pile !== "none"
                            width: root.cardW
                            height: root.cardH
                            x: info.x
                            y: info.y
                            z: info.z
                            // Mucked cards are already flying to the dealer when they
                            // start fading — the discard is a motion, not a pile.
                            opacity: info.pile === "muck" ? 0 : 1

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 400
                                }
                            }
                            Behavior on x {
                                NumberAnimation {
                                    duration: 160
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on y {
                                NumberAnimation {
                                    duration: 160
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Rectangle {
                                id: body
                                anchors.fill: parent
                                radius: Math.max(2, root.cardW * 0.09)
                                color: "transparent"

                                // The artwork carries its own frame and rounded corners, so
                                // this is a positioning shell only.
                                Image {
                                    anchors.fill: parent
                                    source: cardItem.info.up ? root.cardImage(cardItem.cid) : root.backImage
                                    fillMode: Image.PreserveAspectFit
                                    sourceSize.width: Math.max(64, Math.round(root.cardW * 2))
                                    smooth: true
                                    mipmap: true
                                    asynchronous: true
                                    cache: true
                                }
                            }
                        }
                    }

                    // ------------------------------------------------- hand banner
                    Rectangle {
                        visible: root.g !== null && root.g.phase === "handOver"
                        z: 900
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(parent.width * 0.7, winCol.implicitWidth + Style.spacing.huge * 2)
                        height: winCol.implicitHeight + Style.spacing.xl * 2
                        radius: Math.max(2, root.cornerRadius)
                        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.93)
                        border.width: 1
                        border.color: root.gold

                        Column {
                            id: winCol
                            anchors.centerIn: parent
                            spacing: Style.spacing.sm

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.bannerTitle()
                                color: root.gold
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                                font.bold: true
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                visible: root.bannerSub() !== ""
                                text: root.bannerSub()
                                color: root.foreground
                                opacity: 0.8
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }
                            Button {
                                accent: root.gold
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Next hand"
                                bordered: true
                                fontFamily: root.fontFamily
                                onClicked: root.nextHand()
                            }
                        }
                    }

                    // --------------------------------------------- setup / session overlays
                    Rectangle {
                        visible: root.g === null || root.g.phase === "idle"
                        z: 950
                        anchors.fill: parent
                        color: Qt.rgba(root.felt.r, root.felt.g, root.felt.b, 0.96)

                        Column {
                            id: setup
                            anchors.centerIn: parent
                            spacing: Style.spacing.md

                            property int botCount: 2

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "♠  Omarchy Hold'em"
                                color: root.gold
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                                font.bold: true
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "No-limit Texas Hold'em  ·  Small blind " + Poker.SB + "  ·  Big blind " + Poker.BB + "  ·  Buy-in " + root.fmt(Poker.START_STACK)
                                color: root.foreground
                                opacity: 0.7
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Style.spacing.sm

                                Dropdown {
                                    id: opponentPicker
                                    label: "Opponents"
                                    showLabel: true
                                    fontFamily: root.fontFamily
                                    accent: root.gold
                                    value: setup.botCount.toString()
                                    options: [
                                        {
                                            value: "1",
                                            label: "One"
                                        },
                                        {
                                            value: "2",
                                            label: "Two"
                                        },
                                        {
                                            value: "3",
                                            label: "Three"
                                        },
                                        {
                                            value: "4",
                                            label: "Four"
                                        }
                                    ]
                                    onChanged: function (v) {
                                        setup.botCount = parseInt(v);
                                    }
                                }
                            }

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Opponents: " + Poker.STYLES.slice(0, setup.botCount).map(function (s) {
                                    return s.name;
                                }).join(", ")
                                color: root.foreground
                                opacity: 0.6
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                            }

                            Button {
                                accent: root.gold
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Take a seat"
                                bordered: true
                                selected: true
                                fontFamily: root.fontFamily
                                onClicked: root.startSession(setup.botCount)
                            }
                        }
                    }

                    // Session over — felted or swept, either way the chips are back.
                    Rectangle {
                        visible: root.g !== null && root.g.phase === "sessionOver"
                        z: 950
                        anchors.fill: parent
                        color: Qt.rgba(root.felt.r, root.felt.g, root.felt.b, 0.96)

                        Column {
                            anchors.centerIn: parent
                            spacing: Style.spacing.md

                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.g !== null && root.g.seats[0].chips <= 0 ? "You are felted." : "You cleaned them out."
                                color: root.g !== null && root.g.seats[0].chips <= 0 ? root.urgent : root.gold
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.heading
                                font.bold: true
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: {
                                    if (!root.g)
                                        return "";
                                    var s = root.g.stats;
                                    return s.hands + " hands  ·  biggest pot " + root.fmt(s.biggestPot) + "  ·  peak stack " + root.fmt(s.peak);
                                }
                                color: root.foreground
                                opacity: 0.75
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                            }
                            Button {
                                accent: root.gold
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "New session"
                                bordered: true
                                selected: true
                                fontFamily: root.fontFamily
                                onClicked: root.newSession()
                            }
                        }
                    }
                }
            }
        }
    }

    // Banner text helpers, kept out of the bindings for readability.
    function bannerTitle() {
        if (!root.g || !root.g.results)
            return "";
        var wins = root.g.results.wins;
        if (wins.length === 0)
            return "Hand over";
        if (wins.length === 1) {
            var w = wins[0];
            return (w.seat === 0 ? "You win " : root.seatName(w.seat) + " wins ") + root.fmt(w.amount);
        }
        var names = [];
        var amounts = {};
        for (var i = 0; i < wins.length; i++) {
            var n = wins[i].seat === 0 ? "You" : root.seatName(wins[i].seat);
            if (names.indexOf(n) < 0)
                names.push(n);
            amounts[n] = (amounts[n] || 0) + wins[i].amount;
        }
        return names.map(function (n) {
            return n + " " + root.fmt(amounts[n]);
        }).join(" · ");
    }

    function bannerSub() {
        if (!root.g || !root.g.results)
            return "";
        var seen = [];
        for (var i = 0; i < root.g.results.wins.length; i++) {
            var h = root.g.results.wins[i].name;
            if (h && seen.indexOf(h) < 0)
                seen.push(h);
        }
        return seen.join("  ·  ");
    }
}
