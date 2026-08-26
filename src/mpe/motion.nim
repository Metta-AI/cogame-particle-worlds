## The particle motion model: damp BOTH axes every tick, then add the impulse.
##
## MPE integrates `p_vel = p_vel * (1 - damping) + action * accel * dt` and
## clamps to `max_speed`. The starter integrates the same thing in integers but
## applies friction only to an UNPOWERED axis, which makes a particle that is
## being driven behave like a sled rather than like a body in a viscous fluid.
## Particle worlds wants particles that GLIDE, so the damping runs on both axes
## unconditionally and the impulse is added afterwards.
##
## Everything here is integer-only. `frictionNum / frictionDen` = 192/256 =
## 0.75 retention per tick, i.e. MPE's `damping = 0.25`, exactly.

import
  sim_types

proc dampAxis*(velocity, frictionNum, frictionDen, stopThreshold: int): int =
  ## One axis of viscous damping, then the starter's dead-zone snap so a
  ## particle actually comes to rest instead of creeping by one motion unit
  ## forever. Integer division truncates toward zero, which is symmetric for
  ## +/- velocities, so a particle drifting west decays exactly like one
  ## drifting east.
  result = velocity * frictionNum div max(1, frictionDen)
  if abs(result) < stopThreshold:
    result = 0

proc driveAxis*(velocity, input, accel, maxSpeed: int): int =
  ## One axis of impulse, clamped to the per-axis speed ceiling. `input` is the
  ## d-pad sign for the axis, in {-1, 0, 1}.
  clamp(velocity + input * accel, -maxSpeed, maxSpeed)

proc dampAndDriveVelocity*(
  sim: var SimServer,
  seat: int,
  inputX, inputY, accel, maxSpeed: int
) =
  ## Steps ONE particle's velocity: damp, then impulse, then clamp. Position
  ## integration is `applyMomentumAxis` in sim.nim (unchanged, inherited), so
  ## this proc owns exactly the part of the model that differs from the
  ## starter's.
  if seat < 0 or seat >= sim.players.len:
    return
  template p: untyped = sim.players[seat]
  p.velX = dampAxis(
    p.velX, sim.config.frictionNum, sim.config.frictionDen,
    sim.config.stopThreshold)
  p.velY = dampAxis(
    p.velY, sim.config.frictionNum, sim.config.frictionDen,
    sim.config.stopThreshold)
  p.velX = driveAxis(p.velX, inputX, accel, maxSpeed)
  p.velY = driveAxis(p.velY, inputY, accel, maxSpeed)

proc turnAim*(sim: var SimServer, seat: int, ccw, cw: bool) =
  ## Aim rotation, decoupled from locomotion exactly as the starter has it:
  ## holding B turns counter-clockwise, Select clockwise, both cancel. Applies
  ## even to an ANCHORED particle — `crypto`'s Alice cannot move, but her
  ## sprite still reads as looking at whoever she is talking to.
  if seat < 0 or seat >= sim.players.len:
    return
  template p: untyped = sim.players[seat]
  if ccw != cw:
    let turn = if ccw: sim.config.aimTurnRate else: -sim.config.aimTurnRate
    p.aimBrads =
      ((p.aimBrads + turn) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  p.flipH =
    p.aimBrads > AimBradsTurn div 4 and p.aimBrads < AimBradsTurn * 3 div 4

proc bumpPairIndex*(a, b: int): int =
  ## The flat index of one unordered pair of the four seats, 0..15. Small and
  ## fixed so the per-pair event throttle is a plain array read.
  let
    lo = min(a, b)
    hi = max(a, b)
  lo * 4 + hi

proc particleCentreOf*(sim: SimServer, seat: int): tuple[x, y: int] {.inline.} =
  (sim.players[seat].x + CollisionW div 2,
   sim.players[seat].y + CollisionH div 2)

proc resolveBumps*(sim: var SimServer): seq[tuple[a, b: int]] =
  ## For each unordered pair whose centres are within `bumpPx`, credit a bump
  ## tick to BOTH seats and report the pair when its event throttle has
  ## expired. The elastic shove itself already happened inside
  ## `applyMomentumAxis` / `bouncePlayers`; this is only the counter and the
  ## feed signal.
  let
    reach = max(0, sim.config.bumpPx)
    reachSq = reach * reach
    seats = min(4, sim.players.len)
  for a in 0 ..< seats:
    let (ax, ay) = sim.particleCentreOf(a)
    for b in a + 1 ..< seats:
      let (bx, by) = sim.particleCentreOf(b)
      if distSq(ax, ay, bx, by) > reachSq:
        continue
      inc sim.bumps[a]
      inc sim.bumps[b]
      let pair = bumpPairIndex(a, b)
      if sim.tickCount - sim.lastBumpTick[pair] >= BumpEventThrottleTicks:
        sim.lastBumpTick[pair] = sim.tickCount
        result.add((a, b))

proc bumpPairsThisTick*(sim: SimServer): seq[tuple[a, b: int]] =
  ## The unordered pairs touching RIGHT NOW, as a read-only query for the
  ## broadcast delta. Throttled by the same per-pair window the sim's own event
  ## uses, so the feed and the tier-2 stream agree without the broadcast layer
  ## being allowed to mutate sim state.
  let
    reach = max(0, sim.config.bumpPx)
    reachSq = reach * reach
    seats = min(4, sim.players.len)
  for a in 0 ..< seats:
    let (ax, ay) = sim.particleCentreOf(a)
    for b in a + 1 ..< seats:
      let (bx, by) = sim.particleCentreOf(b)
      if distSq(ax, ay, bx, by) > reachSq:
        continue
      if sim.lastBumpTick[bumpPairIndex(a, b)] == sim.tickCount:
        result.add((a, b))

proc resolveTags*(sim: var SimServer): seq[int] =
  ## `tag` rounds only: recompute each pursuer's contact with the evader,
  ## credit the contact ticks, and report every pursuer whose contact follows
  ## at least `TagEventThrottleTicks` quiet ticks (the `tag` event).
  if sim.mode != modeTag:
    return
  let seats = min(4, sim.players.len)
  var evader = -1
  for seat in 0 ..< seats:
    if sim.roleIndex[seat] == 0:
      evader = seat
      break
  if evader < 0:
    return
  let
    (ex, ey) = sim.particleCentreOf(evader)
    reach = max(0, sim.config.tagPx)
    reachSq = reach * reach
  var any = false
  for seat in 0 ..< seats:
    if seat == evader:
      sim.tagContact[seat] = false
      continue
    let (px, py) = sim.particleCentreOf(seat)
    let touching = distSq(px, py, ex, ey) <= reachSq
    if touching:
      any = true
      inc sim.tagCredit[seat]
      if sim.tickCount - sim.lastTagTick[seat] >= TagEventThrottleTicks:
        result.add(seat)
      sim.lastTagTick[seat] = sim.tickCount
    sim.tagContact[seat] = touching
  if any:
    inc sim.tagTicks
