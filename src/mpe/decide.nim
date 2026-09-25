## The decision layer: the per-turn loop that asks both commanders what their
## squads do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (108 ticks = 4.5 s of sim time), 10
## turns per round, 40 per episode. At each turn the server builds ALL FOUR
## seats' private views and sends them as one batch to ordinary players.
## Particle worlds is a SIMULTANEOUS-decision game, so
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
  std/[json, math, monotimes, os, times],
  sim, control, directives, baselines

type
  BatchCall* = object
    seat*: int
    view*: string
    turn*: int
    retry*: bool

  BatchReply* = object
    ok*: bool
    action*: string
    cause*: string
    error*: string

  BatchFn* = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
    {.closure, gcsafe.}

  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `drifter`.
    isExternal*: bool
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    batch*: BatchFn
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    externalOff*: bool         ## the budget guard fired; scripted from here on
    records*: seq[string]      ## chat records queued for the replay writer

proc initDecisionEngine*(sim: SimServer): DecisionEngine =
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blDrifter
    result.seats[i].label = "drifter"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isExternal:
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
  ## `tag` scores from the contact counters at round end and never writes
  ## `roundAccum` (scoring.nim:132), so reading roundAccum told every seat in
  ## every tag round that its round score so far was 0.000 while the spectator
  ## frame showed the real number. The seat view computes it the way
  ## broadcast.nim:1052 does, from the same live term.
  let
    elapsed = max(1, sim.gameTicksElapsed())
    scoreSeat = min(max(0, seat), 3)
    soFar =
      if sim.mode == modeTag: sim.tagRoundPermille(scoreSeat, elapsed)
      else: clamp(int(sim.roundAccum[scoreSeat] div elapsed), 0, 1000)

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
  ## tools/replay_summary.py — the ONLY reader in the tree. Playback DROPS it
  ## (`replays.nim`'s chat branch keeps `directive` and the `stop` record and
  ## nothing else), so nothing cross-checks it against a re-derivation: the
  ## viewer re-derives all of these values from the seeded draw, and every one
  ## of them is in `gameHash`, so a divergence surfaces as a hash mismatch at
  ## the tick it happens rather than as a record comparison.
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
  ## The per-turn monotonic deadline. It clocks the CALLS, and it is (re)started
  ## below, after the rate floor's wait -- see the rate floor for why.
  var turnStart = getMonoTime()

  # --- budget guard: settle EARLY rather than overrun -----------------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, switch external calls off for the rest of the episode and finish on the
  # scripted layer (microseconds per turn), so the episode ends
  # complete/full_time instead of deadline.
  #
  # A full turn is the rate floor PLUS the calls: the floor holds batch STARTS
  # `turnSpacingMs` apart and the monotonic budget then clocks `turnBudgetMs`
  # of calls from the moment the wait ends, so the worst single turn costs
  # 9 s + 10 s = 19 s, not 10 s. Reserving 2 x 10 s left the last callable turn
  # ending ~2 s inside the 690 s stop; reserving 2 x 19 s makes the guard's
  # margin the one its expression claims.
  if not engine.externalOff:
    let turnSeconds =
      (sim.config.turnSpacingMs + sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.externalOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "particle-worlds: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isExternal and not engine.externalOff:
      open.add(seat)
    elif engine.seats[seat].isExternal:
      # A budget-skipped external seat counts as a fallback turn.
      var directive = engine.drifterFor(sim, sim.commandedCogs(seat))
      directive.source = dsFallback
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let cause = "budget_guard"
      result.add(fallbackRecord(roundIndex, turnIndex, seat, 1, cause,
        "the decision budget is exhausted; playing drifter"))
      echo "particle-worlds llm: seat ", seat, " falling back to drifter (", cause,
        ") on turn ", turnIndex
    else:
      var directive = engine.scriptedFor(
        sim, seat, engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true

  # --- the rate floor -------------------------------------------------------
  # Hold the start of player batches `turnSpacingMs` apart. The cert fixture
  # sets it to zero, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true
    # The rate floor is a WAIT, not work, so the per-turn budget starts HERE,
    # when the first batch of the turn does. It has to: `turnBudgetMs` is the
    # cap sim_config validates `attempt1Ms + retryMs` against (10 000 against
    # 6000 + 3000 on every shipped variant), and the floor is 9000 ms of the
    # same window. Clocking the sleep inside the budget left roughly 3.5 s of
    # it in steady state, so a turn whose attempt 1 TIMED OUT was already past
    # the deadline and broke out with a budget-exhausted record: the single
    # retry the acceptance checklist requires could never be issued at the
    # shipped settings. Batch STARTS are still held turnSpacingMs apart -- that
    # is what the rate floor promises the sidecar -- so a turn still costs at
    # most max(turnSpacingMs, turnBudgetMs) of wall clock and 40 turns still
    # settle far inside the 690 s engine stop.
    turnStart = engine.lastBatchStart

  # --- up to two PARALLEL batches ------------------------------------------
  ## ONE `fallback` record per seat per turn, written by the tail block below.
  ## Each failed attempt records WHY here instead of emitting its own record:
  ## `results.fallbackTurns` counts seat-turns, so a stream that carried two or
  ## three records for one seat-turn (and, on the budget-exhausted path, two
  ## records both stamped attempt 2 with different causes) made
  ## replay_summary.py's `fallbacks` disagree with it and phase 60 unable to
  ## read either. The record's `attempt` is now how many attempts the seat
  ## actually spent, 1 or 2, and its `cause` is the one that ended the turn.
  var
    lastCause = newSeq[string](engine.seats.len)
    lastDetail = newSeq[string](engine.seats.len)
    attemptsSpent = newSeq[int](engine.seats.len)
  var attempt = 0
  var failFast: seq[int]
  while open.len > 0 and attempt < 2:
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        lastCause[seat] = "timeout"
        lastDetail[seat] =
          "per-turn budget exhausted before attempt " & $(attempt + 1)
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var calls: seq[BatchCall]
    for seat in open:
      calls.add BatchCall(seat: seat,
        view: engine.seatViewJson(sim, seat, turnIndex, turnsPerRound),
        turn: turnIndex, retry: attempt > 0)
    let started = getMonoTime()
    let replies = engine.batch(calls, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let reply = replies[position]
        if not reply.ok:
          cause = if reply.cause.len > 0: reply.cause else: "transport_error"
          raise newException(ValueError, reply.error)
        let text = reply.action
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
        lastCause[seat] = cause
        lastDetail[seat] = error.msg
        attemptsSpent[seat] = attempt + 1
        echo "particle-worlds llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if attempt == 1:
      var retryable: seq[int]
      for seat in open:
        if lastCause[seat] in ["throttled", "no_credentials"]:
          failFast.add(seat)
        else:
          retryable.add(seat)
      open = retryable

  # --- anything still open plays drifter for this turn ---------------------
  open.add(failFast)
  for seat in open:
    var directive = engine.drifterFor(sim, sim.commandedCogs(seat))
    directive.source = dsFallback
    engine.directives[seat] = directive
    engine.haveDirective[seat] = true
    let cause = if lastCause[seat].len > 0: lastCause[seat] else: "timeout"
    let detail =
      if lastDetail[seat].len > 0: lastDetail[seat]
      else: "seat fell back to the drifter directive"
    ## The one authoritative record for this seat-turn: `attempt` is how many
    ## attempts it spent (1 when the retry never went out -- a throttle, a
    ## disabled client or an exhausted budget -- 2 when it did).
    result.add(fallbackRecord(roundIndex, turnIndex, seat,
      max(1, attemptsSpent[seat]), cause, detail))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "particle-worlds llm: seat ", seat, " falling back to drifter (", cause,
      ") on turn ", turnIndex
