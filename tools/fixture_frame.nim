## THE WORST-CASE BROADCAST FRAME, built by the REAL server code.
##
## `tools/ci/renderer_fixture.html` loads the shipped viewer page and hands it
## a spectator frame chosen to hurt: a full-cap 160-rune note on EVERY seat, a
## non-silent symbol on all four particles, the crypto panel populated, the
## mark rail full, and one feed row of every kind the sim can emit, all at
## once. That frame cannot be hand-written in the fixture: a made-up shape
## renders as an empty page and the fixture then measures nothing, which is
## exactly the failure it exists to catch. So it is BUILT HERE, by
## `broadcast.buildStateJson` over a real four-round episode, written to
## `tools/ci/renderer_fixture_frame.json` by `tools/gen_fixture_frame.nim`, and
## pinned against a freshly built frame by `tests/test_viewer.nim` so it cannot
## drift away from the server.
import
  std/[json, tables, unicode],
  bitworld/spriteprotocol,
  ../src/mpe/[sim, broadcast, control, directives, baselines],
  ../tests/fixture

const
  WorstCaseNote* =
    "hold at teal south flank until the greens commit and then break for " &
    "the goal in one straight run, never crossing the middle while an eye " &
    "is close 012345\u00e9\u00e0\u00fc\U0001F680"
    ## Exactly MaxNoteRunes (160) runes, ending in a 4-byte emoji so the
    ## rune-boundary path is real here too.
  WorstCaseNames* = [
    "particle-worlds-swarm-champion",
    "particle-worlds-cipher-champion",
    "particle-worlds-drifter",
    "particle-worlds-beeline"]
    ## Long policy names: the 360 px plate is where a name collapses.

proc worstCaseFrames*(): JsonNode =
  ## `{"playing": <crypto-round frame>, "gameover": <endcard frame>}` — the two
  ## states the chrome draws most text in, from one real episode.
  var config = fixtureConfig()
  var sim = seatedSim(config)
  for seat in 0 ..< FixtureSeats:
    sim.seatNames[seat] = WorstCaseNames[seat]
    sim.seatPolicyKind[seat] = "prompt"
  var
    ctl = initControlState(sim)
    tracker = initBroadcastTracker()
    orders = newSeq[CogOrder](4)
    inputs = newSeq[InputState](sim.players.len)
    have = false
    played = 0
    catalogue = initOrderedTable[string, JsonNode]()
    beats = newJArray()
    playingFrame = ""
    gameoverFrame = ""
  while played < 4:
    if sim.phase == Lobby and sim.players.len < FixtureSeats:
      sim.reseat(config)
      inputs = newSeq[InputState](sim.players.len)
      ctl = initControlState(sim)
      have = false
    if sim.phase == Playing:
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if sim.gameTicksElapsed() mod config.turnTicks == 0:
        for seat in 0 ..< 4:
          var directive = scriptedDirective(ctl, sim, blDrifter, @[seat])
          directive.note = WorstCaseNote
          ## A non-silent symbol on EVERY particle: silence would leave the
          ## radio strip and four plate glyphs empty, which is the easy case.
          ## It goes on the ORDER, because `pushFeedDirective` installs the
          ## symbol the record carries — live and in replay alike.
          directive.orders[0].symbol = 1 + seat
          orders[seat] = directive.orders[0]
          sim.installSymbol(seat, orders[seat].symbol, turn)
          sim.recordHoldAnchor(seat)
          sim.pushFeedDirective(directive.boundedDirectiveRecord(
            sim.roundIndex + 1, turn, seat, $sim.mode, sim.cogAlias(seat),
            roleName(sim.mode, sim.roleIndex[seat])))
        have = true
      ## A real pursuer contact, so the `tag` feed row and beat are the sim's
      ## own rather than an invention: a drifter pack does not reliably catch
      ## a faster evader inside one fixture round.
      if sim.mode == modeTag and sim.gameTicksElapsed() == 60:
        let evader = sim.seatWithRole(0)
        for seat in 0 ..< 4:
          if seat != evader:
            sim.players[seat].x = sim.players[evader].x + 4
            sim.players[seat].y = sim.players[evader].y
            break
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
    var stepEventsJson = newJArray()
    sim.stepEvents(tracker, stepEventsJson)
    for event in stepEventsJson:
      let kind = event["k"].getStr()
      if kind notin catalogue:
        catalogue[kind] = event
      if kind in ["roundstart", "firstword", "onpoint", "tag", "roundover"]:
        beats.add(event)
    ## The frame the fixture opens on: mid-round in CRYPTO, the busiest state
    ## the chrome has (the decode panel, the key, the mark rail and the radio
    ## strip are all up at once).
    if sim.mode == modeCrypto and sim.phase == Playing and
        sim.gameTicksElapsed() == 180:
      playingFrame = sim.buildStateJson(
        newJArray(), playing = true, speed = 1,
        maxTick = config.maxTicks * config.maxGames, looping = false,
        transportEnabled = true, mismatchTick = -1, povSlot = -1)
    if before != GameOver and sim.phase == GameOver:
      inc played
      if played >= 4:
        gameoverFrame = sim.buildStateJson(
          newJArray(), playing = false, speed = 1,
          maxTick = config.maxTicks * config.maxGames, looping = false,
          transportEnabled = true, mismatchTick = -1, povSlot = -1)
  doAssert playingFrame.len > 0 and gameoverFrame.len > 0

  ## Every feed row kind at once. Each event is the sim's own, collected from
  ## the episode above; splicing the catalogue into one frame is what makes
  ## the fixture a WORST case rather than a typical one.
  var events = newJArray()
  for kind, event in catalogue:
    events.add(event)
  var playing = parseJson(playingFrame)
  playing["events"] = events
  playing["beats"] = beats
  var gameover = parseJson(gameoverFrame)
  gameover["beats"] = beats
  %*{"playing": playing, "gameover": gameover}

proc worstCaseFramesText*(): string =
  ## The committed file's exact bytes.
  pretty(worstCaseFrames()) & "\n"

when isMainModule:
  doAssert WorstCaseNote.runeLen == MaxNoteRunes,
    "the fixture note must sit exactly on the cap: " & $WorstCaseNote.runeLen
  echo "note runes: ", WorstCaseNote.runeLen
