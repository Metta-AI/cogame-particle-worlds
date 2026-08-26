## The decision layer: the per-turn loop that asks both commanders what their
## squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (108 ticks = 4.5 s of sim time), 10
## turns per round, 40 per episode. At each turn the server builds ALL FOUR
## seats' request bodies and issues them as ONE parallel batch
## (`curl.makeRequests`) — particle worlds is a SIMULTANEOUS-decision game, so
## querying seats one after another would quadruple the wall clock for no gain.
## One call per seat per turn; an episode is at most 160 calls, at most 4 in
## flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: attempt 1 gets
## `attempt1Ms`, the single retry gets `retryMs`, and the whole turn is
## wrapped in a monotonic `turnBudgetMs` deadline. A provider throttle with no
## other candidate model skips the retry outright (it cannot land) and fails
## fast to the scripted layer for that turn. On a second failure the seat
## plays the `drifter` scripted directive for that turn and a `fallback`
## record names the cause. No failure mode leaves a particle unactuated: the
## control layer always has a directive — this turn's, else last turn's, else
## `drifter`'s.

import
  std/[json, math, monotimes, os, strutils, times],
  curly,
  sim, control, directives, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `drifter`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.client = newLlmClient(sim.config)
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blDrifter
    result.seats[i].label = "drifter"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc secretJson(sim: SimServer, seat: int): JsonNode =
  ## The ONE mode-conditional block, and the whole entitlement matrix. A seat
  ## that is not entitled sees `null` — never an ABSENT key — so a model never
  ## has to distinguish "hidden" from "malformed".
  ## tests/test_observation.nim asserts this from both sides.
  result = %*{"goal": newJNull(), "goal_colour": newJNull(),
              "key": newJNull()}
  let role = sim.roleIndex[min(max(0, seat), 3)]
  case sim.mode
  of modeSpread, modeTag:
    discard                        ## nothing extra: there is no secret.
  of modeDeceive:
    if role != 0:                  ## the three good agents are told the goal
      result["goal"] = %sim.goalLandmark
      result["goal_colour"] = %MarkColourNames[max(0, sim.goalColour())]
    else:
      result["goal_is_one_of"] = %[0, 1, 2, 3]
  of modeCrypto:
    if role == 0:                  ## Alice sees the goal, its colour AND the key
      result["goal"] = %sim.goalLandmark
      result["goal_colour"] = %MarkColourNames[max(0, sim.goalColour())]
    if role == 0 or role == 1:     ## Alice and Bob share the key
      var key = newJArray()
      for colour in 0 ..< LandmarkCount:
        key.add(%[%symbolText(sim.keySymbols[colour]),
                  %MarkColourNames[colour]])
      result["key"] = key

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerRound: int
): string =
  ## Everything this seat may legitimately know, in map pixels, rounded to
  ## integers.
  ##
  ## Positions are FULLY OBSERVABLE — MPE is a fully observable environment,
  ## and hiding positions would add a search puzzle the idea never asks for and
  ## subtract the one it does ask for (inference from BEHAVIOUR and from
  ## SYMBOLS). What is hidden is the round's secret, the other seats' orders for
  ## the turn being decided, every seat's `note`, every PLAYER_PROMPT, every
  ## real policy name, the seed and the RNG state.
  let
    role = sim.roleIndex[min(max(0, seat), 3)]
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)
    (px, py) = sim.particleCentre(seat)
    (cx, cy) = centreOfField()

  var marks = newJArray()
  for i in 0 ..< sim.landmarks.len:
    marks.add(%*{
      "i": i,
      "pos": [sim.landmarks[i].x, sim.landmarks[i].y],
      "colour": MarkColourNames[sim.landmarks[i].colour],
      "r": sim.config.landmarkRadius
    })

  var agents = newJArray()
  for i in 0 ..< min(4, sim.players.len):
    let (ax, ay) = sim.particleCentre(i)
    agents.add(%*{
      "id": sim.cogAlias(i),
      "role": roleName(sim.mode, sim.roleIndex[i]),
      "anchored": sim.isAnchored(i),
      "pos": [ax, ay],
      "vel": [sim.players[i].velX, sim.players[i].velY],
      "colour": teamText(sim.players[i].team)
    })

  var radio = newJArray()
  for i in 0 ..< min(4, sim.players.len):
    radio.add(%*{
      "id": sim.cogAlias(i),
      "now": symbolText(sim.commSymbol[i]),
      "last": symbolText(sim.commPrev[i])
    })

  ## Public BEHAVIOUR: which mark each mobile agent is nearest and how long it
  ## has stayed there. This is the legitimate signal an eavesdropper tails and
  ## the listener must confound, so every seat gets it in every mode.
  var beliefs = newJArray()
  for i in 0 ..< min(4, sim.players.len):
    if sim.isAnchored(i):
      continue
    beliefs.add(%*{
      "id": sim.cogAlias(i),
      "nearest_mark": sim.nearestMark[i],
      "settled_ticks": sim.settledTicks[i]
    })

  var banked = newJArray()
  for entry in sim.roundLog:
    banked.add(%(entry.permille[min(max(0, seat), 3)].float / 1000.0))
  let
    elapsed = max(1, sim.gameTicksElapsed())
    ## `tag` does not accumulate per tick -- it scores from the contact
    ## counters (scoring.scoreTick's modeTag arm is `discard`) -- so reading
    ## `roundAccum` there reported 0.000 to every seat for all ten turns of the
    ## round. Same rule the spectator frame uses (broadcast.buildStateJson).
    soFar =
      if sim.mode == modeTag:
        sim.tagRoundPermille(min(max(0, seat), 3), elapsed)
      else:
        clamp(int(sim.roundAccum[min(max(0, seat), 3)] div elapsed), 0, 1000)

  var node = %*{
    "round": sim.roundIndex + 1,
    "of": max(1, sim.config.maxGames),
    "mode": $sim.mode,
    "turn": turnIndex,
    "turns": turnsPerRound,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "field": {"w": MapWidth, "h": MapHeight, "centre": [cx, cy]},
    "you": {
      "id": sim.cogAlias(seat),
      "role": roleName(sim.mode, role),
      "anchored": sim.isAnchored(seat),
      "pos": [px, py],
      "vel": [sim.players[seat].velX, sim.players[seat].velY],
      "speed_px_s": (abs(sim.players[seat].velX) + abs(sim.players[seat].velY)) *
        TargetFps div max(1, sim.config.motionScale),
      "accel_px_s2": sim.particleAccel(seat) * TargetFps * TargetFps div
        max(1, sim.config.motionScale),
      "max_px_s": sim.particleMaxSpeed(seat) * TargetFps div
        max(1, sim.config.motionScale)
    },
    "marks": marks,
    "agents": agents,
    "radio": radio,
    "secret": secretJson(sim, seat),
    "beliefs": beliefs,
    "score": {
      "this_round_so_far": soFar.float / 1000.0,
      "rounds_banked": banked,
      "episode_so_far": sim.episodePermille(seat).float / 1000.0
    }
  }
  case sim.mode
  of modeSpread:
    node["cover_pct"] = %(sim.coverPermille() div 10)
    node["bumps"] = %sim.bumps[min(max(0, seat), 3)]
  of modeTag:
    var contact = newJArray()
    for i in 0 ..< min(4, sim.players.len):
      contact.add(%sim.tagContact[i])
    node["contact"] = contact
    node["tag_ticks"] = %sim.tagTicks
  else:
    discard
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    node["your_last_directive"] = %engine.directives[seat].note
  else:
    node["your_last_directive"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  roundIndex, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "round": roundIndex,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, alias, colour, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "colour": colour,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc roundcardRecord*(sim: SimServer): string =
  ## The `roundcard` control record: the round's mode, its four public roles,
  ## its goal and colour, its key and its marks. A CONVENIENCE for
  ## tools/replay_summary.py and the feed — the viewer re-derives every one of
  ## these values from the seeded draw and cross-checks this record against its
  ## own derivation, so a divergence is visible rather than authoritative.
  var
    roles = newJArray()
    marks = newJArray()
  for seat in 0 ..< 4:
    roles.add(%roleName(sim.mode, sim.roleIndex[seat]))
  for mark in sim.landmarks:
    marks.add(%[%mark.x, %mark.y, %MarkColourNames[mark.colour]])
  var key: JsonNode = newJNull()
  if sim.mode == modeCrypto:
    key = newJArray()
    for colour in 0 ..< LandmarkCount:
      key.add(%[%symbolText(sim.keySymbols[colour]),
                %MarkColourNames[colour]])
  $(%*{
    "k": "roundcard",
    "round": sim.roundIndex + 1,
    "mode": $sim.mode,
    "roles": roles,
    "goal": sim.goalLandmark,
    "goal_colour": (
      if sim.goalColour() >= 0: %MarkColourNames[sim.goalColour()]
      else: newJNull()),
    "key": key,
    "marks": marks
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.playerResultsJson() & "}"

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(engine.ctl, sim, kind, sim.commandedCogs(seat))

proc drifterFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int]
): SquadDirective =
  ## The published `drifter` directive for an arbitrary particle set — the
  ## per-turn fallback, the driver of a no-show or disconnected seat, and the
  ## default for a seat that registered with neither field.
  scriptedDirective(engine.ctl, sim, blDrifter, cogs)

proc repairMissingOrders*(
  engine: DecisionEngine, sim: SimServer, seat: int,
  directive: var SquadDirective
) =
  ## Design §Reply schema, the `cogs` row: "extra entries dropped; a missing
  ## entry keeps LAST turn's directive, else `drifter`'s". The parser fills an
  ## unnamed particle with `go` at the field centre so no particle is ever left
  ## unactuated; that default is a floor, not the rule — a seat that names
  ## nothing usable meant to carry on, not to abandon its post and drift to the
  ## middle.
  var previous: seq[CogOrder]
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    previous = engine.directives[seat].orders
  var
    drifter: SquadDirective
    builtDrifter = false
  for order in directive.orders.mitems:
    if order.fromReply:
      continue
    var repaired = false
    for old in previous:
      if old.cogIndex == order.cogIndex:
        order = old                  ## last turn's directive for this cog
        repaired = true
        break
    if repaired:
      continue
    if not builtDrifter:
      drifter = engine.drifterFor(sim, sim.commandedCogs(seat))
      builtDrifter = true
    for fallback in drifter.orders:
      if fallback.cogIndex == order.cogIndex:
        order = fallback             ## else drifter's
        break

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerRound: int,
  elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal directive.
  let
    roundIndex = sim.roundIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  ## Throttle state is PER TURN: a daily-token 429 on turn k says nothing
  ## about turn k+1 (the sidecar's window may have rolled), so the flag is
  ## cleared here and only suppresses this turn's retry.
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch the LLM off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "particle-worlds: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's `fallback.cause` enum names both
      # reasons it happens (`no_credentials`, `budget_guard`). Recording it is
      # what makes the two countable: without this an LLM seat with no key
      # reported llmTurns 0 AND fallbackTurns 0, and replay_summary.py's
      # `fallbacks` was 0 for an episode in which nothing but fallbacks
      # happened. A seat that registered as SCRIPTED is not a fallback and
      # gets no record (which is why certification's two baseline seats write
      # none).
      var directive = engine.drifterFor(sim, sim.commandedCogs(seat))
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(roundIndex, turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing drifter"))
      echo "particle-worlds llm: seat ", seat, " falling back to drifter (", cause,
        ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE, and FOUR seats per
  # turn blow through it at any fast cadence. Hold the START of consecutive
  # batches `turnSpacingMs` apart, which pins the episode at
  # 4 x 60 / 9 = 26.7 req/min. The cert fixture sets it to 0, so offline runs
  # pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          roundIndex, turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var user = engine.seatViewJson(sim, seat, turnIndex, turnsPerRound)
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', with exactly " &
          "one \"cogs\" entry, for yourself.")
      let request = engine.client.requestFor(
        systemPromptFor($sim.mode, roleName(sim.mode, sim.roleIndex[min(seat, 3)])),
        userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS — and a config that is not a whole
    # number of seconds is therefore not the deadline it claims to be. 0.1.2
    # shipped `attempt1Ms: 4500` and really ran with 4 s against a sidecar
    # whose median call measured 4618 ms; every successful LLM directive in
    # that release reported a latency of 3999–4001 ms, i.e. it was the
    # deadline answering, not the model. sim_config now REJECTS a sub-second
    # value, so the floor below is an identity: 6000 -> 6 s, 3000 -> 3 s,
    # worst case 9 s inside the 10 s turnBudgetMs cap.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        let commanded = sim.commandedCogs(seat)
        var ids: seq[string]
        for cogIndex in commanded:
          ids.add(sim.cogAlias(cogIndex))
        let (fx, fy) = centreOfField()
        var directive = parseSquadDirective(
          extractJsonObject(text), ids, commanded,
          fx, fy, MapWidth - 1, MapHeight - 1)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.repairMissingOrders(sim, seat, directive)
        engine.directives[seat] = directive
        engine.haveDirective[seat] = true
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          ## Name the throttle for what it is. Reporting a 429 as
          ## `parse_error` is what made the hosted log unreadable: 205
          ## "falling back (parse_error)" lines for an episode whose only
          ## fault was a daily-token cap.
          cause = "throttled"
        result.add(fallbackRecord(
          roundIndex, turnIndex, seat, attempt + 1, cause, error.msg))
        echo "particle-worlds llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way: spend the rest of the turn on the scripted
      # layer instead of on a call that cannot land. Bounded, and recorded as
      # a `fallback` with cause `throttled` by the block below.
      echo "particle-worlds llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays drifter for this turn ---------------------
  for seat in open:
    var directive = engine.drifterFor(sim, sim.commandedCogs(seat))
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(roundIndex, turnIndex, seat, 2, cause,
      "seat fell back to the drifter directive"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "particle-worlds llm: seat ", seat, " falling back to drifter (", cause,
      ") on turn ", turnIndex
