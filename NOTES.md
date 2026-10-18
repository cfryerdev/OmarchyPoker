# NOTES — Omarchy Hold'em (nosignal.omarchyholdem)

Working notes for this repo. Read before changing anything in `poker.js` or
`Panel.qml`.

## Status

**0.2.0, untagged.** Playable. This was Quattrolitaire (Klondike solitaire)
by Gavin Nugent — the repo now belongs to **cfryerdev** with the game swapped
for no-limit Texas Hold'em; Gavin's original lives at the public
`28allday/Quattrolitaire`, and the README credits the origin. No release is
tagged yet.

The engine's test suite runs in node: `node tests/poker-test.js`. Run it
after touching `poker.js` — it has already caught a conservation bug the
fun way.

Installed here as a dev copy/symlink under
`~/.config/omarchy/plugins/nosignal.omarchyholdem`, enabled in the right bar
section — so **no hot reload**: `omarchy-restart-shell` after every QML edit,
and never `omarchy-refresh-shell`, which resets `shell.json`.

## Design

**The engine is a separate, serialisable state machine.** `poker.js` holds
every rule — deck, blinds, betting rounds, side pots, showdowns, bot judgement
— as pure functions over one plain object `st`. No QML objects, no node-only
constructs: the file is imported by `Panel.qml` (`import "poker.js" as
Poker`) and required by `tests/poker-test.js`. Because `st` is nothing but
JSON, a mid-hand save is a `JSON.stringify` away, and restoring is exact —
same deck order, same seed, same bot about to act.

**The seed travels with the state.** All randomness (shuffles, bot moods,
jitter) advances `st.seed` via mulberry32, so a saved hand replays its own
future deterministically. That is what makes the restore test meaningful:
snapshot mid-hand, replay both copies, identical chip counts.

**Chips are conserved, and the tests watch it.** The identity is
`Σchips + Σbet + pot` — constant. `committed` is bookkeeping for side pots
(it shadows bet plus what the pot has already taken) and must never be summed
as a fourth place chips live; the test suite asserts conservation after every
simulated action.

**Side pots are layered from all-in levels.** `buildPots` sorts the commit
levels of players still in the hand, slices every seat's committed chips into
layers, and marks eligibility by who covered each layer. Folded money is in
every layer it paid for and eligible for none. Uncalled excess returns to the
bettor before the maths, so the banner never counts a player's own chips as
winnings.

**Bots are two numbers and a dice roll.** Each has `tight` and `aggro` in
`STYLES`. Judgement is a strength estimate (preflop: a Chen-flavoured formula;
postflop: the made-hand category, downgraded when the board plays itself,
boosted for flush and straight draws) compared against pot odds, with the
personality numbers moving the thresholds. Decisions are deterministic per
state — the rng lives in `st` — which keeps replay exact.

**One layout function owns geometry.** `computeLayout()` turns the model into
52 `{x, y, z, up, pile}` records plus plate, pair and board geometry. It is
bound to `rev`, which bumps after every commit. Card delegates bind their
x/y/z to their record with a `Behavior`, so every deal, muck and reveal
animates itself — there is no imperative card movement anywhere.

**The table is a drawn racetrack, not a picture.** Dealer top, five seats on
a bottom arc, filled from the middle out: the human holds bottom centre and
each bot takes the closest open seat, alternating left and right, so the
table stays as symmetric as the opponent count allows. Ghost card pairs
at every occupied seat (exactly where the hole cards land — `computeLayout`
emits both from the same formula), board slots and a suit-pip row under the
board. The felt is pinned casino green with a radial vignette toward the
rail; the chrome around it keeps following the theme. There is no deck pile
and no muck pile: undealt cards wait invisibly behind the board, and folded
cards fly to the dealer and fade mid-flight.

**Dealing is theatre, not model.** The engine deals instantly. Cards sit at
the deck position in the layout until `holeShown` / `shownCommunity` release
them, one pacer tick at a time, so the deal is a pure visual lag over an
already-final model. A restored hand sets the counters to their targets and
everything is simply there.

**Panel instances can be rebuilt.** State is written to disk after every
action (debounced 400ms), and `applyState` only trusts a file where all 52
cards appear exactly once across deck, board, holes and muck. A half-written
or hand-edited file lands on the setup screen instead of half a table.

## Card art

Unchanged from the solitaire days — the bundled art-deco deck in `cards/` is
exactly the deck the table deals. Faces are addressed by card code (`AH`,
`10D`, `QC`, `KS`), built from the engine's own rank and suit indices. See
`cards/CREDITS.md` for the back's provenance and the swap-in procedure.

The solitaire panel drew ghosted suit pips on empty foundation slots; the
poker table uses the same `SuitPip` shapes for the quiet suit row under the
board. The Unicode suit glyphs are still avoided everywhere — they resolve
through font fallback and do not all land in the same font, so the action
ticker writes cards as letters (`Kh 9s 4d`).

## Gotchas hit while building this

- **The `qs.*` imports carry the whole UI kit.** A rewrite that drops
  `import qs.Commons` / `import qs.Ui` still parses — qmlformat passes,
  qmllint only grumbles about unqualified access — and then dies in the live
  shell with `Button is not a type`. The first thing to check after a big
  restructure is the import block.
- **`undefined` is not `false` in a bool binding.** `lastAct !== null &&
  lastAct.gold` assigns `undefined` to `font.bold` when the object exists but
  lacks the field, which the shell logs as `Unable to assign [undefined] to
  bool`. Guard with `=== true` when the field is optional.
- **This Qt's `PathAngleArc` takes `radiusX`/`radiusY`, not `radius`.** The
  docs in your head are from an older Qt; here the property is `radiusX`/
  `radiusY` (and `moveToCenter` is not in the shell's own usage — set
  `centerX`/`centerY` off the Shape's size). Assigning `radius` fails at
  component creation, which takes the whole panel down with it: the tray
  toggle "does nothing" because there is no panel left to toggle. The shell's
  `Ui/SpeedTestOverlay.qml` is the working reference for this Shapes API.
- **Clone before commit.** Engine functions mutate `st` and return it —
  assigning the same reference back to `root.g` would notify QML of nothing.
  `commit()` deep-copies through JSON on every action. It runs at most once a
  second, so the copy is free.
- **The conservation identity is easy to get wrong.** `committed` includes
  the live `bet`, so summing both double-counts the street's chips. The
  invariant is `Σchips + Σbet + pot`.
- **A short all-in does not reopen the action.** It raises `currentBet` but
  not `lastRaise`, and players who already acted are only dragged back in to
  match the difference. Getting this wrong creates raise wars that never end;
  the sim's termination guard is what surfaced it.
- **QML property names cannot start with a capital.** `readonly property var L`
  will not parse.
- **wtype is useless here.** `wtype -k space` swaps the seat keymap, and the
  client resolves the keycode against whichever keymap it has at that moment.
  The kbd noise in the journal is that, not a shell bug. Test keys on a real
  keyboard.
- **`keepLoaded: true` is load-bearing.** Without it the host's Loader
  destroys the panel on hide and the hand in progress goes with it. The
  FileView save covers shell restarts too.

## Plugin plumbing

- **Dev loop is `./scripts/local_publish.sh`**: tests, rsync to
  `~/.config/omarchy/plugins/nosignal.omarchyholdem`, shell restart.
  `--no-restart` / `--no-tests` flags exist; `HOLDEM_DEST` moves the target.
- `panel` + `bar-widget`, so it carries the usual `ensureSelfReference()`
  workaround: `omarchy plugin enable` writes only the bar layout entry, and
  without a `plugins[]` entry the keybinding dies with the bar icon. Upstream
  fix is PR #6510 — drop this once that lands.
- Renamed from `nosignal.quattrolitaire` in 0.2.0. The old registration is
  removed and the new one added; a stray old bar icon means the shell still
  has the old id in `shell.json` — remove it with
  `omarchy plugin remove nosignal.quattrolitaire`.
- Installed as a dev copy for testing, which means **no hot reload** —
  `omarchy-restart-shell` after every QML edit. Never `omarchy-refresh-shell`.

## Screenshots

`screenshots/table.jpg` and `preview.jpg` still show the solitaire table this
plugin used to be; they need retaking against the poker felt. The README
deliberately does not embed them until they are real.

## Ideas, not committed to

- Bet slider as well as the stepper.
- Seeded decks ("hand #1234") so a setup can be replayed or shared.
- Table talk: one-line bot patter in the ticker.
- Rebuy buttons for friendly games instead of strict elimination.
- Tournament structure: rising blinds on a timer.
