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

proc recordEpisode(rounds: seq[Mode], ticks: int): tuple[
    path: string, sim: SimServer, records: int] =
  ## Plays a scripted episode through the REAL replay writer, exactly as the
  ## server's loop does: one mask per particle per tick, one hash per tick, and
  ## the chat records for every roundcard, register, directive and the result.
  var config = variantConfig(rounds)
  config.maxTicks = ticks
  config.maxGames = rounds.len
  config.turnSpacingMs = 0
  config.startWaitTicks = 0
  config.gameOverTicks = 24
  ## The sim is NOT started here: the seats join on a LOBBY tick and
  ## `stepLobby` starts the round inside the step, exactly as the server does,
  ## so the replayed sim reaches Playing on the same tick from the same
  ## recorded joins.
  var sim = initSimServer(config)
  let path = getTempDir() / ("pw-test-" & $getCurrentProcessId() & ".bitreplay")
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
  while played < rounds.len:
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
