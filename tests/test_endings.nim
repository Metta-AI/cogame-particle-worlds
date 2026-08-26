## End conditions. `results.reason` is a closed enum of three values and
## `results.endRule` a closed enum of four; a round ends ONLY on the clock, and
## a round the wall clock never reached is EXCLUDED from the mean rather than
## scored 0.

import std/[json, sets, unittest]
import bitworld/spriteprotocol
import ../src/mpe/sim
import fixture

const
  LegalReasons = [ReasonComplete, ReasonDeadline, ReasonFault]
  LegalEndRules = [EndRuleFullTime, EndRuleWallClock, EndRuleSimFault,
                   EndRuleHostError]
  LegalRoundRules = [EndRuleFullTime, EndRuleWallClock]
  LegalModes = ["spread", "deceive", "crypto", "tag"]

proc runRounds(config: GameConfig, rounds: int): SimServer =
  ## Plays `rounds` rounds with all-zero inputs, re-seating between them
  ## exactly as the server's round switch does.
  result = seatedSim(config)
  var played = 0
  var inputs = newSeq[InputState](result.players.len)
  while played < rounds:
    let before = result.phase
    result.step(inputs, inputs)
    if before != GameOver and result.phase == GameOver:
      inc played
      if played >= rounds:
        break
      result.roundIndex = played
      result.reseat(config)

suite "end conditions":

  test "a round ends exactly on tick maxTicks, not the tick before or after":
    var config = fixtureConfig(@[modeSpread])
    var sim = seatedSim(config)
    var inputs = newSeq[InputState](sim.players.len)
    for tick in 0 ..< config.maxTicks - 1:
      sim.step(inputs, inputs)
      check sim.phase == Playing
      check sim.roundLog.len == 0
    sim.step(inputs, inputs)
    check sim.phase == GameOver
    check sim.roundLog.len == 1
    check sim.roundLog[0].ticks == config.maxTicks
    check sim.roundLog[0].endRule == EndRuleFullTime

  test "four rounds give complete / full_time with roundsPlayed 4":
    var config = fixtureConfig()
    var sim = runRounds(config, 4)
    sim.seatNames = ["a", "b", "c", "d"]
    check sim.roundLog.len == 4
    for i in 0 ..< 4:
      check sim.roundLog[i].ticks == config.maxTicks
      check sim.roundLog[i].endRule == EndRuleFullTime
    let results = parseJson(sim.particleResultsJson())
    check results["reason"].getStr() == ReasonComplete
    check results["endRule"].getStr() == EndRuleFullTime
    check results["roundsPlayed"].getInt() == 4
    check results["modes"].len == 4
    check results["roundTicks"].len == 4

  test "results.bumps is the EPISODE's bump ticks, not the last round's":
    ## Every other seat-indexed number in the document is an episode aggregate
    ## (`scores`, `llmTurns`, `fallbackTurns`) or an explicit per-round array
    ## (`roundScores`, `roles`). `sim.bumps` is the live per-round counter
    ## `beginRound` zeroes, so reporting it named round 4 alone -- which in the
    ## default variant is `tag`, the one mode where bumps do not score.
    var config = fixtureConfig()
    var sim = seatedSim(config)
    var inputs = newSeq[InputState](sim.players.len)
    var played = 0
    var expected: array[4, int]
    while played < 4:
      ## Park two particles on top of each other so bumps really accrue, in
      ## every round.
      sim.players[1].x = sim.players[0].x
      sim.players[1].y = sim.players[0].y
      let before = sim.phase
      sim.step(inputs, inputs)
      if before != GameOver and sim.phase == GameOver:
        ## The counters are still the round's own here: bankRound has run and
        ## beginRound has not.
        for seat in 0 ..< 4:
          expected[seat] += sim.bumps[seat]
        inc played
        if played >= 4:
          break
        sim.roundIndex = played
        sim.reseat(config)
    sim.seatNames = ["a", "b", "c", "d"]
    let results = parseJson(sim.particleResultsJson())
    check expected[0] > 0
    for seat in 0 ..< 4:
      check sim.episodeBumps[seat] == expected[seat]
      check results["bumps"][seat].getInt() == expected[seat]
    ## And it really is more than the last round's counter.
    check results["bumps"][0].getInt() > sim.bumps[0]

  test "roundLog records exactly one entry per round played":
    for rounds in 1 .. 4:
      var sim = runRounds(fixtureConfig(), rounds)
      check sim.roundLog.len == rounds
      check sim.roundsPlayed == rounds

  test "the wall-clock stop banks the round in progress and excludes the rest":
    var config = fixtureConfig()
    var sim = seatedSim(config)
    var inputs = newSeq[InputState](sim.players.len)
    for tick in 0 ..< 100:
      sim.step(inputs, inputs)
    ## The server's wall-clock stop: bank the round in progress from the ticks
    ## it ran, then settle.
    let ranFor = sim.gameTicksElapsed()
    sim.endReason = ReasonDeadline
    sim.endRule = EndRuleWallClock
    sim.bankRound(ranFor, EndRuleWallClock)
    sim.finishGame(Red, isDraw = true)
    sim.seatNames = ["a", "b", "c", "d"]
    check sim.roundLog.len == 1
    check sim.roundLog[0].ticks == ranFor
    check sim.roundLog[0].endRule == EndRuleWallClock
    let results = parseJson(sim.particleResultsJson())
    check results["reason"].getStr() == ReasonDeadline
    check results["endRule"].getStr() == EndRuleWallClock
    check results["roundsPlayed"].getInt() == 1
    ## Rounds never started are EXCLUDED from the mean, not zeroed: the mean is
    ## over one round, so it equals that round's permille.
    for seat in 0 ..< 4:
      check abs(results["scores"][seat].getFloat() -
        results["roundScores"][seat][0].getFloat()) < 1e-9
    check results["roundEndRules"].len == 1
    check results["roundEndRules"][0].getStr() == EndRuleWallClock

  test "a tripped invariant is fault / sim_fault, scored from what was banked":
    var sim = runRounds(fixtureConfig(), 2)
    sim.seatNames = ["a", "b", "c", "d"]
    ## Trip the guard the way the sim does: a mark inside a wall.
    sim.landmarks[0].x = 1
    sim.landmarks[0].y = 1
    expect SimGuardError:
      sim.checkFieldInvariants()
    sim.endReason = ReasonFault
    sim.endRule = EndRuleSimFault
    let results = parseJson(sim.particleResultsJson())
    check results["reason"].getStr() == ReasonFault
    check results["endRule"].getStr() == EndRuleSimFault
    check results["roundsPlayed"].getInt() == 2
    for seat in 0 ..< 4:
      check results["win"][seat].getBool() == false

  test "the sim guard catches every invariant the design lists":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    sim.checkFieldInvariants()                        ## a clean round passes
    block roleIndex:
      var broken = sim
      broken.roleIndex = [1, 1, 2, 3]
      expect SimGuardError: broken.checkFieldInvariants()
    block symbol:
      var broken = sim
      broken.commSymbol[2] = 99
      expect SimGuardError: broken.checkFieldInvariants()
    block key:
      var broken = sim
      broken.keySymbols = [1, 1, 2, 3]
      expect SimGuardError: broken.checkFieldInvariants()
    block spacing:
      var broken = sim
      broken.landmarks[1].x = broken.landmarks[0].x + 4
      broken.landmarks[1].y = broken.landmarks[0].y
      expect SimGuardError: broken.checkFieldInvariants()
    block bumps:
      var broken = sim
      broken.bumps[0] = broken.tickCount + 1000
      expect SimGuardError: broken.checkFieldInvariants()
    block credit:
      var broken = sim
      broken.tagTicks = 0
      broken.tagCredit[1] = 5
      expect SimGuardError: broken.checkFieldInvariants()
    block banked:
      var broken = sim
      broken.roundLog.add(RoundLogEntry(
        mode: modeSpread, ticks: 1, endRule: EndRuleFullTime,
        permille: [0, 5000, 0, 0], goal: -1))
      expect SimGuardError: broken.checkFieldInvariants()
    block markCount:
      var broken = sim
      broken.landmarks.setLen(3)
      expect SimGuardError: broken.checkFieldInvariants()

  test "every declared enum member really is declared":
    var sim = runRounds(fixtureConfig(), 4)
    sim.seatNames = ["a", "b", "c", "d"]
    let results = parseJson(sim.particleResultsJson())
    check results["reason"].getStr() in LegalReasons
    check results["endRule"].getStr() in LegalEndRules
    for entry in results["roundEndRules"]:
      check entry.getStr() in LegalRoundRules
    for entry in results["modes"]:
      check entry.getStr() in LegalModes
    ## And the closed sets have exactly the declared sizes.
    check LegalReasons.len == 3
    check LegalEndRules.len == 4
    check LegalRoundRules.len == 2
    check LegalModes.len == 4
    var modes: HashSet[string]
    for mode in Mode:
      modes.incl($mode)
    check modes.len == LegalModes.len
    for name in LegalModes:
      check name in modes

  test "there is no early win: a round never ends before its clock":
    ## MPE scenarios are fixed-horizon, and a fixed horizon is what makes the
    ## four rounds comparable and the replay a predictable length. Park every
    ## particle on the goal in every mode and prove the round still runs out.
    for mode in Mode:
      var config = fixtureConfig(@[mode])
      var sim = seatedSim(config)
      var inputs = newSeq[InputState](sim.players.len)
      let (gx, gy) = sim.markCentre(max(0, sim.goalLandmark))
      for seat in 0 ..< 4:
        sim.players[seat].x = clamp(gx + seat * 14, 0, MapWidth - 1)
        sim.players[seat].y = gy
      for tick in 0 ..< config.maxTicks - 1:
        sim.step(inputs, inputs)
        check sim.phase == Playing
      sim.step(inputs, inputs)
      check sim.phase == GameOver
