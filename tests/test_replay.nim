## AN END-TO-END EPISODE THAT WRITES A REPLAY, and the integrity chain over it.
##
## This is the test that proves the wasm viewer can re-derive the whole episode
## from the recorded actuator masks: it plays a full scripted four-round episode
## through the real replay writer, parses the bytes back, re-simulates from the
## config plus the mask log and compares EVERY recorded hash — including the
## landmark draw, the colour permutation, the role cycle and the key, none of
## which are load-bearing records.

import std/[json, os, osproc, strutils, tables, unicode, unittest]
import bitworld/spriteprotocol
import ../src/mpe/[sim, control, directives, baselines, decide, replays,
                   replay_runtime, broadcast, events]
import fixture

const
  NonAsciiLabel = "poli\u00e7y-\u00e9\u00e0\u00fc"      ## a non-ASCII policy label
  NonAsciiNote = "cubrir la marca m\u00e1s cercana \u2014 \u00e9\u00e0\u00fc"

proc recordEpisode(rounds: seq[Mode], ticks: int,
                   wallClockBudgetSeconds = 0): tuple[
    path: string, sim: SimServer, records: int] =
  ## Plays a scripted episode through the REAL replay writer, exactly as the
  ## server's loop does: one mask per particle per tick, one hash per tick, and
  ## the chat records for every roundcard, register, directive and the result.
  ##
  ## With `wallClockBudgetSeconds > 0` the episode ends the way the engine's
  ## hard stop ends it (`server.nim`'s deadline check) instead of on the round
  ## clock. This harness's wall clock is the TICK clock — 24 Hz, so a budget of
  ## 10 lands the stop on tick 240, mid-round — which keeps the recording
  ## reproducible while the stop itself goes through the very procs the server
  ## calls (`wallClockStopRecord` + `applyWallClockStop`).
  var config = variantConfig(rounds)
  config.maxTicks = ticks
  config.maxGames = rounds.len
  config.turnSpacingMs = 0
  config.startWaitTicks = 0
  config.gameOverTicks = 24
  if wallClockBudgetSeconds > 0:
    config.wallClockBudgetSeconds = wallClockBudgetSeconds
  ## The sim is NOT started here: the seats join on a LOBBY tick and
  ## `stepLobby` starts the round inside the step, exactly as the server does,
  ## so the replayed sim reaches Playing on the same tick from the same
  ## recorded joins.
  var sim = initSimServer(config)
  let path = getTempDir() / ("pw-test-" & $getCurrentProcessId() & "-" &
    $wallClockBudgetSeconds & ".bitreplay")
  var writer = openReplayWriter(path, config.configJson())
  for seat in 0 ..< FixtureSeats:
    sim.seatNames[seat] = NonAsciiLabel & "-" & $seat
    sim.seatPolicyKind[seat] = "scripted"
  var
    ctl = initControlState(sim)
    orders = newSeq[CogOrder](4)
    have = false
    inputs = newSeq[InputState](sim.players.len)
    prev = newSeq[InputState](sim.players.len)
    played = 0
    records = 0
    deadlineHit = false
  while played < rounds.len:
    ## The engine's hard stop, checked at the TOP of the iteration exactly as
    ## the server checks it: record the stop first, then apply it, so the
    ## record sits at this tick's time — where playback re-applies it, before
    ## the same tick's step.
    if wallClockBudgetSeconds > 0 and not deadlineHit and
        sim.tickCount div TargetFps >= config.wallClockBudgetSeconds:
      deadlineHit = true
      writer.writeChat(tickTime(sim.tickCount), 0, sim.wallClockStopRecord())
      sim.applyWallClockStop()
      inc records
    if sim.phase == Lobby and sim.players.len < FixtureSeats:
      ## The SIM cleared the roster (resetToLobby, inside the step) and
      ## advanced the round; the seats rejoin exactly as the server's squad
      ## construction does — on a LOBBY tick, before it is stepped, so the
      ## recorded join lands on the same tick the live sim applied it and the
      ## replay re-derives the whole switch.
      for seat in 0 ..< FixtureSeats:
        discard sim.addPlayer(
          config.slots[seat].name, seat, config.slots[seat].token)
        writer.writeJoin(tickTime(sim.tickCount), seat,
          config.slots[seat].name, seat, config.slots[seat].token)
        while writer.lastMasks.len < sim.players.len:
          writer.lastMasks.add(0)
        writer.writeChat(tickTime(sim.tickCount), seat, registerRecord(
          seat, sim.cogAlias(seat), teamText(sim.players[seat].team),
          NonAsciiLabel, "scripted", "drifter"))
        inc records
      inputs = newSeq[InputState](sim.players.len)
      prev = newSeq[InputState](sim.players.len)
      ctl = initControlState(sim)
      have = false
    if sim.phase == Playing:
      let turn = sim.gameTicksElapsed() div config.turnTicks
      if sim.gameTicksElapsed() mod config.turnTicks == 0:
        if turn == 0:
          writer.writeChat(tickTime(sim.tickCount), 0, roundcardRecord(sim))
          inc records
        for seat in 0 ..< 4:
          var directive = scriptedDirective(ctl, sim, blDrifter, @[seat])
          ## A non-ASCII note on every seat, so the strict-UTF-8 path is real.
          directive.note = NonAsciiNote
          orders[seat] = directive.orders[0]
          sim.installSymbol(seat, orders[seat].symbol, turn)
          let record = directive.boundedDirectiveRecord(
            sim.roundIndex + 1, turn, seat, $sim.mode, sim.cogAlias(seat),
            roleName(sim.mode, sim.roleIndex[seat]))
          check record.runeLen <= MaxDirectiveRunes
          writer.writeChat(tickTime(sim.tickCount), seat, record)
          sim.pushFeedDirective(record)
          inc records
        have = true
      ctl.observeEnemies(sim)
      if have:
        for seat in 0 ..< 4:
          inputs[seat] = decodeInputMask(
            ctl.compileMask(sim, orders[seat], seat))
    else:
      for seat in 0 ..< inputs.len:
        inputs[seat] = InputState()
    for seat in 0 ..< sim.players.len:
      writer.writeInputMaskChange(
        tickTime(sim.tickCount), seat, encodeInputMask(inputs[seat]))
    let before = sim.phase
    sim.step(inputs, prev)
    prev = inputs
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    if deadlineHit:
      ## The stop's own tick is recorded and hashed like any other; the
      ## episode ends here, as the server's `quitAfterFrame` ends it.
      break
    if before != GameOver and sim.phase == GameOver:
      inc played
      if played >= rounds.len:
        break

  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord(sim))
  inc records
  writer.closeReplayWriter()
  (path, sim, records)

suite "the replay":

  var episode = recordEpisode(
    @[modeSpread, modeDeceive, modeCrypto, modeTag], 540)

  test "the episode wrote a COWLDMPE replay and a results document":
    check fileExists(episode.path)
    let bytes = readFile(episode.path)
    check bytes.len > 4096
    check bytes.startsWith("COWLDMPE")
    check "particle-worlds" in bytes[0 ..< 64]
    check episode.sim.roundLog.len == 4
    let results = parseJson(episode.sim.particleResultsJson())
    check results["reason"].getStr() in
      [ReasonComplete, ReasonDeadline, ReasonFault]
    check results["roundsPlayed"].getInt() == 4
    check results["names"].len == FixtureSeats

  test "parseReplayBytes accepts it and re-simulating reproduces EVERY hash":
    let data = parseReplayBytes(readFile(episode.path))
    check data.hashes.len > 0
    var initialized = initReplayRuntime(
      data, mismatchQuit = false, gameEventLoggingEnabled = false)
    var
      game = move(initialized.sim)
      player = move(initialized.player)
      tracker = move(initialized.tracker)
    ## The landmark draw, the colour permutation, the role cycle and the key
    ## are all RE-DERIVED here from the seeded RNG in the config: nothing in
    ## the record stream pins them, so a divergence in any of them shows up as
    ## a hash mismatch.
    var frames = 0
    while frames < data.hashes.len + 64:
      discard player.advanceReplayFrame(game, tracker, @[], @[])
      inc frames
      if player.hashMismatchTick >= 0:
        break
      if game.tickCount >= int(data.hashes[^1].tick):
        break
    if player.hashMismatchTick >= 0:
      echo "MISMATCH at tick ", player.hashMismatchTick,
        " simTick=", game.tickCount, " phase=", game.phase,
        " round=", game.roundIndex, " mode=", game.mode,
        " players=", game.players.len
    check player.hashMismatchTick == -1
    check game.tickCount >= int(data.hashes[^1].tick) - 1
    ## And the re-derived round log matches the recorded one.
    check game.landmarks.len == LandmarkCount

  ## The other ending the design accepts: the engine's wall-clock stop
  ## (`reason: deadline`). It is the one end path that mutates hashed state
  ## from OUTSIDE the step, so it is the one that needs the recorded `stop`
  ## record to re-derive.
  var deadline = recordEpisode(
    @[modeSpread, modeDeceive, modeCrypto, modeTag], 540,
    wallClockBudgetSeconds = 10)

  test "a DEADLINE-ended episode re-derives frame by frame, stop tick included":
    ## The recording: the stop banked the round in progress and finished the
    ## game mid-round, from outside the step.
    check deadline.sim.phase == GameOver
    check deadline.sim.endReason == ReasonDeadline
    check deadline.sim.endRule == EndRuleWallClock
    check deadline.sim.roundLog.len == 1
    check deadline.sim.roundLog[^1].endRule == EndRuleWallClock
    check deadline.sim.roundLog[^1].ticks < 540      ## cut short, not full time
    let recorded = parseJson(deadline.sim.particleResultsJson())
    check recorded["reason"].getStr() == ReasonDeadline
    check recorded["endRule"].getStr() == EndRuleWallClock
    check recorded["roundsPlayed"].getInt() == 1

    ## Exactly one `stop` record rides the stream.
    let bytes = readFile(deadline.path)
    var stops = 0
    var at = 0
    while true:
      at = bytes.find("{\"k\":\"stop\"", at)
      if at < 0:
        break
      inc stops
      at = at + 1
    check stops == 1

    ## Playback re-derives it: EVERY recorded hash, the stop tick's included.
    let data = parseReplayBytes(bytes)
    check data.hashes.len > 0
    var initialized = initReplayRuntime(
      data, mismatchQuit = false, gameEventLoggingEnabled = false)
    var
      game = move(initialized.sim)
      player = move(initialized.player)
      tracker = move(initialized.tracker)
    var frames = 0
    while frames < data.hashes.len + 64:
      discard player.advanceReplayFrame(game, tracker, @[], @[])
      inc frames
      if player.hashMismatchTick >= 0:
        break
      if game.tickCount >= int(data.hashes[^1].tick):
        break
    if player.hashMismatchTick >= 0:
      echo "DEADLINE MISMATCH at tick ", player.hashMismatchTick,
        " simTick=", game.tickCount, " phase=", game.phase,
        " roundsPlayed=", game.roundsPlayed
    check player.hashMismatchTick == -1
    check game.tickCount >= int(data.hashes[^1].tick) - 1
    ## And it ENDS where the recording ended — a replay that quietly stayed
    ## `Playing` would pass the hash check above and still show no ending.
    check game.phase == GameOver
    check game.winner == deadline.sim.winner
    check game.isDraw == deadline.sim.isDraw
    check game.roundsPlayed == deadline.sim.roundsPlayed
    check game.roundLog.len == deadline.sim.roundLog.len
    for seat in 0 ..< 4:
      check game.roundLog[^1].permille[seat] ==
        deadline.sim.roundLog[^1].permille[seat]
    let rederived = parseJson(game.particleResultsJson())
    check rederived["reason"].getStr() == ReasonDeadline
    check rederived["endRule"].getStr() == EndRuleWallClock
    check rederived["roundsPlayed"].getInt() ==
      recorded["roundsPlayed"].getInt()
    check rederived["roundScores"] == recorded["roundScores"]
    check rederived["scores"] == recorded["scores"]
    check rederived["roundEndRules"] == recorded["roundEndRules"]

  test "the record stream carries the whole vocabulary":
    let bytes = readFile(episode.path)

    var counts = {
      "roundcard": 0, "register": 0, "directive": 0, "result": 0}.toTable
    var i = 0
    while true:
      i = bytes.find("{\"k\":", i)
      if i < 0:
        break
      let stop = bytes.find('}', i)
      if stop < 0:
        break
      for key in counts.keys:
        if ("\"" & key & "\"") in bytes[i .. min(bytes.high, i + 40)]:
          counts[key] = counts[key] + 1
      i = i + 1
    check counts["roundcard"] == 4
    check counts["register"] == 4 * 4     ## re-registered on every round switch
    check counts["directive"] >= 4
    check counts["result"] == 1

  test "the derived event stream carries every kind particle worlds emits":
    var config = variantConfig(@[modeSpread, modeDeceive, modeCrypto, modeTag])
    config.maxTicks = 540
    config.startWaitTicks = 0
    config.gameOverTicks = 24
    var sim = seatedSim(config)
    sim.collectEvents = true
    var
      ctl = initControlState(sim)
      orders = newSeq[CogOrder](4)
      inputs = newSeq[InputState](sim.players.len)
      have = false
      played = 0
      tracker = initBroadcastTracker()
      beats: seq[string]
      kinds: seq[string]
    while played < 4:
      if sim.phase == Lobby and sim.players.len < FixtureSeats:
        for seat in 0 ..< FixtureSeats:
          discard sim.addPlayer(
            config.slots[seat].name, seat, config.slots[seat].token)
        inputs = newSeq[InputState](sim.players.len)
        ctl = initControlState(sim)
        have = false
      if sim.phase == Playing:
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          for seat in 0 ..< 4:
            let directive = scriptedDirective(ctl, sim, blDrifter, @[seat])
            orders[seat] = directive.orders[0]
            sim.installSymbol(seat, orders[seat].symbol,
              sim.gameTicksElapsed() div config.turnTicks)
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
      let stepEventsJson = newJArray()
      sim.stepEvents(tracker, stepEventsJson)
      for event in stepEventsJson:
        let kind = event["k"].getStr()
        if kind notin kinds:
          kinds.add(kind)
        if kind in ["roundstart", "firstword", "onpoint", "tag", "roundover"]:
          if kind notin beats:
            beats.add(kind)
      if before != GameOver and sim.phase == GameOver:
        inc played
        if played >= 4:
          break

    echo "derived kinds: ", kinds
    for required in ["roundstart", "word", "firstword", "bump", "decode",
                     "roundover"]:
      check required in kinds
    ## `tag` fires when a pursuer really touches the evader, which a `drifter`
    ## pack does not reliably manage against a faster evader inside 540 ticks
    ## (that is the point of the mode). Its detector is exercised directly.
    block tagDetector:
      var tagSim = seatedSim(fixtureConfig(@[modeTag]))
      let evader = tagSim.seatWithRole(0)
      var pursuer = -1
      for seat in 0 ..< 4:
        if seat != evader:
          pursuer = seat
          break
      var tagTracker = initBroadcastTracker()
      let warm = newJArray()
      tagSim.stepEvents(tagTracker, warm)        ## initialise: no contact yet
      tagSim.stepEvents(tagTracker, warm)
      tagSim.players[pursuer].x = tagSim.players[evader].x + 4
      tagSim.players[pursuer].y = tagSim.players[evader].y
      let tagged = tagSim.resolveTags()
      check pursuer in tagged
      check tagSim.tagTicks == 1
      check tagSim.tagCredit[pursuer] == 1
      check tagSim.tagContact[pursuer]
      let beat = newJArray()
      tagSim.stepEvents(tagTracker, beat)
      var sawTag = false
      for event in beat:
        if event["k"].getStr() == "tag":
          sawTag = true
          check event["alias"].getStr() == tagSim.cogAlias(pursuer)
      check sawTag
    ## `onpoint` fires the first time a mobile agent reaches the round's GOAL,
    ## which a drifter pack manages only by luck inside 540 ticks -- so, like
    ## `tag`, its detector is exercised directly rather than left unasserted.
    block onPointDetector:
      var goalSim = seatedSim(fixtureConfig(@[modeCrypto]))
      check goalSim.goalLandmark >= 0
      var mover = -1
      for seat in 0 ..< 4:
        if not goalSim.isAnchored(seat):
          mover = seat
          break
      check mover >= 0
      var goalTracker = initBroadcastTracker()
      let warm = newJArray()
      goalSim.stepEvents(goalTracker, warm)        ## initialise the deltas
      goalSim.onPointDone[mover] = false           ## nobody has arrived yet
      goalSim.stepEvents(goalTracker, warm)        ## and the tracker agrees
      let (gx, gy) = goalSim.markCentre(goalSim.goalLandmark)
      goalSim.players[mover].x = gx
      goalSim.players[mover].y = gy
      let crossings = goalSim.updateBeliefs()
      check goalSim.onPointDone[mover]
      var announced = false
      for point in crossings.onPoints:
        if point.seat == mover:
          announced = true
      check announced
      let arrival = newJArray()
      goalSim.stepEvents(goalTracker, arrival)
      var sawOnPoint = false
      for event in arrival:
        if event["k"].getStr() == "onpoint":
          sawOnPoint = true
          check event["alias"].getStr() == goalSim.cogAlias(mover)
          check event["mark"].getInt() == goalSim.goalLandmark
      check sawOnPoint
    ## And the tier-2 stream keeps its mandatory trailing summary row.
    let jsonl = eventsJsonl(sim.events, sim.tickCount)
    let lines = jsonl.strip().splitLines()
    check lines.len >= 2
    let summary = parseJson(lines[^1])
    check summary["type"].getStr() == "summary"
    check summary["gameVersion"].getStr() == GameVersion
    check summary["ticks"].getInt() == sim.tickCount
    var simKinds: seq[string]
    for line in lines[0 ..< lines.high]:
      let kind = parseJson(line)["kind"].getStr()
      if kind notin simKinds:
        simKinds.add(kind)
    echo "sim event kinds: ", simKinds
    for required in ["bump", "decode", "roundover"]:
      check required in simKinds
    ## The kinds the game CANNOT emit never appear.
    for banned in ["shot", "hit", "kill", "capture", "hill_flip", "paint_tiles"]:
      check banned notin simKinds

  test "at least one non-silent symbol reaches the replay":
    let python = findExe("python3")
    check python.len > 0
    let summaryText = execProcess(
      python, args = ["tools/replay_summary.py", episode.path],
      env = nil, workingDir = repoRoot(), options = {})
    ## STRICT UTF-8: the summary must parse as JSON decoded from UTF-8 bytes,
    ## with the non-ASCII policy label and note intact.
    let summary = parseJson(summaryText)
    check summaryText.validateUtf8() == -1
    check summary["protocol"].getStr() == "particle-worlds/v1"
    check summary["gameVersion"].getStr() == GameVersion
    check summary["aliases"].len == FixtureSeats
    check summary["rounds"].len == 4
    var nonSilent = 0
    for entry in summary["symbols"]:
      if entry["symbol"].getStr() != SymbolSilence:
        inc nonSilent
    check nonSilent > 0
    check summary["results"]["roundsPlayed"].getInt() == 4
    check summary["results"]["reason"].getStr() == ReasonComplete
    var sawNonAscii = false
    for record in summary["directives"]:
      check record["note"].getStr().validateUtf8() == -1
      if NonAsciiNote in record["note"].getStr():
        sawNonAscii = true
    check sawNonAscii
    ## ONE directive per seat per turn -- the design's stream spec, asserted as
    ## a per-(round, turn) group rather than a floor over the whole episode.
    var perTurn = initCountTable[string]()
    for record in summary["directives"]:
      perTurn.inc($record["round"].getInt() & ":" & $record["turn"].getInt())
    check perTurn.len >= 4              ## at least one turn in every round
    for key, count in perTurn:
      if count != FixtureSeats:
        echo "turn ", key, " carries ", count, " directives"
      check count == FixtureSeats
    ## The embedded config JSON decodes strictly too.
    check summary["seed"].getInt() == FixtureSeed

  test "every directive record is <= MaxDirectiveRunes":
    let bytes = readFile(episode.path)
    var i = 0
    var seen = 0
    while true:
      i = bytes.find("{\"k\":\"directive\"", i)
      if i < 0:
        break
      var depth = 0
      var stop = i
      for j in i ..< bytes.len:
        if bytes[j] == '{': inc depth
        elif bytes[j] == '}':
          dec depth
          if depth == 0:
            stop = j
            break
      let record = bytes[i .. stop]
      check record.runeLen <= MaxDirectiveRunes
      check record.validateUtf8() == -1
      inc seen
      i = stop + 1
    check seen >= 4

  test "the recorded replay stays well under a megabyte":
    check getFileSize(episode.path) < 1_000_000

  test "cleanup":
    removeFile(episode.path)
    check not fileExists(episode.path)
    removeFile(deadline.path)
    check not fileExists(deadline.path)
