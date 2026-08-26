## THE TWO NAME SPACES, asserted from both sides.
##
## Agents see anonymous cog aliases and nothing else — no policy address ever
## reaches a seat frame, a symbol bubble, an LLM message or a `directive`
## record. The BROADCAST stream, `roster[].name`, the DOM scorebug and
## `results.names` must carry the real names, because a spectator has to know
## who is playing.
##
## A sentinel address is used on both sides so a leak is a substring match, not
## a judgement call.

import std/[json, strutils, unittest]
import ../src/mpe/[sim, broadcast, control, directives, decide, llm]
import fixture

const Sentinel = "SENTINEL-POLICY-ADDRESS"

proc sentinelSim(mode: Mode): SimServer =
  var config = fixtureConfig(@[mode])
  for i in 0 ..< 4:
    config.slots[i].name = Sentinel & "-" & $i
  result = initSimServer(config)
  for i in 0 ..< 4:
    discard result.addPlayer(config.slots[i].name, i, config.slots[i].token)
  for seat in 0 ..< 4:
    result.seatNames[seat] = config.slots[seat].name
    result.seatPolicyKind[seat] = "llm"
  result.startGame()

suite "the two name spaces":

  test "a seat's view carries only aliases, never a policy address":
    for mode in Mode:
      var sim = sentinelSim(mode)
      var engine = initDecisionEngine(sim)
      for seat in 0 ..< 4:
        let text = engine.seatViewJson(sim, seat, 2, 10)
        check Sentinel notin text
        for other in 0 ..< 4:
          check sim.cogAlias(other) in text
        ## Only the four aliases, and nothing that looks like a real name.
        for alias in ["RED-alpha", "BLUE-alpha", "GREEN-alpha", "YELLOW-alpha"]:
          check alias in text

  test "neither LLM message carries a policy address or another seat's note":
    var sim = sentinelSim(modeCrypto)
    var engine = initDecisionEngine(sim)
    for seat in 0 ..< 4:
      engine.seats[seat].prompt = "OPERATOR-PROMPT-" & $seat
      engine.seats[seat].isLlm = true
      engine.directives[seat] = SquadDirective(
        note: "PRIVATE-NOTE-" & $seat, source: dsLlm,
        orders: @[CogOrder(cogIndex: seat, id: sim.cogAlias(seat),
                           intent: intHold, targetX: 1, targetY: 1)])
      engine.haveDirective[seat] = true
    check Sentinel notin SystemPrompt
    for seat in 0 ..< 4:
      let user = userMessage(
        engine.seats[seat].prompt,
        engine.seatViewJson(sim, seat, 2, 10))
      check Sentinel notin user
      check ("OPERATOR-PROMPT-" & $seat) in user       ## its own guidance
      for other in 0 ..< 4:
        if other != seat:
          check ("OPERATOR-PROMPT-" & $other) notin user
          check ("PRIVATE-NOTE-" & $other) notin user

  test "a directive record carries the ALIAS and never the address":
    var sim = sentinelSim(modeSpread)
    for seat in 0 ..< 4:
      let directive = SquadDirective(
        note: "cover four marks", source: dsScripted,
        orders: @[CogOrder(cogIndex: seat, id: sim.cogAlias(seat),
                           intent: intCover, targetX: 10, targetY: 10,
                           symbol: 1)])
      let record = directive.boundedDirectiveRecord(
        1, 0, seat, $sim.mode, sim.cogAlias(seat),
        roleName(sim.mode, sim.roleIndex[seat]))
      check Sentinel notin record
      check sim.cogAlias(seat) in record

  test "a register record carries the policy LABEL, never the prompt":
    let record = registerRecord(
      0, "RED-alpha", "red", "swarm", "llm", "drifter")
    check Sentinel notin record
    check "RED-alpha" in record
    check "swarm" in record
    let node = parseJson(record)
    check not node.hasKey("prompt")

  test "the BROADCAST stream, roster[].name and results.names DO carry it":
    var sim = sentinelSim(modeSpread)
    let frame = sim.buildStateJson(
      newJArray(), playing = true, speed = 1, maxTick = 240, looping = false,
      transportEnabled = true, mismatchTick = -1, povSlot = -1)
    check Sentinel in frame
    let state = parseJson(frame)
    var seen = 0
    for entry in state["roster"]:
      if Sentinel in entry["name"].getStr():
        inc seen
      ## And the alias rides alongside it, so the board can label anonymously.
      let alias = entry["alias"].getStr()
      check (alias.startsWith("RED") or alias.startsWith("BLUE") or
             alias.startsWith("GREEN") or alias.startsWith("YELLOW"))
    check seen == 4
    sim.roundAccum = [1000'i64, 1000, 1000, 1000]
    sim.bankRound(1, EndRuleFullTime)
    let results = parseJson(sim.particleResultsJson())
    for seat in 0 ..< 4:
      check Sentinel in results["names"][seat].getStr()
      check results["alias"][seat].getStr().endsWith("-alpha")

  test "the symbol bubble label is the anonymous identity, not the address":
    var sim = sentinelSim(modeSpread)
    for seat in 0 ..< 4:
      sim.installSymbol(seat, seat + 1, 0)
    ## The bubble label is built from teamText + IdentityNames, which is what
    ## `cogAlias` is built from too — never from `player.address`.
    for seat in 0 ..< 4:
      check IdentityNames[sim.cogIdentityIndex(seat)] == "alpha"
      check Sentinel notin sim.cogAlias(seat)

  test "the two-name-space rule holds for the SPECTATOR frame's own extras":
    var sim = sentinelSim(modeCrypto)
    let frame = parseJson(sim.buildStateJson(
      newJArray(), playing = true, speed = 1, maxTick = 240, looping = false,
      transportEnabled = true, mismatchTick = -1, povSlot = -1))
    ## The crypto panel is the SPECTATOR's view: the key and the goal are
    ## revealed to the audience, which is exactly what no seat is shown.
    check frame["crypto"]["goal"].getInt() == sim.goalLandmark
    check frame["crypto"]["key"].len == LandmarkCount
    for belief in frame["crypto"]["beliefs"]:
      check belief["alias"].getStr().endsWith("-alpha")
      check Sentinel notin belief["alias"].getStr()
