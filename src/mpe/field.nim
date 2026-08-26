## The round setup: the seeded landmark draw, the mark-colour permutation, the
## mode/role schedule, the crypto key, and the spawn ring.
##
## Everything here is INTEGER-ONLY and drawn from the sim's own RNG in a fixed
## order, because the wasm viewer re-derives every one of these values rather
## than reading them out of the replay: the `roundcard` record is a convenience
## for `tools/replay_summary.py` and the feed, not a load-bearing input. A
## floating-point draw or a reordered draw would diverge the hash chain at the
## first tick of the round.
##
## Roles ROTATE so nobody is stuck with the cheap seat. One seeded permutation
## `perm[0..3]` is drawn per EPISODE; in round `r` (0-based here, 1-based in the
## note) seat `s` holds role index `(perm[s] + r) mod 4`, so over four rounds
## each seat holds each role index exactly once.

import
  std/random,
  sim_types, sim_state

proc modeFor*(config: GameConfig, roundIndex: int): Mode =
  ## The mode round `roundIndex` is played under. A `rounds` array shorter
  ## than `maxGames` repeats its last entry rather than failing: the array is
  ## bounded 1..4 by `validate`, and a short one is an authored abbreviation.
  if config.rounds.len == 0:
    return modeSpread
  config.rounds[min(max(0, roundIndex), config.rounds.high)]

proc roleName*(mode: Mode, roleIndex: int): string =
  ## The PUBLIC role name for one role index in one mode. Roles are public in
  ## every mode — the viewer shows them, and a hidden role would make the feed
  ## unreadable. What is secret is the round's GOAL and its KEY, never who
  ## holds which seat.
  let k = max(0, min(3, roleIndex))
  case mode
  of modeSpread: "cooperator"
  of modeDeceive: (if k == 0: "adversary" else: "good")
  of modeCrypto:
    case k
    of 0: "speaker"
    of 1: "listener"
    else: "eavesdropper"
  of modeTag: (if k == 0: "evader" else: "pursuer")

proc symbolText*(index: int): string =
  ## The wire text of one symbol index: 0 is silence, 1..8 are A..H.
  if index <= 0 or index > SymbolAlphabet.len:
    SymbolSilence
  else:
    $SymbolAlphabet[index - 1]

proc symbolIndex*(text: string): int =
  ## The symbol index of one wire text, 0 (silence) for anything else.
  if text.len != 1:
    return 0
  let ch = text[0]
  for i in 0 ..< SymbolAlphabet.len:
    if SymbolAlphabet[i] == ch:
      return i + 1
  0

proc isAnchored*(sim: SimServer, seat: int): bool =
  ## True when this seat's particle cannot move at all this round: `crypto`'s
  ## Alice, as MPE's `simple_crypto` speakers are immovable. Her AIM still
  ## turns, so her sprite reads as looking at whoever she is talking to.
  seat >= 0 and seat < 4 and sim.mode == modeCrypto and sim.roleIndex[seat] == 0

proc isPursuer*(sim: SimServer, seat: int): bool =
  ## True for a `tag` pursuer — the only role with different kinematics.
  seat >= 0 and seat < 4 and sim.mode == modeTag and sim.roleIndex[seat] != 0

proc particleAccel*(sim: SimServer, seat: int): int =
  ## Per-tick impulse for one particle. MPE `simple_tag`'s own ratio: the
  ## adversary pack accelerates at 75 % of the lone evader's.
  if sim.isPursuer(seat):
    sim.config.accel * sim.config.pursuerAccelPct div 100
  else:
    sim.config.accel

proc particleMaxSpeed*(sim: SimServer, seat: int): int =
  ## Per-axis speed clamp for one particle (MPE's 1.0 vs 1.3 max_speed).
  if sim.isPursuer(seat):
    sim.config.maxSpeed * sim.config.pursuerSpeedPct div 100
  else:
    sim.config.maxSpeed

proc drawPermutation(rng: var Rand): array[4, int] =
  ## A uniform permutation of 0..3 by Fisher-Yates over integer draws.
  for i in 0 ..< 4:
    result[i] = i
  for i in countdown(3, 1):
    let j = rng.rand(i)
    swap(result[i], result[j])

proc episodePerm*(seed: int): array[4, int] =
  ## The episode's role permutation. Drawn from a SEPARATE stream seeded off
  ## the config seed rather than off the live sim RNG, so it is a pure function
  ## of the config a replay already carries and cannot shift if a later round
  ## draws a different number of samples.
  var rng = initRand(seed * 2 + 1)
  drawPermutation(rng)

proc planEpisode*(sim: var SimServer) =
  ## Installs the episode-level plan: the role permutation. Called once, from
  ## initSimServer, before any round is drawn.
  sim.perm = episodePerm(sim.config.seed)
  sim.roundLog = @[]
  sim.roundsPlayed = 0
  sim.roundIndex = 0

proc centreOfField*(): tuple[x, y: int] {.inline.} =
  (MapWidth div 2, MapHeight div 2)

proc drawLandmarks(sim: var SimServer) =
  ## Bounded rejection sampling, exactly the design's loop: four marks at least
  ## `landmarkSpacingPx` apart on non-wall floor, with the spacing relaxed by
  ## 20 px every 400 attempts and floored at MinLandmarkSpacingPx — so it
  ## ALWAYS terminates, on every seed, which `tests/test_field.nim` proves over
  ## 10 000 of them.
  let
    margin = max(1, sim.config.landmarkMargin)
    spanX = max(1, MapWidth - 1 - 2 * margin)
    spanY = max(1, MapHeight - 1 - 2 * margin)
  sim.landmarks = @[]
  var colours = drawPermutation(sim.rng)
  for i in 0 ..< LandmarkCount:
    var
      spacing = max(MinLandmarkSpacingPx, sim.config.landmarkSpacingPx)
      attempts = 0
      x = 0
      y = 0
    while true:
      x = margin + sim.rng.rand(spanX)
      y = margin + sim.rng.rand(spanY)
      inc attempts
      var ok = sim.isWalkable(x, y)
      if ok:
        for placed in sim.landmarks:
          if distSq(placed.x, placed.y, x, y) < spacing * spacing:
            ok = false
            break
      if ok:
        break
      if attempts mod 400 == 0:
        spacing = max(MinLandmarkSpacingPx, spacing - 20)
    sim.landmarks.add(Landmark(x: x, y: y, colour: colours[i]))

proc drawKey(sim: var SimServer) =
  ## The round's crypto key: `keySymbols[c]` is THE symbol that means mark
  ## colour `c`. An ordered sample WITHOUT replacement from A..H, so a symbol
  ## an eavesdropper hears has four a-priori-equal meanings and the key is
  ## redrawn every round.
  var pool: seq[int]
  for i in 1 .. max(LandmarkCount, min(sim.config.symbolCount, SymbolAlphabet.len)):
    pool.add(i)
  for c in 0 ..< LandmarkCount:
    let pick = sim.rng.rand(pool.high)
    sim.keySymbols[c] = pool[pick]
    pool.delete(pick)

proc placeParticles*(sim: var SimServer) =
  ## Spawn placement: role index `k` spawns on the circle of radius
  ## `spawnRingPx` about the field centre at `(64 * k + spawnOffsetBrads) mod
  ## 256`, snapped to the nearest walkable pixel. Velocity, carry and the
  ## sub-pixel accumulators all start at zero.
  let
    (cx, cy) = centreOfField()
    radius = max(1, sim.config.spawnRingPx)
  for seat in 0 ..< sim.players.len:
    if seat >= 4:
      break
    let
      k = sim.roleIndex[seat]
      brads = (64 * k + sim.spawnOffsetBrads) and 255
      wanted = (
        x: cx + AimUnitX[brads] * radius div AimUnitScale,
        y: cy + AimUnitY[brads] * radius div AimUnitScale)
      spot = sim.nearestWalkable(
        clamp(wanted.x, 0, MapWidth - 1), clamp(wanted.y, 0, MapHeight - 1))
    sim.players[seat].x = spot.x
    sim.players[seat].y = spot.y
    sim.players[seat].homeX = spot.x
    sim.players[seat].homeY = spot.y
    sim.players[seat].velX = 0
    sim.players[seat].velY = 0
    sim.players[seat].carryX = 0
    sim.players[seat].carryY = 0
    sim.players[seat].aimBrads = (brads + 128) and 255   ## face the middle
    sim.holdX[seat] = spot.x
    sim.holdY[seat] = spot.y

proc beginRound*(sim: var SimServer, roundIndex: int) =
  ## Draws one round: its mode, its roles, its marks and their colours, its
  ## goal, its key and its spawn rotation, in THIS order. The order is wire
  ## format — the viewer re-derives every value by replaying the same draws.
  sim.roundIndex = roundIndex
  sim.mode = sim.config.modeFor(roundIndex)
  for seat in 0 ..< 4:
    sim.roleIndex[seat] = (sim.perm[seat] + roundIndex) mod 4
  sim.drawLandmarks()
  sim.goalLandmark =
    if sim.mode in {modeDeceive, modeCrypto}: sim.rng.rand(LandmarkCount - 1)
    else: -1
  if sim.mode == modeCrypto:
    sim.drawKey()
  else:
    for c in 0 ..< LandmarkCount:
      sim.keySymbols[c] = 0
  sim.spawnOffsetBrads = sim.rng.rand(63)
  for seat in 0 ..< 4:
    sim.roundAccum[seat] = 0
    sim.bumps[seat] = 0
    sim.tagCredit[seat] = 0
    sim.tagContact[seat] = false
    sim.lastTagTick[seat] = NeverTick
    sim.nearestMark[seat] = -1
    sim.settledTicks[seat] = 0
    sim.decodedMark[seat] = -1
    sim.onPointDone[seat] = false
    sim.commSymbol[seat] = 0
    sim.commPrev[seat] = 0
    sim.commTurn[seat] = -1
  for i in 0 ..< sim.lastBumpTick.len:
    sim.lastBumpTick[i] = NeverTick
  sim.coverAccum = 0
  sim.tagTicks = 0
  sim.placeParticles()

proc goalColour*(sim: SimServer): int =
  ## The colour index of the round's goal mark, -1 outside deceive/crypto.
  if sim.goalLandmark < 0 or sim.goalLandmark >= sim.landmarks.len:
    -1
  else:
    sim.landmarks[sim.goalLandmark].colour

proc markCentre*(sim: SimServer, index: int): tuple[x, y: int] =
  ## One mark's centre, clamped to a real index so no caller can read past the
  ## seq during a pre-round frame.
  if index < 0 or index >= sim.landmarks.len:
    centreOfField()
  else:
    (sim.landmarks[index].x, sim.landmarks[index].y)

proc particleCentre*(sim: SimServer, seat: int): tuple[x, y: int] =
  ## One particle's centre in map pixels.
  if seat < 0 or seat >= sim.players.len:
    centreOfField()
  else:
    (sim.players[seat].x + CollisionW div 2,
     sim.players[seat].y + CollisionH div 2)

proc nearestMarkTo*(sim: SimServer, x, y: int): int =
  ## The index of the mark whose centre is nearest a point; -1 before any
  ## round has been drawn. Ties break to the LOWEST index, so the answer is a
  ## pure function of state.
  result = -1
  var best = high(int)
  for i in 0 ..< sim.landmarks.len:
    let d = distSq(x, y, sim.landmarks[i].x, sim.landmarks[i].y)
    if d < best:
      best = d
      result = i

proc seatWithRole*(sim: SimServer, roleIndex: int): int =
  ## The seat holding one role index this round, -1 if none does (a partially
  ## seated board before squad construction).
  for seat in 0 ..< min(4, sim.players.len):
    if sim.roleIndex[seat] == roleIndex:
      return seat
  -1
