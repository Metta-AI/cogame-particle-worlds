## The control layer: the ONE deterministic function that turns a directive
## into per-tick Sprite v1 actuator masks.
##
## Both LLM directives and scripted directives are compiled by this same code,
## so the two policy kinds are strictly comparable and a scripted baseline is
## legal by construction. It is a pure function of
## `(sim state, directive, cogIndex) -> uint8`.
##
## It sits OUTSIDE the determinism boundary: the server records the masks this
## produces into the replay, and the wasm viewer feeds those recorded masks to
## the identical sim. Nothing here is re-run at playback, which is why this
## module may use ordinary floating-point navigation maths where the hashed
## paint grid may not.

import
  std/[math, tables],
  bitworld/spriteprotocol,
  sim, directives

const
  NavCell* = 12               ## nav grid cell side, in px.
                              ## Sized to the ARENA, not to the paint grid: the
                              ## arena's corridors are ~26 px wide for a 13 px
                              ## footprint, so a cell the size of a paint tile
                              ## (34 px) has no open cell anywhere inside a gap
                              ## between two obstacles and the flow field
                              ## reports the whole far side of every obstacle
                              ## column UNREACHABLE. Measured on that grid, a
                              ## sweeping squad fell back to the straight line,
                              ## walked into the first wall and pressed the same
                              ## d-pad direction for two thousand ticks. At
                              ## 12 px every 26 px corridor contains a cell
                              ## centre with the full footprint's clearance.
  FieldRefreshTicks* = 12     ## a flow field is recomputed at most this often.
  MaxCachedFields* = 64       ## flow fields kept before the cache is dropped.
                              ## A field is one int per cell, so an unbounded
                              ## cache on a fine grid is an unbounded leak over
                              ## a long episode; eight cogs never need more.
  ArriveRadius* = 20          ## px: a cog this close to its goal stops moving.
  AimMinRangeSq* = 16 * 16    ## an aim target nearer than this gives a vector
                              ## too short to mean a direction.
  AimDeadBrads* = 4           ## no turn button inside this error.
  HuntMemoryTicks* = 72       ## how long a seen particle stays "known".
  StuckTicks* = 8             ## ticks of zero displacement after which a cog
                              ## steers along the obstacle instead of into it.
                              ## The flow field is built once, over the wall
                              ## mask alone: it cannot know about the spinning
                              ## diamonds' later frames, and it cannot know
                              ## about the other seven COGS at all — four cogs
                              ## sharing one goal in a 26 px corridor jam each
                              ## other. Degrade-never-hang applies to a cog as
                              ## much as to a network call.

type
  NavGrid* = object
    w*, h*: int
    open*: seq[bool]

  ControlState* = object
    ## Everything the control layer remembers between ticks. Lives on the
    ## SERVER, never on the sim, so it can never enter gameHash.
    grid*: NavGrid
    fields*: Table[int, seq[int]]      ## goal cell -> BFS distance field
    fieldTick*: Table[int, int]        ## goal cell -> tick it was built
    lastSeenX*, lastSeenY*: seq[int]   ## per cog: last known enemy position
    lastSeenTick*: seq[int]
    lastSeenIndex*: seq[int]
    lastX*, lastY*: seq[int]           ## per cog: position at the last observe
    stuckTicks*: seq[int]              ## per cog: consecutive motionless ticks

proc navCellOf*(grid: NavGrid, x, y: int): int =
  ## The flat nav cell containing a map pixel, or -1 off the grid.
  let
    cx = x div NavCell
    cy = y div NavCell
  if x < 0 or y < 0 or cx >= grid.w or cy >= grid.h:
    return -1
  cy * grid.w + cx

proc navCentre*(grid: NavGrid, cell: int): tuple[x, y: int] =
  ((cell mod grid.w) * NavCell + NavCell div 2,
   (cell div grid.w) * NavCell + NavCell div 2)

proc buildNavGrid*(sim: SimServer): NavGrid =
  ## A NavCell-px occupancy grid over the sim's REAL wall mask (not an
  ## observation stream): a cell is open when a cog footprint fits at its
  ## centre. Built once per episode, against the mask as it stands at build
  ## time — a spinning diamond that later rotates into a cell this grid calls
  ## open is handled by the stuck deflection in `compileMask`, not by rebuilding
  ## a five-thousand-cell grid every tick.
  result.w = (MapWidth + NavCell - 1) div NavCell
  result.h = (MapHeight + NavCell - 1) div NavCell
  result.open = newSeq[bool](result.w * result.h)
  for cell in 0 ..< result.open.len:
    let (cx, cy) = result.navCentre(cell)
    if cx < MapWidth and cy < MapHeight:
      result.open[cell] = sim.canOccupy(cx, cy)

proc nearestOpenCell*(grid: NavGrid, x, y: int): int =
  ## The open cell nearest a map point, by expanding ring search. -1 only
  ## when the grid has no open cell at all.
  let start = grid.navCellOf(clamp(x, 0, MapWidth - 1), clamp(y, 0, MapHeight - 1))
  if start >= 0 and grid.open[start]:
    return start
  let
    sx = clamp(x, 0, MapWidth - 1) div NavCell
    sy = clamp(y, 0, MapHeight - 1) div NavCell
  for r in 1 .. (grid.w + grid.h):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          cx = sx + dx
          cy = sy + dy
        if cx < 0 or cy < 0 or cx >= grid.w or cy >= grid.h:
          continue
        let cell = cy * grid.w + cx
        if grid.open[cell]:
          return cell
  -1

proc computeField*(grid: NavGrid, goal: int): seq[int] =
  ## Breadth-first flow field to `goal` over 4-connected open cells: the
  ## number of steps from every cell to the goal, -1 where unreachable.
  result = newSeq[int](grid.open.len)
  for i in 0 ..< result.len:
    result[i] = -1
  if goal < 0 or goal >= result.len or not grid.open[goal]:
    return
  var
    queue = @[goal]
    head = 0
  result[goal] = 0
  while head < queue.len:
    let
      cell = queue[head]
      cx = cell mod grid.w
      cy = cell div grid.w
      d = result[cell]
    inc head
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= grid.w or ny >= grid.h:
        continue
      let next = ny * grid.w + nx
      if not grid.open[next] or result[next] >= 0:
        continue
      result[next] = d + 1
      queue.add(next)

proc fieldFor*(ctl: var ControlState, tick, goal: int): seq[int] =
  ## The cached flow field for one goal cell, rebuilt at most once every
  ## FieldRefreshTicks. Cheap enough that eight cogs chasing eight distinct
  ## goals still costs a handful of BFS passes per second.
  if goal < 0:
    return @[]
  if ctl.fields.hasKey(goal) and
      tick - ctl.fieldTick.getOrDefault(goal, low(int) div 2) < FieldRefreshTicks:
    return ctl.fields[goal]
  if ctl.fields.len >= MaxCachedFields and not ctl.fields.hasKey(goal):
    ctl.fields.clear()
    ctl.fieldTick.clear()
  let field = computeField(ctl.grid, goal)
  ctl.fields[goal] = field
  ctl.fieldTick[goal] = tick
  field

proc navSteer*(
  ctl: var ControlState, tick, fromX, fromY, goalX, goalY: int
): tuple[dx, dy: int] =
  ## The steering vector for one cog: straight at the goal when the line of
  ## sight is clear (so a cog does not stair-step around an open floor), else
  ## down the flow field toward the neighbouring cell nearest the goal.
  let goalCell = ctl.grid.nearestOpenCell(goalX, goalY)
  if goalCell < 0:
    return (0, 0)
  let (gx, gy) = ctl.grid.navCentre(goalCell)
  let field = ctl.fieldFor(tick, goalCell)
  let here = ctl.grid.nearestOpenCell(fromX, fromY)
  if here < 0 or field.len == 0 or field[here] <= 1:
    return (gx - fromX, gy - fromY)
  let
    cx = here mod ctl.grid.w
    cy = here div ctl.grid.w
  var
    best = field[here]
    bestCell = -1
  for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)]:
    let
      nx = cx + dx
      ny = cy + dy
    if nx < 0 or ny < 0 or nx >= ctl.grid.w or ny >= ctl.grid.h:
      continue
    let next = ny * ctl.grid.w + nx
    if not ctl.grid.open[next] or field[next] < 0:
      continue
    if dx != 0 and dy != 0:
      # No corner cutting: a diagonal is only taken when both of the cells it
      # squeezes between are open. A cell is barely wider than a cog, so
      # clipping the corner of an obstacle wedges the cog against it and it
      # presses the same direction forever.
      if not ctl.grid.open[cy * ctl.grid.w + nx] or
          not ctl.grid.open[ny * ctl.grid.w + cx]:
        continue
    if field[next] < best:
      best = field[next]
      bestCell = next
  if bestCell < 0:
    return (gx - fromX, gy - fromY)
  let (nxp, nyp) = ctl.grid.navCentre(bestCell)
  (nxp - fromX, nyp - fromY)

proc bradsErr*(desired, current: int): int =
  ## Signed shortest turn from `current` to `desired`, in brads: positive is
  ## counter-clockwise (button B), negative clockwise (button Select).
  var d = (desired - current) mod AimBradsTurn
  if d < -(AimBradsTurn div 2): d += AimBradsTurn
  if d > AimBradsTurn div 2: d -= AimBradsTurn
  d

proc initControlState*(sim: SimServer): ControlState =
  result.grid = buildNavGrid(sim)
  result.fields = initTable[int, seq[int]]()
  result.fieldTick = initTable[int, int]()
  result.lastSeenX = newSeq[int](MaxPlayers)
  result.lastSeenY = newSeq[int](MaxPlayers)
  result.lastSeenTick = newSeq[int](MaxPlayers)
  result.lastSeenIndex = newSeq[int](MaxPlayers)
  result.lastX = newSeq[int](MaxPlayers)
  result.lastY = newSeq[int](MaxPlayers)
  result.stuckTicks = newSeq[int](MaxPlayers)
  for i in 0 ..< MaxPlayers:
    result.lastSeenTick[i] = low(int) div 2
    result.lastSeenIndex[i] = -1
    result.lastX[i] = low(int) div 2
    result.lastY[i] = low(int) div 2

proc observeEnemies*(ctl: var ControlState, sim: SimServer) =
  ## The control layer's ONCE-PER-TICK observation: each cog's memory of the
  ## nearest enemy it can currently see, and whether it is making progress.
  ## Vision is the sim's own fog rule, so the control layer never knows more
  ## than the cog does.
  ##
  ## Both are updated here rather than in `compileMask` so that compiling a
  ## mask stays a pure read of this state: the same (state, directive) pair
  ## yields the same byte however many times it is asked.
  while ctl.lastSeenX.len < sim.players.len:
    ctl.lastSeenX.add(0)
    ctl.lastSeenY.add(0)
    ctl.lastSeenTick.add(low(int) div 2)
    ctl.lastSeenIndex.add(-1)
  while ctl.lastX.len < sim.players.len:
    ctl.lastX.add(low(int) div 2)
    ctl.lastY.add(low(int) div 2)
    ctl.stuckTicks.add(0)
  for i in 0 ..< sim.players.len:
    if sim.players[i].x == ctl.lastX[i] and sim.players[i].y == ctl.lastY[i]:
      inc ctl.stuckTicks[i]
    else:
      ctl.stuckTicks[i] = 0
    ctl.lastX[i] = sim.players[i].x
    ctl.lastY[i] = sim.players[i].y
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    var
      bestDist = high(int)
      bestIndex = -1
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive:
        continue
      if sim.players[j].team == sim.players[i].team:
        continue
      if not sim.playerVisibleTo(i, j):
        continue
      let d = distSq(sim.players[i].x, sim.players[i].y,
                     sim.players[j].x, sim.players[j].y)
      if d < bestDist:
        bestDist = d
        bestIndex = j
    if bestIndex >= 0:
      ctl.lastSeenX[i] = sim.players[bestIndex].x
      ctl.lastSeenY[i] = sim.players[bestIndex].y
      ctl.lastSeenTick[i] = sim.tickCount
      ctl.lastSeenIndex[i] = bestIndex

proc knownEnemy*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[known: bool, x, y, index, ticksAgo: int] =
  ## The nearest enemy this cog knows about — seen now, or seen within
  ## HuntMemoryTicks. That memory is intel a commander legitimately has.
  if cogIndex >= ctl.lastSeenTick.len:
    return (false, 0, 0, -1, 0)
  let age = sim.tickCount - ctl.lastSeenTick[cogIndex]
  if age > HuntMemoryTicks or ctl.lastSeenIndex[cogIndex] < 0:
    return (false, 0, 0, -1, 0)
  (true, ctl.lastSeenX[cogIndex], ctl.lastSeenY[cogIndex],
   ctl.lastSeenIndex[cogIndex], age)

proc particleCentreAt*(sim: SimServer, cogIndex: int): tuple[x, y: int] =
  ## One particle's centre in map pixels.
  (sim.players[cogIndex].x + CollisionW div 2,
   sim.players[cogIndex].y + CollisionH div 2)

proc nearestOtherParticle*(
  sim: SimServer, cogIndex, toX, toY: int
): tuple[found: bool, index, x, y: int] =
  ## The OTHER particle nearest a point. Ties break to the lowest index, so
  ## the answer is a pure function of state and the same (state, order) pair
  ## always compiles to the same byte.
  result = (false, -1, 0, 0)
  var best = high(int)
  for i in 0 ..< sim.players.len:
    if i == cogIndex:
      continue
    let (px, py) = sim.particleCentreAt(i)
    let d = distSq(toX, toY, px, py)
    if d < best:
      best = d
      result = (true, i, px, py)

proc evadePoint*(
  ctl: ControlState, sim: SimServer, cogIndex: int
): tuple[x, y: int] =
  ## 16 candidate points at `evadeProbePx` around the particle at `16 * j`
  ## brads; keep the WALKABLE ones and pick the one maximising the minimum
  ## distance to any other particle, ties to the lowest `j`. If none is
  ## walkable the field centre is the answer, so `evade` always has somewhere
  ## to go. Integer only — the 16 headings come from the starter's integer
  ## aim table, never from sin/cos.
  let
    (px, py) = sim.particleCentreAt(cogIndex)
    reach = max(1, sim.config.evadeProbePx)
  var
    bestScore = -1
    found = false
  result = centreOfField()
  for j in 0 ..< 16:
    let
      brads = (16 * j) and 255
      cx = clamp(px + AimUnitX[brads] * reach div AimUnitScale, 0, MapWidth - 1)
      cy = clamp(py + AimUnitY[brads] * reach div AimUnitScale, 0, MapHeight - 1)
    if not sim.canOccupy(cx, cy):
      continue
    var worst = high(int)
    for i in 0 ..< sim.players.len:
      if i == cogIndex:
        continue
      let (ox, oy) = sim.particleCentreAt(i)
      worst = min(worst, distSq(cx, cy, ox, oy))
    if worst == high(int):
      worst = 0
    if worst > bestScore:
      bestScore = worst
      result = (cx, cy)
      found = true
  if not found:
    result = centreOfField()

proc goalFor*(
  ctl: ControlState, sim: SimServer, order: CogOrder, cogIndex: int
): tuple[x, y: int] =
  ## The goal point one intent resolves to for one particle. EVERY branch has
  ## a defined answer, so a particle is never left without somewhere to be.
  let
    (px, py) = sim.particleCentreAt(cogIndex)
    seat = cogIndex
    tx = clamp(order.targetX, 0, MapWidth - 1)
    ty = clamp(order.targetY, 0, MapHeight - 1)
  case order.intent
  of intGo:
    (tx, ty)
  of intHold:
    ## The particle's own position at the tick the order was installed, so a
    ## DRIFTING particle is steered back rather than allowed to coast away.
    if seat >= 0 and seat < 4: (sim.holdX[seat], sim.holdY[seat])
    else: (px, py)
  of intCover:
    let mark = sim.nearestMarkTo(tx, ty)
    if mark >= 0: sim.markCentre(mark) else: (tx, ty)
  of intShadow:
    ## Whom to shadow. Normally "the other particle nearest `target`", which is
    ## what lets an eavesdropper name the listener by pointing at where it last
    ## saw it. In a `tag` round a PURSUER always shadows the EVADER: the target
    ## point in an order is up to 4.5 s stale (one whole turn), by which time
    ## the evader has moved ~420 px at cruise, so "nearest to that point" was
    ## reliably ANOTHER PURSUER and the pack chased itself in circles at a
    ## measured closest approach of 52 px. There is exactly one thing worth
    ## shadowing in `tag`, and naming it removes the ambiguity instead of
    ## papering over it.
    let other =
      if sim.isPursuer(seat):
        let evader = sim.seatWithRole(0)
        if evader >= 0 and evader != cogIndex:
          let (ex, ey) = sim.particleCentreAt(evader)
          (found: true, index: evader, x: ex, y: ey)
        else:
          sim.nearestOtherParticle(cogIndex, tx, ty)
      else:
        sim.nearestOtherParticle(cogIndex, tx, ty)
    if not other.found:
      (px, py)
    else:
      let
        ## A `tag` PURSUER shadows to CONTACT, not to the eavesdropper's
        ## stand-off. The standoff exists so an eavesdropper tailing the
        ## listener can watch it without shoving it; a pursuer's whole job is
        ## to be within `tagPx` = 20 px, and the 60 px stand-off is three times
        ## that — measured, a shadowing pack trails the evader for a whole
        ## round at a closest approach of 71 px and scores not one contact
        ## tick, which would make `tag` an unmeasured round instead of a chase.
        standoff =
          if sim.isPursuer(seat): max(1, sim.config.tagPx div 2)
          else: max(1, sim.config.shadowStandoffPx)
        d2 = distSq(px, py, other.x, other.y)
      if d2 <= standoff * standoff:
        (px, py)                 ## already inside: hold station, do not oscillate
      else:
        let brads = bradsOfVector(px - other.x, py - other.y)
        (clamp(other.x + AimUnitX[brads] * standoff div AimUnitScale,
               0, MapWidth - 1),
         clamp(other.y + AimUnitY[brads] * standoff div AimUnitScale,
               0, MapHeight - 1))
  of intEvade:
    ctl.evadePoint(sim, cogIndex)
  of intOrbit:
    ## A quarter turn ahead of the particle's current bearing about `t`, i.e.
    ## counter-clockwise motion, snapped to the nearest walkable pixel.
    let
      radius = max(1, sim.config.orbitRadiusPx)
      brads = (bradsOfVector(px - tx, py - ty) + 24) and 255
      wanted = (
        x: clamp(tx + AimUnitX[brads] * radius div AimUnitScale,
                 0, MapWidth - 1),
        y: clamp(ty + AimUnitY[brads] * radius div AimUnitScale,
                 0, MapHeight - 1))
    sim.nearestWalkable(wanted.x, wanted.y)

proc compileMask*(
  ctl: var ControlState,
  sim: SimServer,
  order: CogOrder,
  cogIndex: int
): uint8 =
  ## One particle's Sprite v1 actuator mask for this tick.
  ##
  ## Legality is STRUCTURAL, not checked afterwards: Up and Down are chosen
  ## from one sign so they can never both be set (same for Left/Right), B and
  ## Select come from one signed error, and A and C are NEVER touched —
  ## particle worlds has no weapon, no throwable and no trigger.
  result = 0
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return
  let player = sim.players[cogIndex]
  if not player.alive:
    return
  let
    (px, py) = sim.particleCentreAt(cogIndex)
    goal = ctl.goalFor(sim, order, cogIndex)

  # --- d-pad: the octant of the steering vector, unless we have arrived ---
  # Inside ArriveRadius NO d-pad bit is set and the damping brings the particle
  # to rest: moving is nearly free here, so a particle that keeps pressing
  # while sitting on a mark would jitter off it and lose the closeness it is
  # being paid for.
  if distSq(px, py, goal.x, goal.y) > ArriveRadius * ArriveRadius:
    var steer = ctl.navSteer(sim.tickCount, px, py, goal.x, goal.y)
    if cogIndex < ctl.stuckTicks.len and ctl.stuckTicks[cogIndex] >= StuckTicks:
      # Wedged: steer a quarter turn clockwise instead, which slides the
      # particle ALONG whatever it is pressed against — a wall, or another
      # particle. One consistent rotation makes this a wall follower, so a
      # convex obstacle is always escaped rather than oscillated against.
      steer = (dx: -steer.dy, dy: steer.dx)
    let
      ax = abs(steer.dx)
      ay = abs(steer.dy)
      major = max(ax, ay)
    if major > 0:
      # Diagonals only when the minor axis is at least 40% of the major one,
      # so a straight run does not chatter between two octants.
      if ax * 5 >= major * 2:
        result = result or (if steer.dx > 0: ButtonRight else: ButtonLeft)
      if ay * 5 >= major * 2:
        result = result or (if steer.dy > 0: ButtonDown else: ButtonUp)

  # --- facing: `face` if the order gave one, else the goal, else the current
  # velocity, else due east. `face` only turns the sprite.
  var
    aimX = 0
    aimY = 0
    aimed = false
  if order.hasFace:
    aimX = order.faceX
    aimY = order.faceY
    aimed = true
  if not aimed and distSq(px, py, goal.x, goal.y) > AimMinRangeSq:
    aimX = goal.x
    aimY = goal.y
    aimed = true
  if not aimed and (player.velX != 0 or player.velY != 0):
    aimX = px + player.velX
    aimY = py + player.velY
    aimed = true
  if not aimed:
    aimX = px + 64
    aimY = py
  let
    desired = bradsOfVector(aimX - px, aimY - py)
    err = bradsErr(desired, player.aimBrads)
  if err > AimDeadBrads:
    result = result or ButtonB          ## counter-clockwise
  elif err < -AimDeadBrads:
    result = result or ButtonSelect     ## clockwise
  # A and C are never set. There is nothing to fire and nothing to place.
