## The two published scripted baselines.
##
## Both emit the SAME directive object an LLM does, on the same 4.5 s cadence,
## so their output is legal by construction and directly comparable. Both are
## pure functions of the world state PLUS the seat's own entitlements — a
## `drifter` Bob does not read the goal it was never told — which is what makes
## the bounded-orders test in tests/test_control.nim meaningful.
##
## `drifter` is load-bearing in four places: it is the certification player,
## the per-turn fallback when a seat's LLM call fails twice, the driver of a
## no-show or disconnected seat, and the default for a seat that registers with
## neither PLAYER_PROMPT nor PLAYER_SCRIPTED. Both are documented in
## docs/RULES.md precisely so "playing beside a partner you did not write" here
## means "a partner whose published rules you know".

import
  std/strutils,
  sim, control, directives

type
  Baseline* = enum
    blDrifter = "drifter"
    blBeeline = "beeline"

proc parseBaseline*(text: string): Baseline =
  ## PLAYER_SCRIPTED values. Anything unrecognised is `drifter`: a seat that
  ## says nothing useful still plays the published default rather than sitting
  ## out.
  case text.strip().toLowerAscii()
  of "beeline", "bee": blBeeline
  else: blDrifter

proc markOfColour(sim: SimServer, colour: int): int =
  ## The index of the mark carrying one palette colour, -1 if none does.
  result = -1
  for i in 0 ..< sim.landmarks.len:
    if sim.landmarks[i].colour == colour:
      return i

proc furthestMarkFrom(sim: SimServer, mark: int, skip: int): int =
  ## The mark furthest from `mark`, excluding `mark` itself and `skip`.
  result = -1
  var best = -1
  let (mx, my) = sim.markCentre(mark)
  for i in 0 ..< sim.landmarks.len:
    if i == mark or i == skip:
      continue
    let d = distSq(mx, my, sim.landmarks[i].x, sim.landmarks[i].y)
    if d > best:
      best = d
      result = i

proc goodCentroid(sim: SimServer): tuple[x, y: int] =
  ## The centroid of the three good agents, which is the adversary's naive
  ## inference in `deceive`.
  var
    sx = 0
    sy = 0
    n = 0
  for seat in 0 ..< min(4, sim.players.len):
    if sim.roleIndex[seat] == 0:
      continue
    let (px, py) = sim.particleCentre(seat)
    sx += px
    sy += py
    inc n
  if n == 0: centreOfField() else: (sx div n, sy div n)

proc nearestMarkToSeat(sim: SimServer, seat: int): int =
  let (px, py) = sim.particleCentre(seat)
  sim.nearestMarkTo(px, py)

proc heardKeyColour(sim: SimServer, seat: int): int =
  ## `crypto` Bob's decoder: the mark COLOUR named by any symbol heard this
  ## round — this turn's or a previous turn's — under the key Bob shares with
  ## Alice. -1 when nothing heard maps to a colour.
  result = -1
  for other in 0 ..< min(4, sim.players.len):
    if other == seat:
      continue
    for symbol in [sim.commSymbol[other], sim.commPrev[other]]:
      if symbol <= 0:
        continue
      for colour in 0 ..< LandmarkCount:
        if sim.keySymbols[colour] == symbol:
          return colour

proc noteFor(mode: Mode): string =
  ## One fixed spectator note per mode, so the feed still says what the bot is
  ## trying to do even though a scripted seat has nothing to explain.
  case mode
  of modeSpread: "cover four marks"
  of modeDeceive: "one on, two baiting"
  of modeCrypto: "say the key"
  of modeTag: "run"

proc baseOrder(sim: SimServer, seat: int, id: string): CogOrder =
  let (px, py) = sim.particleCentre(seat)
  CogOrder(
    cogIndex: seat,
    id: id,
    intent: intHold,
    targetX: px,
    targetY: py,
    symbol: 0,
    fromReply: true
  )

proc drifterOrder(sim: SimServer, seat: int, id: string): CogOrder =
  ## `drifter` — mode-aware and role-aware, and never told anything the seat is
  ## not entitled to.
  result = baseOrder(sim, seat, id)
  let role = sim.roleIndex[min(seat, 3)]
  case sim.mode
  of modeSpread:
    ## Cover the mark whose INDEX equals this seat's role index. Four `drifter`
    ## seats therefore cover four distinct marks — the correct cooperative
    ## solution, and a real bar for a champion to clear.
    let (mx, my) = sim.markCentre(role)
    result.intent = intCover
    result.targetX = mx
    result.targetY = my
    result.symbol = min(role + 1, SymbolAlphabet.len)
  of modeDeceive:
    if role == 0:
      ## The adversary: cover the mark nearest the centroid of the three good
      ## agents — the naive inference — re-evaluated every turn.
      let
        centroid = goodCentroid(sim)
        mark = sim.nearestMarkTo(centroid.x, centroid.y)
        (mx, my) = sim.markCentre(mark)
      result.intent = intCover
      result.targetX = mx
      result.targetY = my
      result.symbol = 0
    else:
      let goal = sim.goalLandmark
      var mark = goal
      if role == 2:
        mark = furthestMarkFrom(sim, goal, -1)
      elif role == 3:
        let first = furthestMarkFrom(sim, goal, -1)
        mark = furthestMarkFrom(sim, goal, first)
      if mark < 0:
        mark = goal
      let (mx, my) = sim.markCentre(mark)
      result.intent = intCover
      result.targetX = mx
      result.targetY = my
      result.symbol = 0
  of modeCrypto:
    case role
    of 0:
      ## Alice: hold (she cannot move anyway) and speak the key HONESTLY,
      ## every turn, without variation.
      result.intent = intHold
      result.symbol =
        (if sim.goalColour() >= 0: sim.keySymbols[sim.goalColour()] else: 0)
    of 1:
      ## Bob: decode anything heard this round against the shared key and cover
      ## that colour's mark; otherwise hold and stay quiet.
      let colour = heardKeyColour(sim, seat)
      if colour >= 0:
        let
          mark = markOfColour(sim, colour)
          (mx, my) = sim.markCentre(mark)
        result.intent = intCover
        result.targetX = mx
        result.targetY = my
      else:
        result.intent = intHold
      result.symbol = 0
    else:
      ## Eve: tail Bob. It has no key, so behaviour is the only signal it has.
      let bob = sim.seatWithRole(1)
      let (bx, by) =
        if bob >= 0: sim.particleCentre(bob) else: centreOfField()
      result.intent = intShadow
      result.targetX = bx
      result.targetY = by
      result.symbol = 0
  of modeTag:
    if role == 0:
      result.intent = intEvade
      let (px, py) = sim.particleCentre(seat)
      result.targetX = px
      result.targetY = py
    else:
      ## A pursuer runs a PURE PURSUIT: `go` straight at the evader's current
      ## position. `shadow` is the wrong intent for a baseline pursuer even
      ## though it reads like the right one — it parks at
      ## `shadowStandoffPx` = 60 px, three times the `tagPx` = 20 px contact
      ## radius, so a shadowing pack trails the evader for a whole round and
      ## never scores a single contact tick. The naive chase does score, which
      ## is what makes `tag` a MEASURED round with a real bar for a champion to
      ## clear — and the published champion prompts already advise the better
      ## answer (two shadow, one intercepts ahead of the evader's velocity).
      let evader = sim.seatWithRole(0)
      let (ex, ey) =
        if evader >= 0: sim.particleCentre(evader) else: centreOfField()
      result.intent = intShadow
      result.targetX = ex
      result.targetY = ey
    result.symbol = 0

proc beelineOrder(sim: SimServer, seat: int, id: string): CogOrder =
  ## `beeline` — deliberately weaker and different in SHAPE, so the ladder gets
  ## a spread rather than two versions of one bot: EVERY seat, EVERY mode,
  ## covers the mark nearest to itself and says nothing. It never speaks, never
  ## decodes, never flees, and its pursuers chase nothing.
  result = baseOrder(sim, seat, id)
  let
    mark = nearestMarkToSeat(sim, seat)
    (mx, my) = sim.markCentre(mark)
  result.intent = intCover
  result.targetX = mx
  result.targetY = my
  result.symbol = 0

proc scriptedDirective*(
  ctl: ControlState,
  sim: SimServer,
  kind: Baseline,
  governed: seq[int]
): SquadDirective =
  ## The directive one baseline issues for the seats it governs this turn.
  ## `governed` is one seat's own particle in every real call — particle worlds
  ## has one body per seat — but the seq shape is kept so the fallback path can
  ## ask for an arbitrary particle set.
  result.source = dsScripted
  result.note = noteFor(sim.mode)
  if kind == blBeeline:
    result.note = "nearest mark"
  for seat in governed:
    if seat < 0 or seat >= sim.players.len:
      continue
    let id = sim.cogAlias(seat)
    result.orders.add(
      if kind == blBeeline: beelineOrder(sim, seat, id)
      else: drifterOrder(sim, seat, id))
