## THE GRID HARNESS for the scripted baseline's control parameters.
##
## Checklist item 7: "The baseline's parameters were tuned with a grid harness,
## not guessed." Two of `drifter`'s numbers are continuous and role-owned, so
## they are the ones a grid can settle:
##
##   * `shadowStandoffPx` -- how far a crypto EAVESDROPPER parks from the
##     listener it is tailing (control.goalFor's intShadow branch). Too close
##     and it shoves the listener around and lands on the goal only by
##     accident; too far and it never arrives at all.
##   * `evadeProbePx` -- how far ahead a tag EVADER probes when it runs
##     (control.evadePoint samples 16 candidate points at this radius). Too
##     short and it turns inside a pursuer's reach; too long and every probe
##     lands in a wall and the choice collapses.
##
## Each is swept against the score of the ROLE THAT USES IT, over whole
## all-drifter episodes at several seeds, with the role cycle giving every seat
## every role. `--check` fails if the shipped value is not at the grid optimum
## (within `Tolerance` permille of the best cell), which is what makes the
## claim above testable rather than asserted; the table is written to
## `--out` for CI to keep as an artifact.
##
##   nim c -d:release --path:src -o:/tmp/tune tools/tune_baselines.nim
##   /tmp/tune --check --out sweep.md
##
## The pursuer's own stand-off (`tagPx div 2`) and the arrival radius
## (control.ArriveRadius) are compile-time constants rather than config, so
## they are NOT in this grid; the measurements behind them are recorded at
## their definitions.
import
  std/[os, strformat],
  bitworld/spriteprotocol,
  ../src/mpe/[sim, control, directives, baselines],
  ../tests/fixture

const
  Seeds = [FixtureSeed, 20260826, 8675309]
  Standoffs = [20, 40, 60, 80, 100, 140]
  Probes = [80, 140, 200, 260, 320, 400]
  ShippedStandoff = DefaultShadowStandoffPx     ## 60
  ShippedProbe = DefaultEvadeProbePx            ## 200
  Tolerance = 10
    ## permille. A cell inside this of the best is "at the optimum": the sim is
    ## deterministic, so this is not noise -- it is how much score the harness
    ## is willing to leave on the table before it calls the shipped value
    ## wrong.
  RoundTicks = 240        ## the certification fixture's round length.

proc episodeRoles(
  rounds: seq[Mode], seed: int, standoff, probe: int
): seq[RoundLogEntry] =
  ## One all-`drifter` episode, played exactly as the server plays it: one
  ## directive per seat per turn, compiled to masks by the real control layer.
  var config = fixtureConfig(rounds)
  config.seed = seed
  config.maxTicks = RoundTicks
  config.maxGames = rounds.len
  config.shadowStandoffPx = standoff
  config.evadeProbePx = probe
  var sim = seatedSim(config)
  var
    ctl = initControlState(sim)
    orders = newSeq[CogOrder](4)
    inputs = newSeq[InputState](sim.players.len)
    have = false
    played = 0
  while played < rounds.len:
    if sim.phase == Lobby and sim.players.len < FixtureSeats:
      sim.reseat(config)
      inputs = newSeq[InputState](sim.players.len)
      ctl = initControlState(sim)
      have = false
    if sim.phase == Playing:
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if sim.gameTicksElapsed() mod config.turnTicks == 0:
        for seat in 0 ..< 4:
          let directive = scriptedDirective(ctl, sim, blDrifter, @[seat])
          orders[seat] = directive.orders[0]
          sim.installSymbol(seat, orders[seat].symbol, turn)
          sim.recordHoldAnchor(seat)
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
    sim.step(inputs, inputs)
    if before != GameOver and sim.phase == GameOver:
      inc played
  sim.roundLog

proc meanForRoles(log: seq[RoundLogEntry], roles: set[uint8]): int =
  ## The mean banked permille over every (round, seat) whose ROLE is in the
  ## set. Roles are per round, so this averages a role across the cycle.
  var
    total = 0
    n = 0
  for entry in log:
    for seat in 0 ..< 4:
      if uint8(entry.roles[seat]) in roles:
        total += entry.permille[seat]
        inc n
  if n == 0: 0 else: total div n

proc sweepStandoff(): seq[(int, int)] =
  ## crypto: the EAVESDROPPERS are role indices 2 and 3.
  for standoff in Standoffs:
    var total = 0
    for seed in Seeds:
      let log = episodeRoles(
        @[modeCrypto, modeCrypto, modeCrypto, modeCrypto], seed,
        standoff, ShippedProbe)
      total += log.meanForRoles({2u8, 3u8})
    result.add((standoff, total div Seeds.len))

proc sweepProbe(): seq[(int, int)] =
  ## tag: the EVADER is role index 0.
  for probe in Probes:
    var total = 0
    for seed in Seeds:
      let log = episodeRoles(
        @[modeTag, modeTag, modeTag, modeTag], seed,
        ShippedStandoff, probe)
      total += log.meanForRoles({0u8})
    result.add((probe, total div Seeds.len))

proc report(name, unit: string, cells: seq[(int, int)], shipped: int): tuple[
    text: string, ok: bool] =
  var
    best = -1
    bestAt = -1
    shippedScore = -1
  for (value, score) in cells:
    if score > best:
      best = score
      bestAt = value
    if value == shipped:
      shippedScore = score
  var text = &"\n### {name}\n\n| {unit} | score (permille) |\n| --- | --- |\n"
  for (value, score) in cells:
    let mark =
      if value == shipped and value == bestAt: "  <- shipped, optimum"
      elif value == shipped: "  <- shipped"
      elif value == bestAt: "  <- grid optimum"
      else: ""
    text.add(&"| {value} | {score}{mark} |\n")
  let ok = shippedScore >= 0 and best - shippedScore <= Tolerance
  text.add(&"\nshipped {shipped} scores {shippedScore}; grid optimum " &
           &"{bestAt} scores {best}; tolerance {Tolerance} -> " &
           (if ok: "OK\n" else: "OUT OF TOLERANCE\n"))
  (text, ok)

when isMainModule:
  var
    check = false
    outPath = ""
    args = commandLineParams()
    i = 0
  while i < args.len:
    case args[i]
    of "--check": check = true
    of "--out":
      inc i
      if i < args.len: outPath = args[i]
    else:
      echo "usage: tune_baselines [--check] [--out <path>]"
      quit 2
    inc i

  var text = "# drifter control-parameter sweep\n\n" &
    &"seeds {Seeds}, {RoundTicks}-tick rounds, four rounds per episode so the " &
    "role cycle gives every seat every role. Each parameter is scored by the " &
    "role that uses it.\n"
  let standoff = report(
    "shadowStandoffPx (crypto eavesdropper mean)", "px", sweepStandoff(),
    ShippedStandoff)
  let probe = report(
    "evadeProbePx (tag evader mean)", "px", sweepProbe(), ShippedProbe)
  text.add(standoff.text)
  text.add(probe.text)
  echo text
  if outPath.len > 0:
    writeFile(outPath, text)
  if check and not (standoff.ok and probe.ok):
    echo "::error::a shipped baseline parameter is not at its grid optimum; " &
      "retune it or state why the grid is wrong"
    quit 1
