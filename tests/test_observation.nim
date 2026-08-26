## The per-seat view and the ENTITLEMENT MATRIX, asserted from both sides: what
## each seat must see, and what it must never see.

import std/[json, strutils, unittest]
import ../src/mpe/[sim, control, directives, decide]
import fixture

proc viewOf(sim: SimServer, seat: int): JsonNode =
  var engine = initDecisionEngine(sim)
  parseJson(engine.seatViewJson(sim, seat, 3, 10))

suite "the per-seat observation":

  test "every seat sees all four particles and all four marks with colours":
    for mode in Mode:
      var sim = seatedSim(fixtureConfig(@[mode]))
      for seat in 0 ..< 4:
        let view = sim.viewOf(seat)
        check view["agents"].len == 4
        check view["marks"].len == LandmarkCount
        for mark in view["marks"]:
          check mark["colour"].getStr() in MarkColourNames
          check mark["r"].getInt() == sim.config.landmarkRadius
          check mark["pos"].len == 2
        check view["field"]["w"].getInt() == MapWidth
        check view["field"]["h"].getInt() == MapHeight
        check view["mode"].getStr() == $mode
        check view["you"]["id"].getStr() == sim.cogAlias(seat)

  test "the radio carries all four seats with no distance filter":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    ## Push two particles to opposite corners: the channel is GLOBAL, so both
    ## must still appear in every seat's radio block.
    sim.players[0].x = ArenaBorder + 20
    sim.players[0].y = ArenaBorder + 20
    sim.players[3].x = MapWidth - ArenaBorder - 20
    sim.players[3].y = MapHeight - ArenaBorder - 20
    for seat in 0 ..< 4:
      sim.installSymbol(seat, seat + 1, 0)
    for seat in 0 ..< 4:
      let view = sim.viewOf(seat)
      check view["radio"].len == 4
      for i in 0 ..< 4:
        check view["radio"][i]["id"].getStr() == sim.cogAlias(i)
        check view["radio"][i]["now"].getStr() == symbolText(i + 1)

  test "deceive: the three good agents see the goal, the adversary sees null":
    var sim = seatedSim(fixtureConfig(@[modeDeceive]))
    let adversary = sim.seatWithRole(0)
    check adversary >= 0
    for seat in 0 ..< 4:
      let secret = sim.viewOf(seat)["secret"]
      if seat == adversary:
        check secret["goal"].kind == JNull
        check secret["goal_colour"].kind == JNull
        check secret["goal_is_one_of"].len == 4
      else:
        check secret["goal"].getInt() == sim.goalLandmark
        check secret["goal_colour"].getStr() ==
          MarkColourNames[sim.goalColour()]
      ## The key never exists outside crypto.
      check secret["key"].kind == JNull

  test "crypto: Alice sees goal + key, Bob key only, each Eve neither":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    for seat in 0 ..< 4:
      let secret = sim.viewOf(seat)["secret"]
      case sim.roleIndex[seat]
      of 0:
        check secret["goal"].getInt() == sim.goalLandmark
        check secret["goal_colour"].getStr() ==
          MarkColourNames[sim.goalColour()]
        check secret["key"].len == LandmarkCount
      of 1:
        check secret["goal"].kind == JNull
        check secret["goal_colour"].kind == JNull
        check secret["key"].len == LandmarkCount
      else:
        check secret["goal"].kind == JNull
        check secret["goal_colour"].kind == JNull
        check secret["key"].kind == JNull

  test "the key an entitled seat sees is the REAL key, symbol -> colour":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    let bob = sim.seatWithRole(1)
    let key = sim.viewOf(bob)["secret"]["key"]
    check key.len == LandmarkCount
    for colour in 0 ..< LandmarkCount:
      check key[colour][0].getStr() == symbolText(sim.keySymbols[colour])
      check key[colour][1].getStr() == MarkColourNames[colour]

  test "spread and tag hide nothing because there is nothing to hide":
    for mode in [modeSpread, modeTag]:
      var sim = seatedSim(fixtureConfig(@[mode]))
      for seat in 0 ..< 4:
        let view = sim.viewOf(seat)
        check view["secret"]["goal"].kind == JNull
        check view["secret"]["key"].kind == JNull
        if mode == modeSpread:
          check view.hasKey("cover_pct")
          check view.hasKey("bumps")
        else:
          check view["contact"].len == 4
          check view.hasKey("tag_ticks")

  test "`secret` always carries the same keys, so null is never `absent`":
    for mode in Mode:
      var sim = seatedSim(fixtureConfig(@[mode]))
      for seat in 0 ..< 4:
        let secret = sim.viewOf(seat)["secret"]
        check secret.hasKey("goal")
        check secret.hasKey("goal_colour")
        check secret.hasKey("key")

  test "beliefs publish nearest_mark / settled_ticks for every mobile agent":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    for tick in 0 ..< 60:
      discard sim.updateBeliefs()
    for seat in 0 ..< 4:
      let beliefs = sim.viewOf(seat)["beliefs"]
      ## Alice is anchored, so three mobile agents are published.
      check beliefs.len == 3
      for entry in beliefs:
        check entry.hasKey("nearest_mark")
        check entry.hasKey("settled_ticks")
        check entry["settled_ticks"].getInt() >= 0

  test "the seed, the RNG state and the next round appear nowhere":
    var config = fixtureConfig()
    config.seed = 1234567
    var sim = seatedSim(config)
    for seat in 0 ..< 4:
      let text = (var engine = initDecisionEngine(sim);
                  engine.seatViewJson(sim, seat, 3, 10))
      check "1234567" notin text
      check "seed" notin text
      check "rng" notin text
      ## The mode SEQUENCE is not in a seat frame: only THIS round's mode is.
      check "\"rounds\":" notin text
      for mode in Mode:
        if mode != sim.mode:
          check ($mode) notin text
      ## Nor the next round's mark draw: only the current one.
      check "spawnOffset" notin text
      check "keySymbols" notin text

  test "no seat frame carries another seat's order for the turn being decided":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = initDecisionEngine(sim)
    ## Install a directive on every seat, as the turn boundary does.
    for seat in 0 ..< 4:
      engine.directives[seat] = SquadDirective(
        note: "SECRET-NOTE-" & $seat,
        source: dsScripted,
        orders: @[CogOrder(cogIndex: seat, id: sim.cogAlias(seat),
                           intent: intCover, targetX: 100, targetY: 100,
                           symbol: 4)])
      engine.haveDirective[seat] = true
    for seat in 0 ..< 4:
      let text = engine.seatViewJson(sim, seat, 4, 10)
      ## Its OWN last note is legitimate intel; nobody else's ever is.
      check ("SECRET-NOTE-" & $seat) in text
      for other in 0 ..< 4:
        if other != seat:
          check ("SECRET-NOTE-" & $other) notin text
      check "intent" notin text
      check "cover" notin text or sim.mode == modeSpread

  test "the seat's own score block reports banked rounds and the mean":
    var sim = seatedSim(fixtureConfig())
    for seat in 0 ..< 4:
      sim.roundAccum[seat] = int64(seat) * 2000
    sim.bankRound(10, EndRuleFullTime)
    for seat in 0 ..< 4:
      let score = sim.viewOf(seat)["score"]
      check score["rounds_banked"].len == 1
      check abs(score["episode_so_far"].getFloat() -
        sim.episodePermille(seat).float / 1000.0) < 1e-9
      check score["this_round_so_far"].getFloat() >= 0.0
      check score["this_round_so_far"].getFloat() <= 1.0
