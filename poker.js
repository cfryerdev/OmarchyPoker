// Omarchy Hold'em — the whole game engine, deliberately free of QML objects.
//
// Everything here is plain, serialisable JavaScript operating on one state
// object `st`, so a hand in progress can be written to disk with
// JSON.stringify and resumed exactly where it was. The same file is loaded by
// Panel.qml (`import "poker.js" as Poker`) and by the node test harness in
// tests/, which is why there is not a single QML- or node-only construct in
// it — no Qt object, no `let`/`const`, no arrow functions.
//
// State shape (all of it serialisable):
//   st.v          format version
//   st.seed       rng state; every random choice advances it, so a saved
//                 game replays its own future deterministically
//   st.seats[5]   seat 0 is always the human. Bots sit at 1..botCount.
//                 Each: { name, bot, style {tight, aggro}, chips, sitting,
//                 everSat, hole[], folded, allIn, bet, committed, acted,
//                 revealed }
//   st.button     dealer button, an index into seats; rotates each hand
//   st.sbSeat / st.bbSeat   blind posters for the current hand
//   st.street     0 preflop, 1 flop, 2 turn, 3 river
//   st.community  revealed board cards, up to 5
//   st.deck       undealt cards, top of deck is the last element
//   st.mucked     folded hole cards, kept so the UI can animate them to the
//                 discard and the validator can still count a full deck
//   st.pot        chips collected on earlier streets; live bets sit in
//                 seat.bet until the street ends
//   st.currentBet / st.lastRaise   current betting-round state
//   st.actor      seat to act, or -1
//   st.phase      "idle" | "betting" | "handOver" | "sessionOver"
//   st.log        append-only event list; the UI reads it for the action
//                 ticker and seat badges. Capped, oldest dropped.
//   st.results    per-hand summary for the banner, or null
//   st.stats      { hands, biggestPot, peak } — cumulative across sessions
//
// Chips are always integers. All functions mutate st and return it.

// ------------------------------------------------------------- constants

var SB = 10            // small blind
var BB = 20            // big blind
var START_STACK = 1000 // buy-in for every seat

// Four fixed opponents with distinct tempers. tight raises the bar for
// playing a hand, aggro raises the bar for raising it.
var STYLES = [
  { name: "Vera", tight: 0.62, aggro: 0.72 },
  { name: "Rook", tight: 0.28, aggro: 0.82 },
  { name: "Moss", tight: 0.18, aggro: 0.14 },
  { name: "Tess", tight: 0.85, aggro: 0.34 }
]

// ------------------------------------------------------------------ cards
// A card is still the solitaire codebase's cid 0-51 — same deck artwork:
//   suit = cid / 13   (0 spades, 1 hearts, 2 diamonds, 3 clubs)
//   rank = cid % 13 + 1  (1 ace … 13 king)

var SUIT_LETTERS = ["s", "h", "d", "c"]
var RANK_LETTERS = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
var RANK_WORD = ["Ace", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight",
                 "Nine", "Ten", "Jack", "Queen", "King"]

function rankOf(cid) { return (cid % 13) + 1 }
function suitOf(cid) { return Math.floor(cid / 13) }
function cardCode(cid) { return RANK_LETTERS[rankOf(cid) - 1] + SUIT_LETTERS[suitOf(cid)] }

// Words for showdown text. Values here are 2-14 with the ace as 14; the ace
// also lives at rank 1 in cids, which only the straight finder cares about.
function word(v) { return v === 14 ? "Ace" : RANK_WORD[v - 1] }
function plural(v) { var w = word(v); return w === "Six" ? "Sixes" : w + "s" }

// ------------------------------------------------------------------- rng
// mulberry32, carried inside st so deals and bot moods survive save/restore.

function nextRand(st) {
  st.seed = (st.seed + 0x6D2B79F5) | 0
  var t = st.seed
  t = Math.imul(t ^ (t >>> 15), t | 1)
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296
}

function freshDeck() {
  var d = []
  for (var i = 0; i < 52; i++) d.push(i)
  return d
}

function shuffle(st, arr) {
  for (var i = arr.length - 1; i > 0; i--) {
    var k = Math.floor(nextRand(st) * (i + 1))
    var t = arr[i]; arr[i] = arr[k]; arr[k] = t
  }
  return arr
}

function round10(x) { return Math.max(10, Math.round(x / 10) * 10) }
function clamp01(x) { return Math.min(0.97, Math.max(0.05, x)) }

// ------------------------------------------------------------------- log

function log(st, ev) {
  st.log.push(ev)
  if (st.log.length > 120) st.log.splice(0, st.log.length - 120)
}

// ---------------------------------------------------------- seat helpers

function newSession(botCount, seed) {
  botCount = Math.max(0, Math.min(4, botCount | 0))
  var seats = []
  for (var i = 0; i < 5; i++) {
    var isBot = i > 0 && i <= botCount
    var style = isBot ? STYLES[i - 1] : null
    seats.push({
      name: isBot ? style.name : "You",
      bot: isBot,
      style: isBot ? { tight: style.tight, aggro: style.aggro } : null,
      chips: (i === 0 || isBot) ? START_STACK : 0,
      sitting: i === 0 || isBot,
      everSat: i === 0 || isBot,
      hole: [], folded: false, allIn: false,
      bet: 0, committed: 0, acted: false, revealed: false
    })
  }
  return {
    v: 2,
    seed: seed === undefined ? ((Date.now() & 0xffffffff) >>> 0) : (seed >>> 0),
    botCount: botCount, sb: SB, bb: BB,
    seats: seats,
    button: 0, sbSeat: -1, bbSeat: -1,
    street: 0, community: [], deck: [], mucked: [],
    pot: 0, currentBet: 0, lastRaise: BB, actor: -1,
    handNum: 0, phase: "idle", log: [], results: null,
    stats: { hands: 0, biggestPot: 0, peak: START_STACK }
  }
}

function sittingSeats(st) {
  var out = []
  for (var i = 0; i < 5; i++) if (st.seats[i].sitting) out.push(i)
  return out
}

function activeCount(st) {
  var n = 0
  for (var i = 0; i < 5; i++)
    if (st.seats[i].sitting && !st.seats[i].folded) n++
  return n
}

function canActCount(st) {
  var n = 0
  for (var i = 0; i < 5; i++) {
    var s = st.seats[i]
    if (s.sitting && !s.folded && !s.allIn) n++
  }
  return n
}

// First seat after `from`, clockwise, matching pred. Returns -1 if none.
function nextFrom(st, from, pred) {
  for (var k = 1; k <= 5; k++) {
    var i = (from + k) % 5
    if (pred(st.seats[i])) return i
  }
  return -1
}

function potNow(st) {
  var total = st.pot
  for (var i = 0; i < 5; i++) total += st.seats[i].bet
  return total
}

function muckHole(st, seat) {
  var s = st.seats[seat]
  for (var i = 0; i < s.hole.length; i++) st.mucked.push(s.hole[i])
  s.hole = []
}

// ------------------------------------------------------------- the hand

function startHand(st) {
  var sitting = sittingSeats(st)
  if (sitting.length < 2) return st

  var i
  st.handNum++
  st.phase = "betting"
  st.street = 0
  st.community = []
  st.mucked = []
  st.pot = 0
  st.currentBet = 0
  st.lastRaise = st.bb
  st.actor = -1
  st.results = null
  for (i = 0; i < 5; i++) {
    var s = st.seats[i]
    s.hole = []; s.folded = false; s.allIn = false
    s.bet = 0; s.committed = 0; s.acted = false; s.revealed = false
  }

  // The button moves one seat clockwise per hand. First hand: anywhere.
  if (st.handNum === 1)
    st.button = sitting[Math.floor(nextRand(st) * sitting.length)]
  else
    st.button = nextFrom(st, st.button, function (p) { return p.sitting })

  st.deck = shuffle(st, freshDeck())
  log(st, { k: "hand", n: st.handNum })

  // Blinds. Heads-up: the button posts the small blind.
  var hu = sitting.length === 2
  st.sbSeat = hu ? st.button : nextFrom(st, st.button, function (p) { return p.sitting })
  st.bbSeat = nextFrom(st, st.sbSeat, function (p) { return p.sitting })
  postBlind(st, st.sbSeat, st.sb, "small blind")
  postBlind(st, st.bbSeat, st.bb, "big blind")

  // Deal two cards each, clockwise from the small blind, as a live dealer
  // would. The model deals instantly; the UI staggers the reveal.
  for (var round = 0; round < 2; round++) {
    var seat = st.sbSeat
    for (var n = 0; n < sitting.length; n++) {
      st.seats[seat].hole.push(st.deck.pop())
      seat = nextFrom(st, seat, function (p) { return p.sitting })
    }
  }

  st.currentBet = st.bb
  st.lastRaise = st.bb
  // First to act preflop is the seat after the big blind; heads-up that
  // wraps to the button, which is exactly the rule.
  st.actor = nextFrom(st, st.bbSeat, function (p) { return p.sitting && !p.allIn })
  advance(st)
  return st
}

function postBlind(st, seat, amount, label) {
  var s = st.seats[seat]
  var pay = Math.min(amount, s.chips)
  s.chips -= pay
  s.bet += pay
  s.committed += pay
  if (s.chips === 0) s.allIn = true
  log(st, { k: "blind", seat: seat, amount: pay, label: label })
}

// Everything a seat may do right now, for both the human's buttons and the
// bot's decision. Amounts are chip totals to bet *to*, not deltas.
function legalActions(st) {
  if (st.phase !== "betting" || st.actor < 0) return null
  var s = st.seats[st.actor]
  var toCall = Math.min(st.currentBet - s.bet, s.chips)
  var maxTo = s.bet + s.chips
  var minTo = st.currentBet + st.lastRaise
  if (minTo < st.bb) minTo = st.bb
  if (minTo > maxTo) minTo = maxTo          // short of a full raise: all-in or nothing
  return {
    seat: st.actor,
    toCall: toCall,
    canFold: true,
    canCheck: toCall === 0,
    canCall: toCall > 0,
    canRaise: s.chips > toCall,
    minTo: minTo,
    maxTo: maxTo,
    potNow: potNow(st)
  }
}

// One action by st.actor, then the wheel moves and advance() settles the
// consequences. The UI never calls this for a seat that is not the actor.
function act(st, type, amount) {
  if (st.phase !== "betting" || st.actor < 0) return st
  var seat = st.actor
  var s = st.seats[seat]
  var toCall = Math.min(st.currentBet - s.bet, s.chips)

  if (type === "fold") {
    s.folded = true
    muckHole(st, seat)
    log(st, { k: "act", seat: seat, type: "fold" })
  } else if (type === "check" && toCall === 0) {
    log(st, { k: "act", seat: seat, type: "check" })
  } else if (type === "raise") {
    var maxTo = s.bet + s.chips
    var minTo = st.currentBet + st.lastRaise
    if (minTo < st.bb) minTo = st.bb
    if (minTo > maxTo) minTo = maxTo
    var to = Math.max(minTo, Math.min(amount | 0, maxTo))
    to = Math.max(minTo, Math.min(round10(to), maxTo))
    if (to > maxTo) to = maxTo

    var prevBet = st.currentBet
    var prevRaise = st.lastRaise
    var raiseSize = to - prevBet

    s.chips -= to - s.bet
    s.committed += to - s.bet
    s.bet = to
    s.acted = true
    if (s.chips === 0) s.allIn = true

    // A full raise reopens the action; a short all-in does not — players who
    // already matched the old bet only owe the difference, they are not
    // dragged into a raising war they cannot win.
    if (raiseSize >= prevRaise) {
      st.lastRaise = raiseSize
      for (var i = 0; i < 5; i++) {
        var o = st.seats[i]
        if (i !== seat && o.sitting && !o.folded && !o.allIn) o.acted = false
      }
    }
    st.currentBet = Math.max(st.currentBet, to)
    log(st, {
      k: "act", seat: seat, type: "raise", to: to,
      allIn: s.allIn, size: raiseSize
    })
  } else {
    // call — including the "call an all-in for less" case
    if (toCall > 0) {
      s.chips -= toCall
      s.bet += toCall
      s.committed += toCall
      if (s.chips === 0) s.allIn = true
      log(st, { k: "act", seat: seat, type: "call", amount: toCall, allIn: s.allIn })
    } else {
      log(st, { k: "act", seat: seat, type: "check" })
    }
  }

  s.acted = true
  st.actor = nextFrom(st, seat, function (p) { return p.sitting && !p.folded && !p.allIn })
  advance(st)
  return st
}

function collectBets(st) {
  for (var i = 0; i < 5; i++) {
    st.pot += st.seats[i].bet
    st.seats[i].bet = 0
  }
}

function roundComplete(st) {
  for (var i = 0; i < 5; i++) {
    var s = st.seats[i]
    if (!s.sitting || s.folded || s.allIn) continue
    if (!s.acted || s.bet !== st.currentBet) return false
  }
  return true
}

// Settles everything that does not need a decision: street transitions,
// runouts when nobody can bet, showdowns, uncontested pots. Loops until the
// hand is either waiting on a player or over.
function advance(st) {
  var guard = 0
  while (st.phase === "betting" && guard++ < 100) {
    if (activeCount(st) <= 1) { uncontested(st); break }
    if (!roundComplete(st)) break

    collectBets(st)
    var canA = canActCount(st)
    if (st.street === 3 || canA <= 1) { runout(st); break }

    st.street++
    dealStreet(st)
    st.currentBet = 0
    st.lastRaise = st.bb
    for (var i = 0; i < 5; i++) st.seats[i].acted = false
    st.actor = nextFrom(st, st.button, function (p) {
      return p.sitting && !p.folded && !p.allIn
    })
    // roundComplete is now false for anyone who can act; if nobody can act
    // (everyone all-in — unreachable past the canA check, but cheap to be
    // safe) the next loop pass routes to the runout.
  }
  return st
}

function dealStreet(st) {
  var n = st.street === 1 ? 3 : 1
  var cards = []
  for (var i = 0; i < n; i++) {
    var c = st.deck.pop()
    st.community.push(c)
    cards.push(cardCode(c))
  }
  log(st, { k: "street", street: st.street, cards: cards })
}

// Betting is over with players still holding cards: show them, deal the
// board out, go to showdown.
function runout(st) {
  var i
  for (i = 0; i < 5; i++) {
    var s = st.seats[i]
    if (s.sitting && !s.folded && s.hole.length > 0) s.revealed = true
  }
  log(st, { k: "reveal" })
  while (st.street < 3) {
    st.street++
    dealStreet(st)
  }
  showdown(st)
}

// ------------------------------------------------------------- showdown

// Layers the committed chips into main pot and side pots. Folded money is
// in every layer up to what they put in, but they are eligible for none.
// `committed` is indexed by seat; `folded` too.
function buildPots(committed, folded) {
  var levels = []
  var i
  for (i = 0; i < committed.length; i++)
    if (!folded[i] && committed[i] > 0 && levels.indexOf(committed[i]) < 0)
      levels.push(committed[i])
  levels.sort(function (a, b) { return a - b })

  var pots = []
  var prev = 0
  for (var l = 0; l < levels.length; l++) {
    var level = levels[l]
    var amt = 0
    for (i = 0; i < committed.length; i++)
      amt += Math.max(0, Math.min(committed[i], level) - prev)
    var eligible = []
    for (i = 0; i < committed.length; i++)
      if (!folded[i] && committed[i] >= level) eligible.push(i)
    if (amt > 0 && eligible.length > 0)
      pots.push({ amount: amt, eligible: eligible })
    prev = level
  }
  return pots
}

function showdown(st) {
  var i
  // An uncalled bet comes straight back to the bettor before pot maths,
  // so the banner never counts a player's own chips as winnings.
  var committed = []
  for (i = 0; i < 5; i++) committed.push(st.seats[i].committed)
  var best = -1, second = -1, bestI = -1
  for (i = 0; i < 5; i++) {
    if (committed[i] > best) { second = best; best = committed[i]; bestI = i }
    else if (committed[i] > second) second = committed[i]
  }
  if (bestI >= 0 && best > second) {
    var back = best - second
    st.seats[bestI].chips += back
    st.seats[bestI].committed -= back
    committed[bestI] -= back
    log(st, { k: "return", seat: bestI, amount: back })
  }

  for (i = 0; i < 5; i++) {
    var s = st.seats[i]
    if (s.sitting && !s.folded && s.hole.length > 0) s.revealed = true
  }
  log(st, { k: "reveal" })

  var folded = []
  for (i = 0; i < 5; i++) folded.push(st.seats[i].folded)
  var pots = buildPots(committed, folded)
  var wins = []
  for (var p = 0; p < pots.length; p++) {
    var pot = pots[p]
    var bestScore = null
    var winners = []
    for (var e = 0; e < pot.eligible.length; e++) {
      var seat = pot.eligible[e]
      var score = evalBest(st.seats[seat].hole.concat(st.community))
      if (!bestScore || compareHands(score, bestScore) > 0) {
        bestScore = score
        winners = [seat]
      } else if (compareHands(score, bestScore) === 0) {
        winners.push(seat)
      }
    }
    if (winners.length === 0) continue
    // Split pots: the odd chip goes to the first winner left of the button.
    winners.sort(function (a, b) {
      return ((a - st.button + 5) % 5) - ((b - st.button + 5) % 5)
    })
    var share = Math.floor(pot.amount / winners.length)
    var rem = pot.amount - share * winners.length
    for (var w = 0; w < winners.length; w++) {
      var amt = share + (w < rem ? 1 : 0)
      st.seats[winners[w]].chips += amt
      wins.push({ seat: winners[w], amount: amt, name: handName(bestScore) })
      log(st, { k: "win", seat: winners[w], amount: amt, name: handName(bestScore) })
    }
  }
  finishHand(st, wins)
}

// Last player standing takes the pot without showing anything.
function uncontested(st) {
  collectBets(st)
  var winner = -1
  for (var i = 0; i < 5; i++)
    if (st.seats[i].sitting && !st.seats[i].folded) winner = i
  if (winner < 0) { st.phase = "handOver"; return }
  var amount = st.pot
  st.seats[winner].chips += amount
  log(st, { k: "win", seat: winner, amount: amount, name: null })
  finishHand(st, [{ seat: winner, amount: amount, name: null }])
}

function finishHand(st, wins) {
  st.pot = 0
  for (var i = 0; i < 5; i++) {
    st.seats[i].bet = 0
    st.seats[i].committed = 0
  }
  st.actor = -1
  st.stats.hands++

  var total = 0
  for (i = 0; i < wins.length; i++) total += wins[i].amount
  if (total > st.stats.biggestPot) st.stats.biggestPot = total
  if (st.seats[0].chips > st.stats.peak) st.stats.peak = st.seats[0].chips

  // Busted seats leave the table. The human's felt is the end of the session
  // either way; so is sweeping every bot.
  for (i = 0; i < 5; i++) {
    if (st.seats[i].sitting && st.seats[i].chips === 0) {
      st.seats[i].sitting = false
      log(st, { k: "elim", seat: i })
    }
  }

  st.results = { wins: wins }
  if (st.seats[0].chips <= 0) {
    st.phase = "sessionOver"
    log(st, { k: "bust" })
  } else if (sittingSeats(st).length < 2) {
    st.phase = "sessionOver"
    log(st, { k: "swept" })
  } else {
    st.phase = "handOver"
  }
}

// ---------------------------------------------------------- bot judgement

// Preflop hand strength, 0..1. Pairs scale with rank, unsuited hands ride on
// high cards with shape bonuses. Roughly Chen-flavoured, tuned by feel.
function preflopStrength(hole) {
  var r1 = rankOf(hole[0]), r2 = rankOf(hole[1])
  var v1 = r1 === 1 ? 14 : r1
  var v2 = r2 === 1 ? 14 : r2
  if (v1 < v2) { var t = v1; v1 = v2; v2 = t }
  var suited = suitOf(hole[0]) === suitOf(hole[1])

  if (r1 === r2)
    return Math.min(0.97, 0.50 + 0.045 * (v1 - 2))

  var gap = v1 - v2 - 1
  var str = 0.06 + 0.040 * (v1 - 2) + 0.018 * (v2 - 2)
  if (suited) str += 0.045
  if (gap === 0) str += 0.035
  else if (gap === 1) str += 0.015
  else str -= 0.02 * Math.min(3, gap - 1)
  return clamp01(str)
}

// Postflop strength from the made hand plus draws, 0..1. Playing the board
// (the best five cards are all community) reads as weaker than the category
// alone suggests — nobody is bluff-catching their way to hero calls on it.
function postflopStrength(hole, board) {
  var all = hole.concat(board)
  var s = evalBest(all)
  var base = [0.14, 0.34, 0.50, 0.62, 0.76, 0.84, 0.92, 0.96, 0.985][s[0]]
  var str = base

  var boardBest = evalBest(board)
  if (compareHands(boardBest, s) >= 0) str -= 0.13

  if (board.length < 5 && s[0] < 5) {
    var allDraw = flushDrawCount(all)
    var boardDraw = flushDrawCount(board)
    if (allDraw === 4 && boardDraw < 4) str += 0.13
    var outs = straightDrawWindows(all)
    if (outs >= 2) str += 0.11
    else if (outs === 1) str += 0.05
  }
  return clamp01(str)
}

function flushDrawCount(cards) {
  var counts = [0, 0, 0, 0]
  for (var i = 0; i < cards.length; i++) counts[suitOf(cards[i])]++
  var best = 0
  for (i = 0; i < 4; i++) if (counts[i] > best) best = counts[i]
  return best
}

// Counts five-card windows holding exactly four of a straight's five values.
// Open-enders span two windows (2), gutshots one (1), made straights zero.
function straightDrawWindows(cards) {
  var present = {}
  for (var i = 0; i < cards.length; i++) {
    var v = rankOf(cards[i])
    if (v === 1) { present[14] = true; present[1] = true }
    else present[v] = true
  }
  var windows = 0
  for (var hi = 5; hi <= 14; hi++) {
    var have = 0
    for (var v = hi - 4; v <= hi; v++) if (present[v]) have++
    if (have === 4) windows++
  }
  return windows
}

// The bot's move. Deterministic for a given st — the rng lives in st — so
// saved games and the test harness replay identical bot behaviour.
function botDecision(st) {
  var legal = legalActions(st)
  if (!legal) return { type: "fold" }
  var s = st.seats[st.actor]
  var r = nextRand(st)
  var str = st.street === 0
    ? preflopStrength(s.hole)
    : postflopStrength(s.hole, st.community)
  var tight = s.style.tight
  var aggro = s.style.aggro
  var strJ = str + (r - 0.5) * 0.12
  var toCall = legal.toCall
  var pot = legal.potNow

  if (toCall <= 0) {
    var openAt = 0.58 - aggro * 0.24 + tight * 0.08
    if (strJ >= openAt && legal.canRaise) {
      var size = pot * (0.5 + aggro * 0.5) + (strJ - openAt) * pot * 1.5
      var to = round10(Math.max(legal.minTo, Math.min(legal.maxTo, st.bb * 3 + size)))
      return { type: "raise", amount: Math.min(to, legal.maxTo) }
    }
    if (r > 0.97 - aggro * 0.10 && legal.canRaise)
      return { type: "raise", amount: round10(Math.max(legal.minTo, pot * 0.5)) }
    return { type: "check" }
  }

  var odds = toCall / Math.max(1, pot + toCall)
  var callAt = odds * (1.10 + tight * 0.55) - aggro * 0.04

  if (strJ >= 0.80 && legal.canRaise && r < 0.55 + aggro * 0.35) {
    var to2 = st.currentBet + Math.max(st.lastRaise, pot * (0.55 + aggro * 0.45))
    to2 = Math.min(legal.maxTo, round10(Math.max(legal.minTo, to2)))
    if (to2 >= legal.maxTo * 0.92) to2 = legal.maxTo
    return { type: "raise", amount: to2 }
  }

  if (toCall >= s.chips && strJ < odds + 0.12) return { type: "fold" }
  if (strJ >= callAt) return { type: "call" }
  if (r < aggro * 0.05 && strJ >= 0.35) return { type: "call" }
  return { type: "fold" }
}

// ------------------------------------------------------- hand evaluation
//
// evalBest returns a comparable score: [category, t1..t5] padded to six,
// compared lexicographically. Categories 8..0: straight flush, quads, full
// house, flush, straight, trips, two pair, pair, high card. Values run 2-14
// with the ace high — the wheel lives only inside straightHigh.

function straightHigh(values) {
  var uniq = []
  var seen = {}
  for (var i = 0; i < values.length; i++)
    if (!seen[values[i]]) { seen[values[i]] = true; uniq.push(values[i]) }
  uniq.sort(function (a, b) { return b - a })
  for (i = 0; i + 4 < uniq.length; i++)
    if (uniq[i] - uniq[i + 4] === 4) return uniq[i]
  // the wheel: ace plays low
  if (seen[14] && seen[2] && seen[3] && seen[4] && seen[5]) return 5
  return 0
}

function evalBest(cards) {
  var n = cards.length
  var i
  var vals = []
  var suits = [[], [], [], []]
  var counts = {}
  for (i = 0; i < n; i++) {
    var rv = rankOf(cards[i])
    var v = rv === 1 ? 14 : rv
    vals.push(v)
    suits[suitOf(cards[i])].push(v)
    counts[v] = (counts[v] || 0) + 1
  }

  var groups = []
  for (var key in counts)
    if (counts.hasOwnProperty(key)) groups.push([parseInt(key), counts[key]])
  groups.sort(function (a, b) { return (b[1] - a[1]) || (b[0] - a[0]) })

  var flushVals = null
  for (i = 0; i < 4; i++)
    if (suits[i].length >= 5) {
      suits[i].sort(function (a, b) { return b - a })
      flushVals = suits[i]
    }

  var quad = null, trips = [], pairs = []
  for (i = 0; i < groups.length; i++) {
    var g = groups[i]
    if (g[1] === 4) quad = g[0]
    else if (g[1] === 3) trips.push(g[0])
    else if (g[1] === 2) pairs.push(g[0])
  }

  if (flushVals) {
    var sf = straightHigh(flushVals)
    if (sf > 0) return [8, sf, 0, 0, 0, 0]
    return [5, flushVals[0], flushVals[1], flushVals[2], flushVals[3], flushVals[4]]
  }
  if (quad !== null) {
    var qk = 0
    for (i = 0; i < vals.length; i++) if (vals[i] !== quad && vals[i] > qk) qk = vals[i]
    return [7, quad, qk, 0, 0, 0]
  }
  if (trips.length >= 1 && (trips.length >= 2 || pairs.length >= 1)) {
    var pairPart = trips.length >= 2 ? trips[1] : pairs[0]
    return [6, trips[0], pairPart, 0, 0, 0]
  }
  var sh = straightHigh(vals)
  if (sh > 0) return [4, sh, 0, 0, 0, 0]
  if (trips.length >= 1) {
    var ks = []
    for (i = 0; i < vals.length; i++)
      if (vals[i] !== trips[0] && ks.indexOf(vals[i]) < 0) ks.push(vals[i])
    ks.sort(function (a, b) { return b - a })
    return [3, trips[0], ks[0] || 0, ks[1] || 0, 0, 0]
  }
  if (pairs.length >= 2) {
    var pk = 0
    for (i = 0; i < vals.length; i++)
      if (vals[i] !== pairs[0] && vals[i] !== pairs[1] && vals[i] > pk) pk = vals[i]
    return [2, pairs[0], pairs[1], pk, 0, 0]
  }
  if (pairs.length === 1) {
    var pks = []
    for (i = 0; i < vals.length; i++)
      if (vals[i] !== pairs[0] && pks.indexOf(vals[i]) < 0) pks.push(vals[i])
    pks.sort(function (a, b) { return b - a })
    return [1, pairs[0], pks[0] || 0, pks[1] || 0, pks[2] || 0, 0]
  }
  var highs = vals.slice().sort(function (a, b) { return b - a })
  return [0, highs[0] || 0, highs[1] || 0, highs[2] || 0, highs[3] || 0, highs[4] || 0]
}

function compareHands(a, b) {
  for (var i = 0; i < 5; i++) {
    if (a[i] > b[i]) return 1
    if (a[i] < b[i]) return -1
  }
  return 0
}

function handName(s) {
  switch (s[0]) {
    case 8: return s[1] === 14 ? "Royal Flush" : "Straight Flush, " + word(s[1]) + " high"
    case 7: return "Four of a Kind, " + plural(s[1])
    case 6: return "Full House, " + plural(s[1]) + " full of " + plural(s[2])
    case 5: return "Flush, " + word(s[1]) + " high"
    case 4: return "Straight, " + word(s[1]) + " high"
    case 3: return "Three of a Kind, " + plural(s[1])
    case 2: return "Two Pair, " + plural(s[1]) + " and " + plural(s[2])
    case 1: return "Pair of " + plural(s[1])
    default: return word(s[1]) + " high"
  }
}

// ---------------------------------------------------------------- exports

var api = {
  SB: SB, BB: BB, START_STACK: START_STACK, STYLES: STYLES,
  newSession: newSession, startHand: startHand, advance: advance, act: act,
  legalActions: legalActions, botDecision: botDecision,
  evalBest: evalBest, compareHands: compareHands, handName: handName,
  preflopStrength: preflopStrength, postflopStrength: postflopStrength,
  buildPots: buildPots, straightHigh: straightHigh,
  cardCode: cardCode, rankOf: rankOf, suitOf: suitOf,
  potNow: potNow, activeCount: activeCount, canActCount: canActCount,
  sittingSeats: sittingSeats
}

if (typeof module !== "undefined" && module.exports) module.exports = api
