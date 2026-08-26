## THE BOUNDED-ORDERS / LEGALITY ASSERTION on the scripted baselines, plus the
## control layer's own invariants.
##
## Both baselines emit the SAME directive object an LLM does, so one validator
## covers both policy kinds -- which is what makes this test meaningful rather
## than a tautology about a bot that cannot be illegal.

import std/[json, random, strutils, unicode, unittest]
import bitworld/spriteprotocol
import ../src/mpe/[sim, control, directives, baselines]
import fixture

proc scatter(sim: var SimServer, rng: var Rand) =
  for seat in 0 ..< sim.players.len:
    sim.players[seat].x = rng.rand(MapWidth - 1)
    sim.players[seat].y = rng.rand(MapHeight - 1)
    sim.players[seat].velX = rng.rand(2 * sim.config.maxSpeed) -
      sim.config.maxSpeed
    sim.players[seat].velY = rng.rand(2 * sim.config.maxSpeed) -
      sim.config.maxSpeed
    sim.players[seat].aimBrads = rng.rand(255)
    sim.commSymbol[seat] = rng.rand(SymbolAlphabet.len)
    sim.commPrev[seat] = rng.rand(SymbolAlphabet.len)

proc legalMask(mask: uint8): bool =
  ## Legality is STRUCTURAL in the control layer, and this is the assertion
  ## that says so: never Up+Down, never Left+Right, and NEVER A or C, because
  ## particle worlds has no weapon, no throwable and no trigger.
  if (mask and ButtonUp) != 0 and (mask and ButtonDown) != 0: return false
  if (mask and ButtonLeft) != 0 and (mask and ButtonRight) != 0: return false
  if (mask and ButtonA) != 0: return false
  if (mask and ButtonC) != 0: return false
  true

suite "the control layer and the scripted baselines":

  test "500 random states x 2 baselines x 4 modes x 4 seats are all legal":
    var rng = initRand(20260826)
    var checked = 0
    for mode in Mode:
      var config = fixtureConfig(@[mode])
      var sim = seatedSim(config)
      var ctl = initControlState(sim)
      for trial in 0 ..< 125:
        sim.scatter(rng)
        ctl.observeEnemies(sim)
        for baseline in [blDrifter, blBeeline]:
          for seat in 0 ..< 4:
            let directive = scriptedDirective(ctl, sim, baseline, @[seat])
            check directive.source == dsScripted
            check directive.note.runeLen <= MaxNoteRunes
            check directive.orders.len == 1
            let order = directive.orders[0]
            ## Exactly the seat's own id.
            check order.id == sim.cogAlias(seat)
            check order.cogIndex == seat
            ## An intent in the enum, by construction of the type.
            check ($order.intent).len > 0
            ## A target inside the field box.
            check order.targetX >= 0
            check order.targetX < MapWidth
            check order.targetY >= 0
            check order.targetY < MapHeight
            if order.hasFace:
              check order.faceX >= 0
              check order.faceX < MapWidth
              check order.faceY >= 0
              check order.faceY < MapHeight
            ## A single rune from the nine-value alphabet.
            let symbol = symbolTextOf(order.symbol)
            check symbol.runeLen == 1
            check (symbol == SymbolSilence or symbol[0] in SymbolAlphabet)
            ## And the compiled mask has only legal bits.
            let mask = ctl.compileMask(sim, order, seat)
            check legalMask(mask)
            inc checked
    check checked == 4 * 125 * 2 * 4

  test "the same (state, order) pair always compiles to the same byte":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    let order = CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intCover,
      targetX: 400, targetY: 300, symbol: 3)
    let first = ctl.compileMask(sim, order, 0)
    for repeat in 0 ..< 50:
      check ctl.compileMask(sim, order, 0) == first

  test "a particle inside ArriveRadius of its goal sets no d-pad bit":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var ctl = initControlState(sim)
    ctl.observeEnemies(sim)
    let (mx, my) = sim.markCentre(0)
    sim.players[0].x = mx
    sim.players[0].y = my
    let order = CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intCover,
      targetX: mx, targetY: my, symbol: 0)
    let mask = ctl.compileMask(sim, order, 0)
    check (mask and (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) == 0

  test "a particle ordered to an unreachable target still moves every tick":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var ctl = initControlState(sim)
    ## Deep inside the border wall: nearestOpenCell will pull the goal back
    ## onto the floor, so the particle keeps steering rather than freezing.
    let order = CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intGo,
      targetX: 1, targetY: 1, symbol: 0)
    var moved = 0
    var inputs = newSeq[InputState](sim.players.len)
    for tick in 0 ..< 120:
      ctl.observeEnemies(sim)
      let mask = ctl.compileMask(sim, order, 0)
      check legalMask(mask)
      if mask != 0:
        inc moved
      inputs[0] = decodeInputMask(mask)
      sim.step(inputs, inputs)
    check moved >= 110

  test "evade never picks a non-walkable probe":
    var sim = seatedSim(fixtureConfig(@[modeTag]))
    var ctl = initControlState(sim)
    var rng = initRand(77)
    for trial in 0 ..< 400:
      sim.scatter(rng)
      ctl.observeEnemies(sim)
      for seat in 0 ..< 4:
        let point = ctl.evadePoint(sim, seat)
        check point.x >= 0
        check point.x < MapWidth
        check point.y >= 0
        check point.y < MapHeight
        ## Either a walkable probe, or the field centre when none was.
        check (sim.canOccupy(point.x, point.y) or point == centreOfField())

  test "shadow holds station inside its stand-off instead of oscillating":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    var ctl = initControlState(sim)
    let
      bob = sim.seatWithRole(1)
      eve = sim.seatWithRole(2)
    ## Put the eavesdropper 30 px from Bob -- well inside the 60 px stand-off.
    sim.players[eve].x = clamp(sim.players[bob].x + 30, 0, MapWidth - 1)
    sim.players[eve].y = sim.players[bob].y
    ctl.observeEnemies(sim)
    let order = CogOrder(
      cogIndex: eve, id: sim.cogAlias(eve), intent: intShadow,
      targetX: sim.players[bob].x, targetY: sim.players[bob].y, symbol: 0)
    let goal = ctl.goalFor(sim, order, eve)
    let (px, py) = sim.particleCentre(eve)
    check goal == (px, py)            ## holds station: the goal IS here
    check (ctl.compileMask(sim, order, eve) and
      (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) == 0

  test "a tag pursuer shadows to CONTACT, not to the eavesdropper stand-off":
    var sim = seatedSim(fixtureConfig(@[modeTag]))
    var ctl = initControlState(sim)
    let evader = sim.seatWithRole(0)
    var pursuer = -1
    for seat in 0 ..< 4:
      if seat != evader:
        pursuer = seat
        break
    sim.players[pursuer].x = clamp(sim.players[evader].x + 300, 0, MapWidth - 1)
    sim.players[pursuer].y = sim.players[evader].y
    ctl.observeEnemies(sim)
    let order = CogOrder(
      cogIndex: pursuer, id: sim.cogAlias(pursuer), intent: intShadow,
      targetX: sim.players[evader].x, targetY: sim.players[evader].y, symbol: 0)
    let
      goal = ctl.goalFor(sim, order, pursuer)
      (ex, ey) = sim.particleCentre(evader)
      gap = distSq(goal.x, goal.y, ex, ey)
    ## Its goal sits inside the tag radius, not 60 px behind the tail.
    check gap <= sim.config.tagPx * sim.config.tagPx

  test "hold brakes where the order landed, not back at the round's spawn":
    ## `hold` means "brake and stay where you are" (llm.nim's prompt,
    ## docs/RULES.md §Orders). The anchor is stamped as the order is installed,
    ## so a particle half a round from its spawn point holds THERE.
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var ctl = initControlState(sim)
    let spawn = sim.particleCentre(0)
    ## Displace it ~400 px from spawn and stop it there.
    let moved = sim.nearestWalkable(
      clamp(spawn.x + 400, 0, MapWidth - 1), spawn.y)
    sim.players[0].x = moved.x
    sim.players[0].y = moved.y
    sim.players[0].velX = 0
    sim.players[0].velY = 0
    let here = sim.particleCentre(0)
    check distSq(here.x, here.y, spawn.x, spawn.y) > 300 * 300
    let order = CogOrder(
      cogIndex: 0, id: sim.cogAlias(0), intent: intHold,
      targetX: here.x, targetY: here.y, symbol: 0)
    ## Installed exactly as the server installs it (server.nim's turn block).
    sim.anchorHold(0)
    check ctl.goalFor(sim, order, 0) == here
    var inputs = newSeq[InputState](sim.players.len)
    for tick in 0 ..< 2 * 108:              ## two whole turns of holding
      ctl.observeEnemies(sim)
      for seat in 0 ..< inputs.len:
        inputs[seat] = InputState()
      let mask = ctl.compileMask(sim, order, 0)
      check legalMask(mask)
      inputs[0] = decodeInputMask(mask)
      sim.step(inputs, inputs)
    let ended = sim.particleCentre(0)
    ## It stayed where the order landed ...
    check distSq(ended.x, ended.y, here.x, here.y) <=
      (2 * ArriveRadius) * (2 * ArriveRadius)
    ## ... and never trekked back to the spawn ring.
    check distSq(ended.x, ended.y, spawn.x, spawn.y) > 300 * 300

  test "drifter x 4 completes, covers >= 80% in spread, and beats beeline":
    proc play(baseline: Baseline, rounds: seq[Mode]): tuple[
        mean: int, cover: int, bobOnGoal: bool, played: int] =
      var config = variantConfig(rounds)
      var sim = seatedSim(config)
      var ctl = initControlState(sim)
      var orders = newSeq[CogOrder](4)
      var inputs = newSeq[InputState](sim.players.len)
      var have = false
      var played = 0
      var cover = 0
      var bobOnGoal = false
      while played < rounds.len:
        if sim.phase == Playing:
          if sim.gameTicksElapsed() mod config.turnTicks == 0:
            for seat in 0 ..< 4:
              let directive = scriptedDirective(ctl, sim, baseline, @[seat])
              orders[seat] = directive.orders[0]
              sim.installSymbol(seat, orders[seat].symbol,
                sim.gameTicksElapsed() div config.turnTicks)
            have = true
          ctl.observeEnemies(sim)
          if have:
            for seat in 0 ..< 4:
              inputs[seat] = decodeInputMask(
                ctl.compileMask(sim, orders[seat], seat))
        else:
          for seat in 0 ..< inputs.len:
            inputs[seat] = InputState()
        let before = sim.phase
        let modeNow = sim.mode
        let goal = sim.goalLandmark
        let bob = sim.seatWithRole(1)
        sim.step(inputs, inputs)
        if before != GameOver and sim.phase == GameOver:
          if modeNow == modeSpread:
            cover = max(cover, sim.roundLog[^1].coverPct)
          if modeNow == modeCrypto and goal >= 0 and bob >= 0:
            bobOnGoal = bobOnGoal or sim.roundLog[^1].goalHits > 0
          inc played
          if played >= rounds.len:
            break
          sim.roundIndex = played
          sim.reseat(config)
          ctl = initControlState(sim)
          have = false
      var total = 0
      for seat in 0 ..< 4:
        total += sim.episodePermille(seat)
      (total div 4, cover, bobOnGoal, sim.roundLog.len)

    let rounds = @[modeSpread, modeDeceive, modeCrypto, modeTag]
    let drifter = play(blDrifter, rounds)
    let beeline = play(blBeeline, rounds)
    echo "drifter mean=", drifter.mean, " cover=", drifter.cover,
      " bobOnGoal=", drifter.bobOnGoal
    echo "beeline mean=", beeline.mean, " cover=", beeline.cover
    check drifter.played == 4
    check beeline.played == 4
    check drifter.cover >= 80              ## >= 80% coverage in its spread round
    check drifter.bobOnGoal                ## crypto Bob ended on the goal
    check drifter.mean > beeline.mean       ## drifter BEATS beeline
