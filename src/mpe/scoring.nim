## The scoring formulas: one permille per seat per round, and the episode mean.
##
## SIGN: higher is better, every term is non-negative, and every seat's episode
## score lies in [0, 1]. There is no negative reward anywhere in particle
## worlds — `spread`'s collision debit is floored at 0 and every zero-sum term
## is clamped into 0..1000.
##
## Integer only, and `int64` for the accumulators: a 1080-tick sum of permille
## reaches 1 080 000, and Nim's `int` is 32-bit under `--cpu:wasm32`, so an
## `int` accumulator would be inside the range but an `int` PRODUCT on the way
## to a mean would not be. Squared distances are compared as integers wherever
## a comparison is all that is needed.

import
  sim_types, field

proc closeness*(distance, closeScalePx: int): int =
  ## 1000 for a particle sitting on a mark, 0 for one `closeScalePx` away or
  ## further, linear in between. Monotone non-increasing by construction.
  1000 - min(1000, distance * 1000 div max(1, closeScalePx))

proc distanceTo*(sim: SimServer, seat, mark: int): int =
  ## Centre-to-centre distance in map pixels, as an integer square root of the
  ## integer squared distance (no floating point anywhere on the hashed path).
  let
    (px, py) = sim.particleCentre(seat)
    (mx, my) = sim.markCentre(mark)
  var
    d2 = distSq(px, py, mx, my)
    root = 0
    bit = 1 shl 15
  while bit > d2:
    bit = bit shr 2
  while bit != 0:
    if d2 >= root + bit:
      d2 -= root + bit
      root = (root shr 1) + bit
    else:
      root = root shr 1
    bit = bit shr 2
  root

proc distanceBetween*(sim: SimServer, a, b: int): int =
  ## Integer centre-to-centre distance between two particles.
  let
    (ax, ay) = sim.particleCentre(a)
    (bx, by) = sim.particleCentre(b)
  var
    d2 = distSq(ax, ay, bx, by)
    root = 0
    bit = 1 shl 15
  while bit > d2:
    bit = bit shr 2
  while bit != 0:
    if d2 >= root + bit:
      d2 -= root + bit
      root = (root shr 1) + bit
    else:
      root = root shr 1
    bit = bit shr 2
  root

proc coverPermille*(sim: SimServer): int =
  ## `spread`'s per-tick coverage term: for each of the four marks, the
  ## closeness of the NEAREST particle, averaged over the marks. Four particles
  ## each parked on a different mark scores about 950; four clumped on one mark
  ## about 300.
  if sim.landmarks.len == 0:
    return 0
  let seats = min(4, sim.players.len)
  if seats == 0:
    return 0
  var total = 0
  for mark in 0 ..< sim.landmarks.len:
    var best = high(int)
    for seat in 0 ..< seats:
      best = min(best, sim.distanceTo(seat, mark))
    total += closeness(best, sim.config.closeScalePx)
  total div sim.landmarks.len

proc goodCloseness(sim: SimServer, skipRole: int): int =
  ## The closeness of the nearest particle whose role index is NOT `skipRole`,
  ## measured to the round's goal mark.
  var best = high(int)
  for seat in 0 ..< min(4, sim.players.len):
    if sim.roleIndex[seat] == skipRole:
      continue
    best = min(best, sim.distanceTo(seat, sim.goalLandmark))
  if best == high(int): 0 else: closeness(best, sim.config.closeScalePx)

proc roleCloseness(sim: SimServer, roleIndex: int): int =
  ## The closeness of the seat holding one role index to the goal mark.
  let seat = sim.seatWithRole(roleIndex)
  if seat < 0: 0
  else: closeness(sim.distanceTo(seat, sim.goalLandmark), sim.config.closeScalePx)

proc scoreTick*(sim: var SimServer) =
  ## Adds this tick's per-seat term to `roundAccum`, and `spread`'s coverage
  ## term to `coverAccum`. Every branch is the design's own equation.
  let seats = min(4, sim.players.len)
  if seats == 0:
    return
  case sim.mode
  of modeSpread:
    let cover = sim.coverPermille()
    sim.coverAccum += cover
    for seat in 0 ..< seats:
      sim.roundAccum[seat] += cover
  of modeDeceive:
    let
      gc = sim.goodCloseness(0)
      vc = sim.roleCloseness(0)
      goodP = clamp(500 + (gc - vc) div 2, 0, 1000)
      advP = clamp(500 + (vc - gc) div 2, 0, 1000)
    for seat in 0 ..< seats:
      sim.roundAccum[seat] +=
        (if sim.roleIndex[seat] == 0: advP else: goodP)
  of modeCrypto:
    let
      bc = sim.roleCloseness(1)
      e1 = sim.roleCloseness(2)
      e2 = sim.roleCloseness(3)
      ec = max(e1, e2)
      pairP = clamp(500 + (bc - ec) div 2, 0, 1000)
    for seat in 0 ..< seats:
      case sim.roleIndex[seat]
      of 0, 1:
        sim.roundAccum[seat] += pairP
      of 2:
        sim.roundAccum[seat] += clamp(500 + (e1 - bc) div 2, 0, 1000)
      else:
        sim.roundAccum[seat] += clamp(500 + (e2 - bc) div 2, 0, 1000)
  of modeTag:
    discard   ## `tag` scores from the contact counters at round end.

proc tagRoundPermille*(sim: SimServer, seat, ticks: int): int =
  ## `tag`'s round score. A pursuer is paid for the ticks IT was in contact,
  ## needing `tagTargetTicks` for a full score; the evader is paid for every
  ## tick no pursuer was within `tagPx`.
  if sim.roleIndex[seat] == 0:
    if ticks <= 0: 1000
    else: clamp((ticks - sim.tagTicks) * 1000 div ticks, 0, 1000)
  else:
    min(1000, sim.tagCredit[seat] * 1000 div max(1, sim.config.tagTargetTicks))

proc roundPermille*(sim: SimServer, seat, ticks: int): int =
  ## The banked round score for one seat, given how many ticks the round ran.
  ## Never negative, never above 1000.
  if ticks <= 0:
    return 0
  case sim.mode
  of modeTag:
    sim.tagRoundPermille(seat, ticks)
  of modeSpread:
    let
      base = int(sim.roundAccum[seat] div ticks)
      debit = min(
        sim.config.bumpPenaltyCap,
        sim.bumps[seat] * sim.config.bumpPenaltyPermille)
    clamp(max(0, base - debit), 0, 1000)
  else:
    clamp(int(sim.roundAccum[seat] div ticks), 0, 1000)

proc coverPctForRound*(sim: SimServer, ticks: int): int =
  ## The round's mean coverage percent; 0 outside `spread`.
  if sim.mode != modeSpread or ticks <= 0:
    0
  else:
    clamp(int(sim.coverAccum div ticks) div 10, 0, 100)

proc goalHitsForRound*(sim: SimServer): int =
  ## How many MOBILE agents are within `landmarkRadius + OnPointSlackPx` of the
  ## round's goal right now; 0 in `spread` and `tag`, which have no goal.
  if sim.goalLandmark < 0:
    return 0
  let reach = sim.config.landmarkRadius + OnPointSlackPx
  for seat in 0 ..< min(4, sim.players.len):
    if sim.isAnchored(seat):
      continue
    if sim.distanceTo(seat, sim.goalLandmark) <= reach:
      inc result

proc bankRound*(sim: var SimServer, ticks: int, endRule: string) =
  ## Banks the round in progress into `roundLog` and counts it toward the
  ## episode mean. A round the wall clock never REACHED is excluded from the
  ## mean (it is simply never banked); a round that was measured and cut short
  ## banks from the ticks it actually ran.
  var entry = RoundLogEntry(
    mode: sim.mode,
    ticks: ticks,
    endRule: endRule,
    goal: sim.goalLandmark,
    coverPct: sim.coverPctForRound(ticks),
    tagTicks: (if sim.mode == modeTag: sim.tagTicks else: 0),
    goalHits: sim.goalHitsForRound()
  )
  for seat in 0 ..< 4:
    entry.roles[seat] = sim.roleIndex[seat]
    entry.permille[seat] =
      if seat < sim.players.len: sim.roundPermille(seat, ticks) else: 0
  sim.roundLog.add(entry)
  inc sim.roundsPlayed

proc episodePermille*(sim: SimServer, seat: int): int =
  ## The mean of the seat's banked round scores, in permille. Rounds never
  ## started are excluded from the mean rather than scored 0: a truncated
  ## episode reports what was actually measured instead of punishing four
  ## policies for a slow sidecar.
  if sim.roundLog.len == 0 or seat < 0 or seat >= 4:
    return 0
  var total = 0
  for entry in sim.roundLog:
    total += entry.permille[seat]
  clamp(total div sim.roundLog.len, 0, 1000)
