## The scoring formulas and their SIGNS. Higher is better, every term is
## non-negative, every round permille is in 0..1000 and every episode score is
## in [0, 1]. The zero-sum modes are asserted zero-sum by construction over
## random position draws, not by inspection.

import std/[json, random, unittest]
import ../src/mpe/sim
import fixture

proc placeAll(sim: var SimServer, rng: var Rand) =
  for seat in 0 ..< sim.players.len:
    sim.players[seat].x = rng.rand(MapWidth - 1)
    sim.players[seat].y = rng.rand(MapHeight - 1)

suite "scoring":

  test "closeness is 1000 on the mark, 0 at the scale, and monotone":
    check closeness(0, 500) == 1000
    check closeness(500, 500) == 0
    check closeness(5000, 500) == 0
    var previous = 1001
    for d in 0 .. 700:
      let value = closeness(d, 500)
      check value >= 0
      check value <= 1000
      check value <= previous
      previous = value

  test "spread shares base and only the bump debit differs, never negative":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var rng = initRand(4242)
    for trial in 0 ..< 200:
      sim.placeAll(rng)
      let cover = sim.coverPermille()
      check cover >= 0
      check cover <= 1000
      for seat in 0 ..< 4:
        sim.roundAccum[seat] = int64(cover) * 100
      sim.bumps = [0, 10, 400, 100_000]
      for seat in 0 ..< 4:
        let permille = sim.roundPermille(seat, 100)
        check permille >= 0
        check permille <= 1000
      ## The debit is capped, so the worst bumper never falls below
      ## base - bumpPenaltyCap and never below 0.
      check sim.roundPermille(0, 100) >= sim.roundPermille(1, 100)
      check sim.roundPermille(1, 100) >= sim.roundPermille(2, 100)
      check sim.roundPermille(2, 100) >= sim.roundPermille(3, 100)
      check sim.roundPermille(0, 100) - sim.roundPermille(3, 100) <=
        sim.config.bumpPenaltyCap

  test "spread is never negative even at a full round of bump ticks":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = 0
      sim.bumps[seat] = 1080
    for seat in 0 ..< 4:
      check sim.roundPermille(seat, 1080) == 0

  test "deceive is zero-sum on every unclamped tick over 100k draws":
    var sim = seatedSim(fixtureConfig(@[modeDeceive]))
    var rng = initRand(90210)
    var unclamped = 0
    for trial in 0 ..< 100_000:
      sim.placeAll(rng)
      for seat in 0 ..< 4:
        sim.roundAccum[seat] = 0
      sim.scoreTick()
      let adversary = sim.seatWithRole(0)
      var goodSeat = -1
      for seat in 0 ..< 4:
        if seat != adversary:
          goodSeat = seat
          break
      let
        advP = int(sim.roundAccum[adversary])
        goodP = int(sim.roundAccum[goodSeat])
      check advP >= 0
      check advP <= 1000
      check goodP >= 0
      check goodP <= 1000
      if advP > 0 and advP < 1000 and goodP > 0 and goodP < 1000:
        inc unclamped
        check advP + goodP == 1000
      ## Every good agent gets the SAME term.
      for seat in 0 ..< 4:
        if seat != adversary:
          check int(sim.roundAccum[seat]) == goodP
    echo "deceive: ", unclamped, "/100000 draws were unclamped"
    check unclamped > 50_000

  test "crypto pairs rise with Bob and fall with the Eves":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    let
      alice = sim.seatWithRole(0)
      bob = sim.seatWithRole(1)
      eve1 = sim.seatWithRole(2)
      eve2 = sim.seatWithRole(3)
      (gx, gy) = sim.markCentre(sim.goalLandmark)
    # Bob ON the goal, both Eves 500 px away: the pair takes it.
    sim.players[bob].x = gx
    sim.players[bob].y = gy
    for eve in [eve1, eve2]:
      sim.players[eve].x = clamp(gx + 520, 0, MapWidth - 1)
      sim.players[eve].y = clamp(gy + 520, 0, MapHeight - 1)
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = 0
    sim.scoreTick()
    check int(sim.roundAccum[bob]) > 900
    check int(sim.roundAccum[alice]) == int(sim.roundAccum[bob])
    check int(sim.roundAccum[eve1]) < 100
    check int(sim.roundAccum[eve2]) < 100
    # And the reverse: an Eve on the goal while Bob is 500 px away.
    sim.players[eve1].x = gx
    sim.players[eve1].y = gy
    sim.players[bob].x = clamp(gx + 520, 0, MapWidth - 1)
    sim.players[bob].y = clamp(gy + 520, 0, MapHeight - 1)
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = 0
    sim.scoreTick()
    check int(sim.roundAccum[eve1]) > 900
    check int(sim.roundAccum[bob]) < 100
    check int(sim.roundAccum[alice]) < 100

  test "tag pays a pursuer for contact and an untouched evader in full":
    var sim = seatedSim(fixtureConfig(@[modeTag]))
    let evader = sim.seatWithRole(0)
    var pursuer = -1
    for seat in 0 ..< 4:
      if seat != evader:
        pursuer = seat
        break
    sim.tagCredit[pursuer] = sim.config.tagTargetTicks
    sim.tagTicks = 0
    check sim.tagRoundPermille(pursuer, 1080) == 1000
    check sim.tagRoundPermille(evader, 1080) == 1000
    sim.tagCredit[pursuer] = sim.config.tagTargetTicks div 2
    check abs(sim.tagRoundPermille(pursuer, 1080) - 500) <= 5
    sim.tagTicks = 1080
    check sim.tagRoundPermille(evader, 1080) == 0
    sim.tagCredit[pursuer] = 10 * sim.config.tagTargetTicks
    check sim.tagRoundPermille(pursuer, 1080) == 1000   ## never above 1000

  test "the episode score is the mean over PLAYED rounds and lies in [0, 1]":
    var sim = seatedSim(fixtureConfig())
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = int64(200 * (seat + 1)) * 10
    sim.bankRound(10, EndRuleFullTime)
    check sim.roundsPlayed == 1
    for seat in 0 ..< 4:
      check sim.episodePermille(seat) == 200 * (seat + 1)
    ## A SECOND round at 1000 for everybody: the mean, not the sum.
    sim.mode = modeSpread
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = 10_000
      sim.bumps[seat] = 0
    sim.bankRound(10, EndRuleFullTime)
    check sim.roundsPlayed == 2
    for seat in 0 ..< 4:
      let mean = sim.episodePermille(seat)
      check mean == (200 * (seat + 1) + 1000) div 2
      check mean >= 0
      check mean <= 1000

  test "win is score >= 0.5 and a fault wins nothing":
    var sim = seatedSim(fixtureConfig())
    sim.seatNames = ["a", "b", "c", "d"]
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = int64(seat) * 3000   ## 0 / 300 / 600 / 900
    sim.bankRound(10, EndRuleFullTime)
    var results = parseJson(sim.particleResultsJson())
    for seat in 0 ..< 4:
      let score = results["scores"][seat].getFloat()
      check score >= 0.0
      check score <= 1.0
      check results["win"][seat].getBool() == (score >= 0.5)
    sim.endReason = ReasonFault
    sim.endRule = EndRuleSimFault
    results = parseJson(sim.particleResultsJson())
    for seat in 0 ..< 4:
      check results["win"][seat].getBool() == false
      ## The banked rounds are still reported, so a fault is scored from what
      ## was actually measured.
      check results["roundsPlayed"].getInt() == 1

  test "every banked round permille is inside 0..1000 for every mode":
    for mode in Mode:
      var sim = seatedSim(fixtureConfig(@[mode]))
      var rng = initRand(7 + ord(mode))
      for tick in 0 ..< 240:
        sim.placeAll(rng)
        sim.scoreTick()
      sim.bankRound(240, EndRuleFullTime)
      for seat in 0 ..< 4:
        let permille = sim.roundLog[^1].permille[seat]
        check permille >= 0
        check permille <= 1000
