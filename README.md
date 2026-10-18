# Omarchy Hold'em

No-limit Texas Hold'em as a native Omarchy shell plugin. Five seats at a
felt table — you in the bottom seat, up to four bots with their own tempers
filling the rest — with the dealer's deck, blinds, side pots and showdowns
all drawn in QML. The felt is casino green with a drawn racetrack; the panel
chrome around it follows the active Omarchy theme. The deck ships in the
repo, so there is nothing to fetch and nothing to build.

- **1 to 4 opponents**, picked at the setup screen. Busted bots are out for
  the session — thin the field, or sweep the table
- Full no-limit betting: min-raise rules, short all-ins, uncalled bets
  returned, layered side pots, split pots with the odd chip left of the button
- Four distinct opponents: Vera plays tight-aggressive, Rook is loose and
  frisky, Moss calls far too much, Tess waits you out
- A hand in progress is saved, so it survives closing the panel *and*
  restarting the shell — you come back to the exact seat that was due to act

## Install

```bash
omarchy plugin add https://github.com/cfryerdev/OmarchyPoker --enable
```

Or with the installer, which does the same thing and places the bar icon:

```bash
./install.sh
```

Then click the ♠ in the bar, or bind a key to:

```bash
omarchy-shell shell toggle nosignal.omarchyholdem
```

`install.sh` takes two optional overrides: `HOLDEM_SECTION` picks the bar
section (`left`, `center` or `right`, default `right`), and `HOLDEM_REPO`
registers the plugin from a fork instead.

## Removal

```bash
omarchy plugin remove nosignal.omarchyholdem
```

That unregisters the plugin and drops its bar icon. The saved session is left
behind; delete it too with:

```bash
rm -rf ~/.local/state/omarchy-holdem
```

## How to play

Sit down, pick your opponents, and the dealer pushes out the blinds. Betting
is standard no-limit: $10/$20 blinds, $1,000 buy-in, two cards to each seat
and five on the board. Every value on the table is in dollars.

| Key | Action |
| --- | --- |
| `f` | fold |
| `c` | check, or call the current bet |
| `r` / `enter` | raise to the amount on the button |
| `↑` / `↓` | raise or lower the raise amount |
| `a` | jump the raise to all-in |
| `space` | deal the next hand (or start a session from the setup screen) |
| `n` | new session |
| `esc` | close |

The buttons do the same thing. Min / ½ pot / Pot / All-in size the raise for
you; the − and + keys step it by a big blind.

Bots that lose their last chip are eliminated and their seat goes dark. Lose
all yours and the session is over; take every chip on the table and it's
yours.

## The game engine

The rules live in `poker.js` — a pure, serialisable state machine with no QML
in it, so the same file runs the table and the test suite in `tests/`:

```bash
node tests/poker-test.js
```

The suite checks hand evaluation against a known table (wheel straights,
kickers, board-play splits), the side-pot layering, heads-up blind positions,
min-raise and short-all-in rules, chip conservation, and two thousand
simulated sessions of bot-vs-bot play.

## Dependencies

Omarchy 4 and its shell — no other runtime dependency for play itself. One
piece of plumbing needs **`jq`**, which Omarchy already installs: see below.

## Developing it

Edit, then `./scripts/local_publish.sh` — it runs the engine test suite,
rsyncs the repo into `~/.config/omarchy/plugins/nosignal.omarchyholdem`
(exactly, deleting anything stale) and restarts the shell. `--no-restart`
syncs only; `--no-tests` skips the suite. No hot reload either way — the
restart is what loads new QML.

## What it writes, and what it does not

- `~/.local/state/omarchy-holdem/state.json` — the session: stacks, the hand
  in progress, and the running stats. Written after every action.
- `~/.config/omarchy/shell.json` — **on first open**, the plugin appends its
  own `{"id": "nosignal.omarchyholdem"}` entry to `plugins[]` if one is not
  already there, using `jq`. This is a workaround: `omarchy plugin enable`
  writes only the bar-layout entry for a plugin that is both a panel and a
  bar widget, so without that entry the keybinding stops working the moment
  the bar icon is removed. The edit is idempotent, appends only, changes no
  other setting, and goes away once upstream
  [PR #6510](https://github.com/basecamp/omarchy/pull/6510) lands. The code
  is at the top of `Panel.qml` if you would rather read it than take my word.

Nothing else on the system is touched. The plugin makes **no network
requests**, needs no credentials, runs nothing privileged, and starts no
process beyond the `jq` edit above and a `mkdir -p` for its own state
directory.

## Where things live

| Path | What |
| --- | --- |
| `manifest.json` | Plugin manifest — `panel` + `bar-widget`, `keepLoaded` |
| `Panel.qml` | The table: seats, board, betting controls, pacing, persistence |
| `poker.js` | The whole engine: dealing, betting, side pots, bots, hand ranks |
| `tests/poker-test.js` | Node test suite for the engine |
| `scripts/local_publish.sh` | Dev loop: tests, then rsync to the local plugin install, then shell restart |
| `cards/` | The deck: 52 faces, a shared back, and the felt tile |
| `BarWidget.qml` | Bar icon; toggles the panel over shell IPC |
| `~/.local/state/omarchy-holdem/state.json` | Saved session and stats |

## Card art

The 52 faces are an original art-deco series, one famous car per card,
bundled in `cards/`. The back is reframed from **vulturetone**'s
`1-quattro.jpg`, the rally-car wallpaper in Omarchy's stock `tokyo-night`
theme — see [cards/CREDITS.md](cards/CREDITS.md), which also covers swapping
in a deck of your own. The felt underneath is a generated green texture, also
documented there.

## Credits

Omarchy Hold'em began as [Quattrolitaire](https://github.com/28allday/Quattrolitaire),
**Gavin Nugent**'s Klondike solitaire plugin for omarchy-shell — the game is
his, and this one keeps his plugin skeleton, his theme plumbing, his
drawn-with-Behaviours card architecture, and his art-deco car deck. The
solitaire gave the table its soul; it just turned out the table wanted to
deal poker.

## Licence

MIT, artwork included — see [LICENSE](LICENSE). The card back comes from
vulturetone's `tokyo-night` wallpaper, credited in
[cards/CREDITS.md](cards/CREDITS.md). Poker itself is a public-domain card
game.
