## The public belief state: which mark each mobile particle is nearest, how
## long it has stayed there, and the two derived signals a spectator (and an
## eavesdropper) reads off pure BEHAVIOUR.
##
## This is the legitimate channel `crypto` turns on. A symbol tells an
## eavesdropper nothing — the key is redrawn every round and one symbol has
## four a-priori-equal meanings — but WATCHING THE LISTENER MOVE tells it
## everything, so the listener's problem is arriving without being followed.
## `nearest_mark` / `settled_ticks` are in every seat's observation for exactly
## that reason, and the viewer's crypto panel reads the same numbers.

import
  sim_types, field, scoring

proc updateBeliefs*(
  sim: var SimServer
): tuple[decodes: seq[tuple[seat, mark: int, right: bool]], onPoints: seq[
    tuple[seat, mark: int]]] =
  ## Recomputes `nearestMark` / `settledTicks` for every mobile agent and
  ## reports the two crossings that are worth an event:
  ##
  ## * `decode` — the tick `settledTicks` reaches SettleTicks on one mark, i.e.
  ##   this agent has visibly committed to it. Emitted once per commitment; a
  ##   fresh commitment to a different mark can emit again.
  ## * `onpoint` — the first time in the round this agent comes inside
  ##   `landmarkRadius + OnPointSlackPx` of the round's GOAL mark.
  let
    seats = min(4, sim.players.len)
    settleReach = sim.config.landmarkRadius + SettleSlackPx
    pointReach = sim.config.landmarkRadius + OnPointSlackPx
  for seat in 0 ..< seats:
    if sim.isAnchored(seat):
      sim.nearestMark[seat] = -1
      sim.settledTicks[seat] = 0
      continue
    let
      (px, py) = sim.particleCentre(seat)
      mark = sim.nearestMarkTo(px, py)
    if mark < 0:
      sim.nearestMark[seat] = -1
      sim.settledTicks[seat] = 0
      continue
    let inside = sim.distanceTo(seat, mark) <= settleReach
    if mark == sim.nearestMark[seat] and inside:
      inc sim.settledTicks[seat]
      if sim.settledTicks[seat] == SettleTicks and sim.decodedMark[seat] != mark:
        sim.decodedMark[seat] = mark
        result.decodes.add(
          (seat: seat, mark: mark, right: mark == sim.goalLandmark))
    else:
      if mark != sim.nearestMark[seat]:
        sim.decodedMark[seat] = -1
      sim.nearestMark[seat] = mark
      sim.settledTicks[seat] = (if inside: 1 else: 0)
    if sim.goalLandmark >= 0 and not sim.onPointDone[seat] and
        sim.distanceTo(seat, sim.goalLandmark) <= pointReach:
      sim.onPointDone[seat] = true
      result.onPoints.add((seat: seat, mark: sim.goalLandmark))

proc settledOn*(sim: SimServer, seat: int): int =
  ## The mark this seat has visibly settled on, or -1. This is the number the
  ## viewer's crypto panel shows as "GREEN-alpha -> bone" and the number an
  ## eavesdropper is legitimately entitled to infer from.
  if seat < 0 or seat >= 4: -1 else: sim.decodedMark[seat]
