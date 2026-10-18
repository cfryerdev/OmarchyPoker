// Node test harness for poker.js — run: node tests/poker-test.js
//
// Three layers:
//   1. Hand evaluation against a known table (ordering, wheel, board play,
//      kickers, splits) plus showdown naming.
//   2. Crafted betting scenarios: blinds, heads-up roles, min-raise rules,
//      short all-ins, uncalled-bet returns, side pots.
//   3. A random simulation of bot-vs-bot sessions asserting the invariants
//      that matter: chips are conserved, hands always terminate, saved
//      state round-trips and replays identically.
//
// The conservation identity used throughout: chips + committed + pot is
// constant. `committed` includes the live street bet (bet is a slice of it
// until collectBets zeroes bet and the pot takes the chips), so counting
// bet as well would double it.

var P = require("../poker.js")

var failures = 0
var checks = 0

function ok(cond, msg) {
  checks++
  if (!cond) {
    failures++
    console.log("FAIL: " + msg)
  }
}

function eq(a, b, msg) {
  checks++
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    failures++
    console.log("FAIL: " + msg + "\n  got:  " + JSON.stringify(a) + "\n  want: " + JSON.stringify(b))
  }
}

function section(name) { console.log("-- " + name) }

// cid helpers: suit 0 spade 1 heart 2 diamond 3 club, rank 1-13 (A=1)
function cid(suit, rank) { return suit * 13 + (rank - 1) }
// The money identity: chips + live bet + pot is constant. `committed` is
// bookkeeping for the side-pot maths (it shadows bet plus what the pot has
// already taken), so it must not be counted as a fourth place chips live.
function inPlay(st) {
  var sum = 0
  for (var i = 0; i < 5; i++) sum += st.seats[i].chips + st.seats[i].bet
  return sum + st.pot
}

// ======================================================== 1. evaluation

section("hand evaluation")

function scoreOf(cards) { return P.evalBest(cards.map(function (c) { return cid(c.s, c.r) })) }
function nameOf(cards) { return P.handName(scoreOf(cards)) }

// Ordered strongest to weakest; every hand must lose to the one above it.
var ranked = [
  { n: "royal flush",      c: [{ s: 0, r: 10 }, { s: 0, r: 1 }, { s: 0, r: 11 }, { s: 0, r: 12 }, { s: 0, r: 13 }], cat: 8, top: 14 },
  { n: "straight flush",   c: [{ s: 2, r: 5 }, { s: 2, r: 6 }, { s: 2, r: 7 }, { s: 2, r: 8 }, { s: 2, r: 9 }], cat: 8, top: 9 },
  { n: "quads",            c: [{ s: 0, r: 9 }, { s: 1, r: 9 }, { s: 2, r: 9 }, { s: 3, r: 9 }, { s: 0, r: 2 }], cat: 7, top: 9 },
  { n: "full house",       c: [{ s: 0, r: 1 }, { s: 1, r: 1 }, { s: 2, r: 1 }, { s: 3, r: 13 }, { s: 0, r: 13 }], cat: 6, top: 14 },
  { n: "flush",            c: [{ s: 1, r: 2 }, { s: 1, r: 5 }, { s: 1, r: 7 }, { s: 1, r: 9 }, { s: 1, r: 11 }], cat: 5, top: 11 },
  { n: "straight",         c: [{ s: 0, r: 4 }, { s: 1, r: 5 }, { s: 2, r: 6 }, { s: 3, r: 7 }, { s: 0, r: 8 }], cat: 4, top: 8 },
  { n: "wheel",            c: [{ s: 0, r: 1 }, { s: 1, r: 2 }, { s: 2, r: 3 }, { s: 3, r: 4 }, { s: 0, r: 5 }], cat: 4, top: 5 },
  { n: "trips",            c: [{ s: 0, r: 7 }, { s: 1, r: 7 }, { s: 2, r: 7 }, { s: 3, r: 10 }, { s: 0, r: 2 }], cat: 3, top: 7 },
  { n: "two pair",         c: [{ s: 0, r: 13 }, { s: 1, r: 13 }, { s: 2, r: 9 }, { s: 3, r: 9 }, { s: 0, r: 2 }], cat: 2, top: 13 },
  { n: "pair",             c: [{ s: 0, r: 6 }, { s: 1, r: 6 }, { s: 2, r: 10 }, { s: 3, r: 12 }, { s: 0, r: 2 }], cat: 1, top: 6 },
  { n: "high card",        c: [{ s: 0, r: 2 }, { s: 1, r: 5 }, { s: 2, r: 7 }, { s: 3, r: 11 }, { s: 0, r: 13 }], cat: 0, top: 13 }
]

for (var i = 0; i < ranked.length; i++) {
  var h = ranked[i]
  var sc = scoreOf(h.c)
  eq(sc[0], h.cat, h.n + " category")
  eq(sc[1], h.top, h.n + " top tiebreak")
  if (i > 0) {
    var prev = scoreOf(ranked[i - 1].c)
    ok(P.compareHands(sc, prev) < 0, ranked[i - 1].n + " beats " + h.n)
  }
}

eq(nameOf([{ s: 2, r: 6 }, { s: 2, r: 6 }, { s: 0, r: 9 }, { s: 1, r: 10 }, { s: 3, r: 10 }]),
   "Two Pair, Tens and Sixes", "two pair naming")
eq(nameOf([{ s: 0, r: 1 }, { s: 1, r: 1 }, { s: 2, r: 1 }, { s: 3, r: 13 }, { s: 0, r: 13 }]),
   "Full House, Aces full of Kings", "full house naming")
eq(nameOf([{ s: 0, r: 1 }, { s: 1, r: 2 }, { s: 2, r: 3 }, { s: 3, r: 4 }, { s: 0, r: 5 }]),
   "Straight, Five high", "wheel naming")
eq(nameOf([{ s: 3, r: 6 }, { s: 3, r: 6 }, { s: 0, r: 2 }, { s: 1, r: 8 }, { s: 2, r: 9 }]),
   "Pair of Sixes", "pair naming")
eq(nameOf([{ s: 0, r: 10 }, { s: 0, r: 1 }, { s: 0, r: 11 }, { s: 0, r: 12 }, { s: 0, r: 13 }]),
   "Royal Flush", "royal naming")

// Wheel is the LOWEST straight — lose to six-high.
ok(P.compareHands(scoreOf([{ s: 0, r: 1 }, { s: 1, r: 2 }, { s: 2, r: 3 }, { s: 3, r: 4 }, { s: 0, r: 5 }]),
                  scoreOf([{ s: 0, r: 2 }, { s: 1, r: 3 }, { s: 2, r: 4 }, { s: 3, r: 5 }, { s: 0, r: 6 }])) < 0,
   "wheel loses to six-high straight")

// Board plays through: equal-value hands split.
var board = [cid(0, 10), cid(1, 10), cid(2, 7), cid(3, 4), cid(0, 2)]
eq(P.compareHands(P.evalBest([cid(1, 3), cid(2, 9)].concat(board)),
                  P.evalBest([cid(1, 9), cid(2, 3)].concat(board))),
   0, "board plays through, split")

// Seven cards, best five: the nines pair with the fives under it.
var seven = [cid(0, 5), cid(1, 5), cid(0, 9), cid(1, 9), cid(2, 13), cid(3, 2), cid(0, 7)]
eq(P.evalBest(seven)[0], 2, "seven cards find two pair")
eq(P.evalBest(seven)[1], 9, "nines are the top pair")

// Kicker matters.
ok(P.compareHands(
    P.evalBest([cid(0, 1), cid(1, 1), cid(2, 5), cid(3, 6), cid(0, 7), cid(1, 8), cid(2, 13)]),
    P.evalBest([cid(0, 1), cid(3, 1), cid(2, 5), cid(3, 6), cid(0, 7), cid(1, 8), cid(2, 12)])) > 0,
   "ace pair with king kicker beats ace pair with queen kicker")

// Flush picks its best five from seven.
var flush7 = [cid(1, 2), cid(1, 5), cid(1, 7), cid(1, 9), cid(1, 11), cid(0, 3), cid(1, 6)]
eq(P.evalBest(flush7)[0], 5, "seven-card flush")
eq(P.evalBest(flush7)[1], 11, "flush high card")

// ========================================================== 2. pots

section("side pots")

// A commits 100, B 100, C all-in 40. Levels 40 and 100.
var pots = P.buildPots([100, 100, 40], [false, false, false])
eq(pots.length, 2, "short all-in builds two pots")
eq(pots[0].amount, 120, "main pot amount")
eq(pots[0].eligible, [0, 1, 2], "main pot eligibility")
eq(pots[1].amount, 120, "side pot amount")
eq(pots[1].eligible, [0, 1], "side pot eligibility")

// Folded money joins the pot but wins nothing.
pots = P.buildPots([200, 60, 0], [false, true, false])
eq(pots.length, 1, "folded contributor builds one pot")
eq(pots[0].amount, 260, "folded money is in the pot")
eq(pots[0].eligible, [0], "folder eligible for nothing")

// Two short stacks at the same level share a layer.
pots = P.buildPots([500, 500, 80, 80], [false, false, false, false])
eq(pots.length, 2, "four-way two levels")
eq(pots[0].amount, 320, "four-way main pot")
eq(pots[1].amount, 840, "four-way side pot")

// ================================================== 3. betting scenarios

section("betting mechanics")

function freshGame(botCount) { return P.newSession(botCount, 12345) }
function sittingCount(st) {
  var n = 0
  for (var i = 0; i < 5; i++) if (st.seats[i].sitting) n++
  return n
}

// Blinds and first actor, five-handed.
var st = freshGame(4)
P.startHand(st)
eq(st.currentBet, 20, "preflop current bet is the big blind")
eq(st.actor, (st.bbSeat + 1) % 5, "first actor sits after the big blind")
eq(st.seats[st.sbSeat].bet, 10, "small blind posted")
eq(st.seats[st.bbSeat].bet, 20, "big blind posted")
eq(st.deck.length, 42, "deck holds the undealt cards")
eq(inPlay(st), 5000, "chips conserved at deal")

// Preflop: four limpers plus the blinds, round completes, flop comes.
var guard = 0
while (st.phase === "betting" && st.street === 0 && guard++ < 200) {
  var legal = P.legalActions(st)
  P.act(st, legal.toCall <= 0 ? "check" : "call")
}
eq(st.street, 1, "completed preflop round moves to the flop")
eq(st.community.length, 3, "flop dealt")
eq(st.pot, 100, "five limpers build a 100 pot")
for (var i = 0; i < 5; i++) eq(st.seats[i].bet, 0, "bets collected on street change")
eq(inPlay(st), 5000, "chips conserved after preflop")

// Calls around every street reach showdown and pay the pot out.
guard = 0
while (st.phase === "betting" && guard++ < 400) {
  legal = P.legalActions(st)
  P.act(st, legal.toCall <= 0 ? "check" : "call")
}
ok(st.phase === "handOver", "calls to the river end the hand")
eq(st.pot, 0, "pot fully awarded")
eq(inPlay(st), 5000, "chips conserved after showdown")

// Heads-up: button posts small blind, acts first preflop, acts last postflop.
st = freshGame(1)
P.startHand(st)
eq(sittingCount(st), 2, "heads-up has two players")
eq(st.sbSeat, st.button, "heads-up button is the small blind")
ok(st.bbSeat !== st.button, "heads-up big blind is the other player")
eq(st.actor, st.button, "heads-up preflop first actor is the button")
guard = 0
while (st.phase === "betting" && st.street === 0 && guard++ < 100) {
  legal = P.legalActions(st)
  P.act(st, legal.toCall <= 0 ? "check" : "call")
}
if (st.phase === "betting" && st.street > 0)
  eq(st.actor, st.bbSeat, "heads-up postflop first actor is the big blind")
eq(inPlay(st), 2000, "chips conserved in heads-up play")

// Raise war bounded by stacks: everyone keeps min-raising until the money
// is gone; the engine must still terminate.
st = freshGame(4)
P.startHand(st)
guard = 0
while (st.phase === "betting" && guard++ < 500) {
  legal = P.legalActions(st)
  var seat = st.seats[st.actor]
  if (legal.canRaise && seat.chips > 200)
    P.act(st, "raise", Math.min(legal.maxTo, legal.minTo + 60))
  else if (legal.toCall <= 0) P.act(st, "check")
  else P.act(st, "call")
}
ok(guard <= 500, "raise war terminates")
eq(inPlay(st), 5000, "chips conserved through raise war")

// Short all-ins mixed with full raises must neither loop nor leak chips.
st = freshGame(4)
P.startHand(st)
guard = 0
while (st.phase === "betting" && guard++ < 500) {
  legal = P.legalActions(st)
  var r = (st.seed >>> 3) % 10
  if (legal.canRaise && r < 2) P.act(st, "raise", legal.maxTo)
  else if (legal.toCall <= 0) P.act(st, "check")
  else P.act(st, "call")
}
ok(guard <= 500, "short-all-in mix terminates")
eq(inPlay(st), 5000, "chips conserved through short all-ins")

// Save/restore round-trip: a snapshot mid-hand replays to the same chips.
st = freshGame(4)
P.startHand(st)
guard = 0
while (st.phase === "betting" && guard < 3) {
  legal = P.legalActions(st)
  P.act(st, legal.toCall <= 0 ? "check" : "call")
  guard++
}
var saved = JSON.stringify(st)
function runOut(g) {
  var n = 0
  while (g.phase === "betting" && n++ < 800) {
    var lg = P.legalActions(g)
    if (g.seats[g.actor].bot) { var d = P.botDecision(g); P.act(g, d.type, d.amount) }
    else P.act(g, lg.toCall <= 0 ? "check" : "call")
  }
  return g.seats.map(function (s) { return s.chips })
}
var chipsA = runOut(st)
var replay = runOut(JSON.parse(saved))
eq(replay, chipsA, "deterministic replay after restore")

// ============================================== 4. random simulation

section("random simulation (bot vs bot)")

var SIM = 2000
var problems = 0
for (var sim = 0; sim < SIM; sim++) {
  var bots = (sim % 4) + 1     // 1..4 bots
  var g = P.newSession(bots, (sim * 7919 + 13) >>> 0)
  var total = P.START_STACK * (1 + bots)
  var guardH = 0
  while (g.phase !== "sessionOver" && guardH < 20000) {
    guardH++
    if (g.phase === "handOver" || g.phase === "idle") { P.startHand(g); continue }
    if (g.phase === "betting") {
      var lg = P.legalActions(g)
      if (g.seats[g.actor].bot) {
        var dec = P.botDecision(g)
        P.act(g, dec.type, dec.amount)
      } else {
        P.act(g, lg.toCall <= 0 ? "check" : "call")
      }
      if (inPlay(g) !== total) {
        problems++
        console.log("FAIL: chip conservation broke in sim " + sim)
        break
      }
      if (g.actor >= 0) {
        var a = g.seats[g.actor]
        if (a.folded || a.allIn || !a.sitting) {
          problems++
          console.log("FAIL: actor cannot act in sim " + sim)
          break
        }
      }
    }
  }
  if (guardH >= 20000) { problems++; console.log("FAIL: sim " + sim + " did not finish") }
  if (problems > 0) break
}
ok(problems === 0, "simulation invariants hold across " + SIM + " sessions")

// ======================================================== summary

console.log("")
console.log(checks + " checks, " + failures + " failures")
process.exit(failures > 0 ? 1 : 0)
