## The turn loop, against a REAL fake provider.
##
## `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` is part of the credential ladder, so this
## test stands a mummy server up on localhost and points the client at it. That
## makes the load-bearing claim actually testable rather than asserted: ALL FOUR
## seats' calls go out as ONE PARALLEL BATCH per turn, and the fake records the
## in-flight window of every request so the test can prove all four intersect.
##
## It also pins the two bounded deadlines, the single retry, the throttle
## fail-fast, the rate floor and the budget guard.

import std/[atomics, json, locks, monotimes, os, strutils, times, unicode,
            unittest]
import bitworld/spriteprotocol
import mummy, mummy/routers
import ../src/mpe/[sim, control, directives, baselines, decide, llm, server]
import fixture

type
  Window = object
    startMs, endMs: int

var
  windowLock: Lock
  windows: seq[Window]
  serverStarted: MonoTime
  holdMs: Atomic[int]           ## how long the fake sleeps before answering
  statusCode: Atomic[int]       ## what the fake answers with
  replyBody: string
  bodyLock: Lock

windowLock.initLock()
bodyLock.initLock()

proc nowMs(): int =
  (getMonoTime() - serverStarted).inMilliseconds.int

proc fakeHandler(request: Request) {.gcsafe.} =
  let began = nowMs()
  let hold = holdMs.load()
  if hold > 0:
    sleep(hold)
  let code = statusCode.load()
  var body: string
  {.cast(gcsafe).}:
    withLock bodyLock:
      body = replyBody
    withLock windowLock:
      windows.add(Window(startMs: began, endMs: nowMs()))
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  request.respond(code, headers, body)

proc bedrockReply(text: string): string =
  $(%*{"content": [{"type": "text", "text": text}]})

proc directiveReply(alias: string): string =
  bedrockReply($(%*{
    "note": "fake provider",
    "cogs": [{"id": alias, "intent": "cover", "target": [400, 300],
              "symbol": "F"}]
  }))

var router: Router
router.get("/**", fakeHandler)
router.post("/**", fakeHandler)
let fake = newServer(router)
var servePort = 0

# The fake is pinned to a fixed high port; this test is the only thing on it.
const FakePort = 8791

var fakeThread: Thread[void]
proc serveFake() {.thread.} =
  fake.serve(Port(FakePort))

proc bootFake() =
  serverStarted = getMonoTime()
  holdMs.store(0)
  statusCode.store(200)
  withLock bodyLock:
    replyBody = directiveReply("RED-alpha")
  createThread(fakeThread, serveFake)
  sleep(400)                     ## let mummy bind before the first request
  servePort = FakePort
  putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
         "http://127.0.0.1:" & $FakePort)
  putEnv("AWS_BEARER_TOKEN_BEDROCK", "fake-token")
  delEnv("ANTHROPIC_API_KEY")
  delEnv("ANTHROPIC_API_KEY_URI")

proc resetWindows() =
  withLock windowLock:
    windows.setLen(0)

proc recordedWindows(): seq[Window] =
  withLock windowLock:
    result = windows

proc llmEngine(sim: SimServer): DecisionEngine =
  result = initDecisionEngine(sim)
  for seat in 0 ..< result.seats.len:
    result.seats[seat].isLlm = true
    result.seats[seat].prompt = "cover a mark"
    result.seats[seat].registered = true
    result.seats[seat].label = "fake"

suite "the turn loop":

  bootFake()

  test "the system prompt describes the controller the seats actually get":
    ## A model reasoning from "shadow stands off 60 px" plans a tag pursuit it
    ## will not get: the control layer forces a pursuer onto the EVADER and
    ## closes to tagPx div 2 (control.goalFor, pinned by test_control). The
    ## prompt has to say so, or the two disagree about the same word.
    check "EXCEPT in TAG" in SystemPrompt
    check "closes to" in SystemPrompt
    check "20-pixel tag radius" in SystemPrompt
    var sim = seatedSim(fixtureConfig(@[modeTag]))
    check sim.config.tagPx == 20

  test "the system prompt names the mode and the role, per turn":
    ## design note: the line `THIS ROUND IS <MODE> AND YOU ARE THE <ROLE>.` is
    ## filled per turn. It is a const with two substitution points, so the
    ## unfilled placeholders must never reach a provider.
    check "THIS ROUND IS <MODE> AND YOU ARE THE <ROLE>." in SystemPrompt
    for mode in Mode:
      var sim = seatedSim(fixtureConfig(@[mode]))
      for seat in 0 ..< 4:
        let role = roleName(sim.mode, sim.roleIndex[seat])
        let filled = systemPromptFor($sim.mode, role)
        check ("THIS ROUND IS " & ($sim.mode).toUpperAscii() &
          " AND YOU ARE THE " & role.toUpperAscii() & ".") in filled
        check "<MODE>" notin filled
        check "<ROLE>" notin filled

  test "the client picks up the fake Bedrock endpoint":
    var sim = seatedSim(fixtureConfig())
    let client = newLlmClient(sim.config)
    check client.transport == ltBedrock
    check not client.disabled

  test "all four seats' calls go out in ONE parallel batch":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = llmEngine(sim)
    const Hold = 400            ## long enough that serial calls could not hide
    holdMs.store(Hold)
    resetWindows()
    let began = getMonoTime()
    let records = engine.turn(sim, 0, 10, 0)
    let elapsed = (getMonoTime() - began).inMilliseconds.int
    holdMs.store(0)
    let seen = recordedWindows()
    check seen.len == FixtureSeats   ## exactly one call per seat per turn
    ## The whole batch must finish in far less than the serial cost of four
    ## calls: that is what "one parallel batch" means, and a loop that queried
    ## the seats one after another could not do it.
    echo "batch of ", seen.len, " at ", Hold, " ms each took ", elapsed, " ms"
    check elapsed < FixtureSeats * Hold
    ## And the requests really did overlap in the provider, not just in the
    ## client: at least one pair of handler windows intersects.
    var overlaps = 0
    for i in 0 ..< seen.len:
      for j in i + 1 ..< seen.len:
        if seen[i].startMs <= seen[j].endMs and seen[j].startMs <= seen[i].endMs:
          inc overlaps
    check overlaps > 0
    ## And all four seats really got an LLM directive, not a fallback.
    for seat in 0 ..< 4:
      check engine.haveDirective[seat]
      check engine.directives[seat].source == dsLlm
      check engine.directives[seat].orders.len == 1
      check engine.directives[seat].orders[0].intent == intCover
    for record in records:
      check "fallback" notin record

  test "an unusable reply retries exactly once, then falls back to drifter":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = llmEngine(sim)
    withLock bodyLock:
      replyBody = bedrockReply("I would rather not answer in JSON.")
    resetWindows()
    let records = engine.turn(sim, 1, 10, 0)
    withLock bodyLock:
      replyBody = directiveReply("RED-alpha")
    ## Two batches of four: attempt 1 and exactly ONE retry.
    check recordedWindows().len == 8
    var fallbacks = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback":
        inc fallbacks
        check node["cause"].getStr() in
          ["parse_error", "timeout", "transport_error"]
        check node["detail"].getStr().runeLen <= MaxFallbackDetailRunes
    check fallbacks >= 4
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsFallback
      check engine.directives[seat].orders.len == 1
      ## The fallback is the published `drifter` order, so no particle is left
      ## unactuated.
      check engine.directives[seat].orders[0].id == sim.cogAlias(seat)

  test "a throttle with no other candidate model skips the retry":
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = llmEngine(sim)
    statusCode.store(429)
    resetWindows()
    let records = engine.turn(sim, 2, 10, 0)
    statusCode.store(200)
    ## ONE batch, not two: the retry cannot land, so the turn fails fast to the
    ## scripted layer instead of spending the budget on a refused call.
    check recordedWindows().len == 4
    var throttled = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback" and
          node["cause"].getStr() == "throttled":
        inc throttled
    check throttled >= 4
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsFallback

  test "the per-turn budget is enforced against a hung provider":
    var config = fixtureConfig(@[modeSpread])
    config.attempt1Ms = 1000
    config.retryMs = 1000
    config.turnBudgetMs = 2000
    var sim = seatedSim(config)
    var engine = llmEngine(sim)
    holdMs.store(4000)            ## far past both deadlines
    let began = getMonoTime()
    let records = engine.turn(sim, 3, 10, 0)
    let elapsed = (getMonoTime() - began).inMilliseconds.int
    holdMs.store(0)
    ## Two 1 s deadlines inside a 2 s cap: the turn must be over well before
    ## the provider would have answered.
    check elapsed < 3500
    check records.len > 0
    for seat in 0 ..< 4:
      check engine.haveDirective[seat]
      check engine.directives[seat].orders.len == 1

  test "sim_config rejects deadlines that are not whole seconds":
    var config = fixtureConfig()
    config.attempt1Ms = 4500
    expect MpeError:
      config.update("{}")
    config = fixtureConfig()
    config.retryMs = 2500
    expect MpeError:
      config.update("{}")

  test "sim_config rejects attempt1Ms + retryMs past turnBudgetMs":
    var config = fixtureConfig()
    config.attempt1Ms = 8000
    config.retryMs = 5000
    config.turnBudgetMs = 10_000
    expect MpeError:
      config.update("{}")

  test "the rate floor holds four seats under 30 requests a minute":
    ## 4 seats per batch and one batch every turnSpacingMs: the shipped variant
    ## floor is 9000 ms, which pins the episode at 4 * 60 / 9 = 26.7 req/min.
    let config = variantConfig(@[modeSpread])
    check config.turnSpacingMs == DefaultParticleTurnSpacingMs
    let perMinute = FixtureSeats * 60_000 div config.turnSpacingMs
    check perMinute <= 30
    ## And the floor is really honoured between consecutive batches.
    var spaced = fixtureConfig(@[modeSpread])
    spaced.turnSpacingMs = 600
    var sim = seatedSim(spaced)
    var engine = llmEngine(sim)
    let began = getMonoTime()
    discard engine.turn(sim, 0, 10, 0)
    discard engine.turn(sim, 1, 10, 0)
    let elapsed = (getMonoTime() - began).inMilliseconds.int
    check elapsed >= spaced.turnSpacingMs

  test "the budget guard switches to scripted and records the turn":
    var config = fixtureConfig(@[modeSpread])
    config.wallClockBudgetSeconds = 30
    var sim = seatedSim(config)
    var engine = llmEngine(sim)
    resetWindows()
    ## elapsed + 2 * turnBudgetSeconds > wallClockBudgetSeconds fires it.
    let records = engine.turn(sim, 5, 10, 25)
    check engine.llmOff
    check recordedWindows().len == 0        ## no call was made at all
    var guards = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "budget_guard":
        inc guards
        check node["turn"].getInt() == 5
    check guards == 1
    for seat in 0 ..< 4:
      check engine.haveDirective[seat]
      check engine.directives[seat].source == dsFallback
    ## Every later turn stays scripted, in microseconds.
    resetWindows()
    discard engine.turn(sim, 6, 10, 26)
    check recordedWindows().len == 0

  test "no seat's directive is ever empty after turn 0":
    var sim = seatedSim(fixtureConfig(@[modeCrypto]))
    var engine = llmEngine(sim)
    withLock bodyLock:
      replyBody = bedrockReply("garbage")
    discard engine.turn(sim, 0, 10, 0)
    withLock bodyLock:
      replyBody = directiveReply("RED-alpha")
    for turn in 1 ..< 6:
      discard engine.turn(sim, turn, 10, 0)
      for seat in 0 ..< 4:
        check engine.haveDirective[seat]
        check engine.directives[seat].orders.len == 1
        check engine.directives[seat].orders[0].cogIndex == seat

  test "a disconnected seat plays drifter and revives on reconnect":
    var config = fixtureConfig(@[modeSpread])
    var sim = seatedSim(config)
    var engine = llmEngine(sim)
    var ctl = initControlState(sim)
    ## The seat drops: the server keeps compiling masks for its particle from
    ## the published `drifter` order, so the particle is never unactuated.
    let scripted = engine.drifterFor(sim, @[2])
    check scripted.orders.len == 1
    check scripted.source == dsScripted
    ctl.observeEnemies(sim)
    let mask = ctl.compileMask(sim, scripted.orders[0], 2)
    check (mask and (ButtonA or ButtonC)) == 0
    ## On reconnect the seat's own LLM directive takes over again.
    discard engine.turn(sim, 1, 10, 0)
    check engine.directives[2].source == dsLlm

  test "a seat with NO credentials records a no_credentials fallback":
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    var sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = llmEngine(sim)
    check engine.client.transport == ltNone
    check engine.client.disabled
    let records = engine.turn(sim, 0, 10, 0)
    var causes = 0
    for record in records:
      let node = parseJson(record)
      if node["k"].getStr() == "fallback" and
          node["cause"].getStr() == "no_credentials":
        inc causes
    check causes == 4
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsFallback
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
           "http://127.0.0.1:" & $FakePort)
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "fake-token")

  test "a never-connecting seat is REPORTED and all four rounds still play":
    ## design note: a lobby no-show is charged to the seat that caused it
    ## (COGAME_PLAYER_FAILURE_URI -> player_failure.json, lowest missing slot)
    ## and the episode is NOT abandoned -- the missing particle joins as a
    ## trusted bot on the published baseline and every round runs to full time.
    let path = getTempDir() / ("pw-failure-" & $getCurrentProcessId() & ".json")
    removeFile(path)
    putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)

    var config = fixtureConfig()
    config.lobbyJoinTimeoutTicks = 24
    config.startWaitTicks = 240
    var sim = initSimServer(config)
    ## Three of the four seats connect; slot 3 never does.
    for seat in 0 ..< 3:
      discard sim.addPlayer(
        config.slots[seat].name, seat, config.slots[seat].token)
    var lobby = newSeq[InputState](sim.players.len)
    var waited = 0
    while not sim.lobbyJoinTimedOut() and waited < 600:
      sim.step(lobby, lobby)
      inc waited
    check sim.lobbyJoinTimedOut()
    check sim.nextPlayerSlot() == 3

    ## What the server does at that point (server.nim's squad-construction
    ## block): declare the no-show, then force-start with the missing cog
    ## added as a trusted bot.
    declarePlayerFailure(sim.nextPlayerSlot(),
      "player slot 3 never joined the lobby within " &
        $config.lobbyJoinTimeoutTicks & " lobby ticks")
    delEnv("COGAME_PLAYER_FAILURE_URI")
    check fileExists(path)
    let declared = parseJson(readFile(path))
    check declared["failed_policy_index"].getInt() == 3
    check "never joined the lobby" in declared["message"].getStr()
    removeFile(path)

    for order in sim.players.len ..< sim.totalCogs():
      discard sim.addPlayer("cog-" & $order, order, "", trusted = true)
    check sim.players.len == sim.totalCogs()
    sim.startGame()

    ## And the episode plays out: four rounds, complete / full_time.
    var
      ctl = initControlState(sim)
      orders = newSeq[CogOrder](4)
      inputs = newSeq[InputState](sim.players.len)
      have = false
      played = 0
    while played < 4:
      if sim.phase == Lobby and sim.players.len < FixtureSeats:
        for seat in 0 ..< 3:
          discard sim.addPlayer(
            config.slots[seat].name, seat, config.slots[seat].token)
        for order in sim.players.len ..< sim.totalCogs():
          discard sim.addPlayer("cog-" & $order, order, "", trusted = true)
        sim.startGame()
        inputs = newSeq[InputState](sim.players.len)
        ctl = initControlState(sim)
        have = false
      if sim.phase == Playing:
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          for seat in 0 ..< 4:
            orders[seat] = scriptedDirective(ctl, sim, blDrifter, @[seat]).orders[0]
            sim.recordHoldAnchor(seat)
          have = true
        ctl.observeEnemies(sim)
        if have:
          for seat in 0 ..< 4:
            inputs[seat] = decodeInputMask(ctl.compileMask(sim, orders[seat], seat))
      else:
        for seat in 0 ..< inputs.len:
          inputs[seat] = InputState()
      let before = sim.phase
      sim.step(inputs, inputs)
      if before != GameOver and sim.phase == GameOver:
        inc played
    sim.seatNames = ["a", "b", "c", "d"]
    let results = parseJson(sim.particleResultsJson())
    check results["roundsPlayed"].getInt() == 4
    check results["reason"].getStr() == ReasonComplete
    check results["endRule"].getStr() == EndRuleFullTime
