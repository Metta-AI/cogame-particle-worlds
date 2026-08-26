## The physics. MPE integrates `p_vel = p_vel * (1 - damping) + action * accel *
## dt` and clamps to `max_speed`; particle worlds does the same in integers,
## damping BOTH axes every tick before adding the impulse. These tests pin the
## exact arithmetic, the wall behaviour, the particle-on-particle bounce, the
## anchored speaker and the float-free rule.

import std/[strutils, unittest]
import bitworld/spriteprotocol
import ../src/mpe/sim
import fixture

suite "particle motion":

  test "an unpowered particle decays by exactly 192/256 per tick":
    var velocity = DefaultParticleMaxSpeed
    var ticks = 0
    while velocity != 0:
      let expected = velocity * DefaultParticleFrictionNum div FrictionDen
      let stepped = dampAxis(velocity, DefaultParticleFrictionNum, FrictionDen,
                             StopThreshold)
      check stepped == (if abs(expected) < StopThreshold: 0 else: expected)
      velocity = stepped
      inc ticks
      check ticks <= 40
    check ticks <= 40           ## reaches rest inside 40 ticks from maxSpeed

  test "a driven axis converges to cruise 1000 and never exceeds maxSpeed":
    var velocity = 0
    for tick in 0 ..< 400:
      velocity = dampAxis(velocity, DefaultParticleFrictionNum, FrictionDen,
                          StopThreshold)
      velocity = driveAxis(velocity, 1, DefaultParticleAccel,
                           DefaultParticleMaxSpeed)
      check velocity <= DefaultParticleMaxSpeed
    ## The design's closed form is accel / (1 - 0.75) = 1000 units. Integer
    ## division truncates toward zero on every damp step, so the real fixed
    ## point is 1000 - 4 * frac for the fractional part frac in [0, 1) -- i.e.
    ## (996, 1000]. Pinning the arithmetic, not the algebra.
    check velocity > 996
    check velocity <= 1000

  test "a pursuer's cruise is 748":
    let
      accel = DefaultParticleAccel * DefaultPursuerAccelPct div 100
      maxSpeed = DefaultParticleMaxSpeed * DefaultPursuerSpeedPct div 100
    var velocity = 0
    for tick in 0 ..< 400:
      velocity = dampAxis(velocity, DefaultParticleFrictionNum, FrictionDen,
                          StopThreshold)
      velocity = driveAxis(velocity, 1, accel, maxSpeed)
      check velocity <= maxSpeed
    ## 187 / (1 - 0.75) = 748, with the same truncation bound: (744, 748].
    check velocity > 744
    check velocity <= 748

  test "a particle driven into a wall is absorbed on that axis, not the other":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    # Park seat 0 hard against the left border wall and drive west + south.
    sim.players[0].x = ArenaBorder + PlayerHalf + 1
    sim.players[0].y = MapHeight div 2
    sim.players[0].velX = 0
    sim.players[0].velY = 0
    var inputs = newSeq[InputState](sim.players.len)
    inputs[0] = decodeInputMask(ButtonLeft or ButtonDown)
    for tick in 0 ..< 90:
      sim.step(inputs, inputs)
    ## The inherited `applyMomentumAxis` absorbs the blocked motion into the
    ## carry rather than into the velocity: the particle presses against the
    ## wall, its sub-pixel accumulator is cleared every tick, and it never
    ## advances or tunnels. The OTHER axis is untouched.
    check sim.players[0].carryX == 0
    check sim.players[0].x >= ArenaBorder
    check sim.players[0].x <= ArenaBorder + PlayerHalf + 1
    check sim.players[0].velY > 0
    check sim.players[0].y > MapHeight div 2

  test "two particles driven together separate and neither leaves the field":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    let (cx, cy) = centreOfField()
    sim.players[0].x = cx - 40
    sim.players[0].y = cy
    sim.players[1].x = cx + 40
    sim.players[1].y = cy
    var inputs = newSeq[InputState](sim.players.len)
    inputs[0] = decodeInputMask(ButtonRight)
    inputs[1] = decodeInputMask(ButtonLeft)
    var closest = high(int)
    for tick in 0 ..< 200:
      sim.step(inputs, inputs)
      closest = min(closest, abs(sim.players[0].x - sim.players[1].x))
      for seat in 0 ..< 4:
        check sim.players[seat].x >= 0
        check sim.players[seat].x < MapWidth
        check sim.players[seat].y >= 0
        check sim.players[seat].y < MapHeight
    check closest <= 2 * PlayerHalf + 2     ## they really met
    check sim.config.playerBouncePct == PlayerBouncePct

  test "a crypto speaker with every d-pad bit set does not move":
    var config = fixtureConfig(@[modeCrypto])
    var sim = seatedSim(config)
    let speaker = sim.seatWithRole(0)
    check speaker >= 0
    check sim.isAnchored(speaker)
    let
      x0 = sim.players[speaker].x
      y0 = sim.players[speaker].y
    var inputs = newSeq[InputState](sim.players.len)
    for seat in 0 ..< sim.players.len:
      inputs[seat] = decodeInputMask(
        ButtonLeft or ButtonRight or ButtonUp or ButtonDown or ButtonB)
    for tick in 0 ..< 240:
      sim.step(inputs, inputs)
      check sim.players[speaker].x == x0
      check sim.players[speaker].y == y0
    ## Her AIM still turns, so her sprite reads as looking at whoever she is
    ## talking to.
    check sim.players[speaker].aimBrads != 0 or sim.config.aimTurnRate == 0

  test "the hashed path is float-free":
    ## Nim's `int` is 32-bit under --cpu:wasm32 and the wasm viewer re-derives
    ## every tick, so a compile-time cos/sin evaluated by whichever libm the
    ## build container ships could differ by an ulp between the amd64 game image
    ## and the emscripten viewer image. These modules are integer-only.
    const banned = ["sin(", "cos(", "tan(", "arctan", "sqrt(", "hypot(",
                    "float"]
    proc callsBanned(code, needle: string): bool =
      ## A whole-identifier match. `isqrt(` -- the integer square root this
      ## module ships precisely so the hashed path never calls libm -- contains
      ## the substring `sqrt(`, and a naive scan would flag the fix as the bug.
      var start = 0
      while true:
        let at = code.find(needle, start)
        if at < 0:
          return false
        let before = (if at == 0: ' ' else: code[at - 1])
        if not (before.isAlphaNumeric() or before == '_'):
          return true
        start = at + 1
    for module in ["field", "motion", "scoring", "beliefs"]:
      let source = sourceOf("src/mpe/" & module & ".nim")
      for line in source.splitLines():
        let code = line.split("##")[0].split("#")[0]
        for needle in banned:
          if code.callsBanned(needle):
            echo module, ".nim: ", line
          check not code.callsBanned(needle)

  test "the same seed reproduces a byte-identical position stream":
    proc trace(seed: int): string =
      var config = fixtureConfig()
      config.seed = seed
      var sim = seatedSim(config)
      var inputs = newSeq[InputState](sim.players.len)
      for seat in 0 ..< sim.players.len:
        inputs[seat] = decodeInputMask(
          if seat mod 2 == 0: ButtonRight or ButtonDown
          else: ButtonLeft or ButtonUp)
      for tick in 0 ..< 240:
        sim.step(inputs, inputs)
        for seat in 0 ..< sim.players.len:
          result.add($sim.players[seat].x & "," & $sim.players[seat].y & ";")
    let a = trace(FixtureSeed)
    check a == trace(FixtureSeed)
    check a != trace(FixtureSeed + 1)
