## The perf budget. RELEASE ONLY (the repo variable `NIM_TESTS_RELEASE_ONLY`
## lists this file): a debug build's range and overflow checks make the number
## meaningless, and the point of this test is the number.
##
## Target: 4 x 1080 ticks of sim plus mask compilation and the flow fields in
## well under 10 s on a CI runner. The bound is 120 s, generously above the
## target, because a shared runner under load is not a benchmark rig -- what
## this catches is an order-of-magnitude regression (an uncached flow field, a
## per-tick sprite bake, an accidental O(n^2) over the mark set), not a 20 %
## drift.

import std/[monotimes, times, unittest]
import bitworld/spriteprotocol
import ../src/mpe/[sim, control, directives, baselines]
import fixture

suite "perf":

  test "a full 4 x 1080-tick episode finishes inside 120 s":
    let config = variantConfig(@[modeSpread, modeDeceive, modeCrypto, modeTag])
    let began = getMonoTime()
    var sim = seatedSim(config)
    var
      ctl = initControlState(sim)
      orders = newSeq[CogOrder](4)
      inputs = newSeq[InputState](sim.players.len)
      have = false
      played = 0
      ticks = 0
      compiled = 0
    while played < 4:
      if sim.phase == Lobby and sim.players.len < FixtureSeats:
        for seat in 0 ..< FixtureSeats:
          discard sim.addPlayer(
            config.slots[seat].name, seat, config.slots[seat].token)
        inputs = newSeq[InputState](sim.players.len)
        ctl = initControlState(sim)
        have = false
      if sim.phase == Playing:
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          for seat in 0 ..< 4:
            let directive = scriptedDirective(ctl, sim, blDrifter, @[seat])
            orders[seat] = directive.orders[0]
            sim.installSymbol(seat, orders[seat].symbol,
              sim.gameTicksElapsed() div config.turnTicks)
          have = true
        ctl.observeEnemies(sim)
        if have:
          for seat in 0 ..< 4:
            inputs[seat] = decodeInputMask(
              ctl.compileMask(sim, orders[seat], seat))
            inc compiled
      else:
        for seat in 0 ..< inputs.len:
          inputs[seat] = InputState()
      let before = sim.phase
      sim.step(inputs, inputs)
      ## The hash chain is part of the per-tick cost the viewer pays too.
      discard sim.gameHash()
      inc ticks
      if before != GameOver and sim.phase == GameOver:
        inc played
    let seconds = float((getMonoTime() - began).inMilliseconds) / 1000.0
    echo "4 x " & $config.maxTicks & " ticks: " & $ticks & " steps, " &
      $compiled & " masks, " & $sim.roundLog.len & " rounds banked in " &
      $seconds & " s"
    check played == 4
    check sim.roundLog.len == 4
    check ticks >= 4 * config.maxTicks
    check compiled >= 4 * 4 * config.maxTicks - 4 * config.turnTicks
    check seconds < 120.0
