## The paintball floor-paint grid, the paint buff, and King of the Hill.
##
## Everything in this module is HASHED state: it is re-derived tick for tick by
## the wasm replay viewer from the recorded input masks, so every line of
## arithmetic here is INTEGER ONLY (`int64` intermediates where a product can
## grow). Nim's `int` is 32-bit under `--cpu:wasm32`, and a float cone test
## would additionally depend on whichever libm the build container shipped, so
## the cone predicate reads its direction out of the fixed-point `AimUnitX/Y`
## literals in sim_types.nim rather than calling `cos`/`sin`.
##
## Ownership of the seam: this module owns the GRID (membership, counts, the
## hill totals, the buff). The cone SWEEP that calls `tileInCone` lives in
## sim.nim, because it also needs that module's line-of-sight predicate.

import
  sim_types, sim_state

proc paintTileSize*(sim: SimServer): int {.inline.} =
  ## The configured tile side in map pixels, floored at 1 so a malformed
  ## config can never divide by zero inside the step loop.
  max(1, sim.config.paintTile)

proc paintTileAt*(sim: SimServer, x, y: int): int =
  ## The flat tile index containing map pixel (x, y), or -1 off the grid.
  if sim.paintGridW <= 0 or sim.paintGridH <= 0:
    return -1
  let
    size = sim.paintTileSize()
    tx = x div size
    ty = y div size
  if x < 0 or y < 0 or tx >= sim.paintGridW or ty >= sim.paintGridH:
    return -1
  ty * sim.paintGridW + tx

proc paintTileCentre*(sim: SimServer, tile: int): tuple[x, y: int] =
  ## The map-pixel centre of one tile (its top-left plus half a tile).
  let
    size = sim.paintTileSize()
    tx = tile mod sim.paintGridW
    ty = tile div sim.paintGridW
  (tx * size + size div 2, ty * size + size div 2)

proc paintTeamCode*(team: Team): uint8 {.inline.} =
  ## Wire code for a tile owner: 0 unpainted, 1 RED, 2 BLUE, ...
  uint8(ord(team) + 1)

proc paintTeamOf*(code: uint8): Team {.inline.} =
  ## The team a non-zero tile code names. Never called on 0.
  Team(int(code) - 1)

proc hillContains*(sim: SimServer, tile: int): bool =
  ## Whether one tile index is part of the hill square.
  for t in sim.hillTiles:
    if t == tile:
      return true
  false

proc initPaintGrid*(sim: var SimServer) =
  ## Sizes the paint grid to the installed map and computes the two things
  ## that are fixed for the whole episode:
  ##
  ## * `paintFloor` — whether a tile is PAINTABLE, i.e. its centre pixel is not
  ##   wall. Computed ONCE, here, against the wall mask with the spinning
  ##   diamonds stamped at spin frame 0 (initSimServer has just done that), so
  ##   the native server and the wasm viewer — which install the same `mapSpec`
  ##   and run the same frame-0 stamp — agree exactly. Recomputing it per tick
  ##   against the LIVE rotating mask would make "is this tile floor" a
  ##   function of the tick, which is not a rule anybody asked for.
  ## * `hillTiles` / `hillFloorTiles` — the (2r+1)^2 tile block centred on the
  ##   tile containing the map centre, and how many of those tiles are floor.
  ##   Wall tiles inside the square are excluded from BOTH the numerator and
  ##   the denominator, so "80% of the hill" always means 80% of the floor a
  ##   cog can actually stand on.
  let size = sim.paintTileSize()
  sim.paintGridW = (MapWidth + size - 1) div size
  sim.paintGridH = (MapHeight + size - 1) div size
  let count = sim.paintGridW * sim.paintGridH
  sim.paintOwner = newSeq[uint8](count)
  sim.paintFloor = newSeq[bool](count)
  for tile in 0 ..< count:
    let (cx, cy) = sim.paintTileCentre(tile)
    if cx >= MapWidth or cy >= MapHeight:
      continue
    sim.paintFloor[tile] = not sim.wallMask[mapIndex(cx, cy)]
  for team in Team:
    sim.paintCount[team] = 0
    sim.hillPaint[team] = 0
    sim.hillTicks[team] = 0
  sim.hillOwned = false
  sim.hillOwner = Red
  sim.lastHillFlipTick = low(int) div 2

  sim.hillTiles = @[]
  sim.hillFloorTiles = 0
  let
    radius = max(0, sim.config.hillRadiusTiles)
    centreTile = sim.paintTileAt(MapWidth div 2, MapHeight div 2)
  if centreTile < 0:
    return
  let
    ctx = centreTile mod sim.paintGridW
    cty = centreTile div sim.paintGridW
  for dy in -radius .. radius:
    for dx in -radius .. radius:
      let
        tx = ctx + dx
        ty = cty + dy
      if tx < 0 or ty < 0 or tx >= sim.paintGridW or ty >= sim.paintGridH:
        continue
      let tile = ty * sim.paintGridW + tx
      sim.hillTiles.add(tile)
      if sim.paintFloor[tile]:
        inc sim.hillFloorTiles

proc clearPaintGrid*(sim: var SimServer) =
  ## Wipes every tile back to unpainted and zeroes the derived counters. Runs
  ## at the start of each GAME of the episode (the two halves are independent
  ## boards) and on resetToLobby.
  for i in 0 ..< sim.paintOwner.len:
    sim.paintOwner[i] = 0
  for team in Team:
    sim.paintCount[team] = 0
    sim.hillPaint[team] = 0
    sim.hillTicks[team] = 0
  sim.hillOwned = false
  sim.hillOwner = Red
  sim.lastHillFlipTick = low(int) div 2

proc paintTile*(sim: var SimServer, tile: int, team: Team): bool =
  ## Flips one tile to `team` and keeps `paintCount` / `hillPaint` exact.
  ## Returns true when the owner actually changed, which is what the render
  ## pool and the `paint` event count. A tile that is not paintable, or is
  ## already this team's, is a no-op.
  if tile < 0 or tile >= sim.paintOwner.len:
    return false
  if not sim.paintFloor[tile]:
    return false
  let code = paintTeamCode(team)
  if sim.paintOwner[tile] == code:
    return false
  let onHill = sim.hillContains(tile)
  if sim.paintOwner[tile] != 0:
    let prev = paintTeamOf(sim.paintOwner[tile])
    dec sim.paintCount[prev]
    if onHill:
      dec sim.hillPaint[prev]
  sim.paintOwner[tile] = code
  inc sim.paintCount[team]
  if onHill:
    inc sim.hillPaint[team]
  true

proc tileInCone*(
  ax, ay, aimBrads, reach, maxWidth, tx, ty: int
): bool =
  ## The starter's spray-cone predicate, evaluated against a POINT (a tile
  ## centre) instead of a body disc, in fixed point.
  ##
  ## The cone's origin is `(ax, ay)`, its direction is the aim LOCKED at the
  ## fire instant (`arcAimBrads`), its centreline reach is `reach` px and its
  ## full width at that reach is `maxWidth` px, widening linearly from the
  ## muzzle — exactly the geometry `selectArcVictims` uses. Products are taken
  ## in `int64` because a 1400 px offset times a 1024-scaled unit times the
  ## reach overflows a 32-bit `int` on wasm32.
  let brads = ((aimBrads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
  let
    ux = int64(AimUnitX[brads])
    uy = int64(AimUnitY[brads])
    vx = int64(tx - ax)
    vy = int64(ty - ay)
    forward = vx * ux + vy * uy            ## scaled by AimUnitScale
    perpendicular = abs(vx * uy - vy * ux) ## scaled by AimUnitScale
  if forward <= 0:
    return false
  if forward > int64(reach) * int64(AimUnitScale):
    return false
  # perpendicular <= forward * maxWidth / (2 * reach), cross-multiplied so the
  # comparison never divides.
  perpendicular * 2'i64 * int64(reach) <= forward * int64(maxWidth)

proc paintUnderFor*(sim: SimServer, playerIndex: int): PaintUnder =
  ## What one cog's BODY CENTRE is standing on — the same "you are in it
  ## exactly while your centre is inside" convention trenches and puddles use.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return puNone
  let
    player = sim.players[playerIndex]
    tile = sim.paintTileAt(
      player.x + CollisionW div 2, player.y + CollisionH div 2)
  if tile < 0:
    return puNone
  let code = sim.paintOwner[tile]
  if code == 0:
    return puNone
  if paintTeamOf(code) == player.team: puOwn else: puEnemy

proc paintSpeedPct*(sim: SimServer, playerIndex: int): int {.inline.} =
  ## The speed/accel percentage this cog's feet earn it. 100 whenever the buff
  ## is gated off, so a `paintBuff: false` variant is byte-identical in the
  ## motion path to one compiled without the feature.
  if not sim.config.paintBuff:
    return 100
  case sim.players[playerIndex].paintUnder
  of puOwn: sim.config.paintSpeedOwnPct
  of puEnemy: sim.config.paintSpeedEnemyPct
  of puNone: 100

proc checkPaintInvariants*(sim: SimServer) =
  ## The sim guard the design note's `fault` / `sim_fault` row exists for,
  ## evaluated once per tick under the paint gates. Integer-only, O(cogs +
  ## teams): the tile counts are maintained INCREMENTALLY on every flip, so a
  ## count outside its own bounds means the increments and the grid no longer
  ## agree — and every number the episode is scored on is downstream of them.
  ## Better a named fault with 0.500/0.500 and a partial replay than a scored
  ## episode built on a broken counter.
  if sim.paintOwner.len != sim.paintGridW * sim.paintGridH:
    raise newException(SimGuardError,
      "paint grid is " & $sim.paintOwner.len & " tiles, expected " &
      $(sim.paintGridW * sim.paintGridH))
  for team in sim.teams():
    if sim.paintCount[team] < 0 or sim.paintCount[team] > sim.paintOwner.len:
      raise newException(SimGuardError,
        "paintCount[" & teamText(team) & "] = " & $sim.paintCount[team] &
        " is outside 0.." & $sim.paintOwner.len)
    if sim.hillPaint[team] < 0 or sim.hillPaint[team] > sim.hillFloorTiles:
      raise newException(SimGuardError,
        "hillPaint[" & teamText(team) & "] = " & $sim.hillPaint[team] &
        " exceeds hillFloorTiles " & $sim.hillFloorTiles)
  for i in 0 ..< sim.players.len:
    let p = sim.players[i]
    if p.alive and (p.x < 0 or p.y < 0 or p.x >= MapWidth or
        p.y >= MapHeight):
      raise newException(SimGuardError,
        "cog " & $i & " is outside the map at " & $p.x & "," & $p.y)

proc hillPixelBox*(sim: SimServer): array[4, int] =
  ## The hill's bounding box in MAP PIXELS: [x0, y0, x1, y1] of the tile block
  ## itself, inclusive of its last pixel. This is the box the seats' view JSON
  ## reports, so it has to be the tiles a cog actually has to paint rather
  ## than a radius measured off the hill's centre pixel.
  let size = sim.paintTileSize()
  if sim.hillTiles.len == 0:
    return [0, 0, 0, 0]
  var
    x0 = MapWidth
    y0 = MapHeight
    x1 = 0
    y1 = 0
  for tile in sim.hillTiles:
    let
      tx = (tile mod sim.paintGridW) * size
      ty = (tile div sim.paintGridW) * size
    x0 = min(x0, tx)
    y0 = min(y0, ty)
    x1 = max(x1, tx + size - 1)
    y1 = max(y1, ty + size - 1)
  [x0, y0, x1, y1]

proc hillOwnsFor*(sim: SimServer, team: Team): bool {.inline.} =
  ## Whether `team` covers at least `hillOwnPermille` of the hill's FLOOR
  ## tiles. The threshold is > 500 by config validation, so at most one team
  ## can ever satisfy this.
  sim.hillFloorTiles > 0 and
    sim.hillPaint[team] * 1000 >= sim.hillFloorTiles * sim.config.hillOwnPermille

proc hillCoveragePct*(sim: SimServer, team: Team): int {.inline.} =
  ## One team's hill coverage as a whole percent, for the scorebug and the
  ## per-seat view. Always visible to both seats: hill ownership is the
  ## scoreboard, not intel.
  if sim.hillFloorTiles <= 0: 0
  else: sim.hillPaint[team] * 100 div sim.hillFloorTiles

proc hillTicksLead*(sim: SimServer, team: Team): int {.inline.} =
  ## This game's banked hill-tick margin for `team` over the other side.
  let other = if team == Red: Blue else: Red
  sim.hillTicks[team] - sim.hillTicks[other]

proc clampInt*(value, lo, hi: int): int {.inline.} =
  if value < lo: lo elif value > hi: hi else: value

proc gameScorePermille*(margin, decisive: int): int =
  ## `0.5 + 0.5 * clamp(margin / decisive, -1, +1)`, in PERMILLE, so the two
  ## seats' scores sum to exactly 1000 for every legal margin (integer
  ## division of a symmetric quantity would not).
  let d = max(1, decisive)
  500 + clampInt(margin * 500 div d, -500, 500)
