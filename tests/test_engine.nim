## The ordinary-player turn batch, retry, and fallback boundary.

import std/[json, unittest]
import ../src/mpe/[sim, directives, decide]
import fixture

proc externalEngine(sim: SimServer): DecisionEngine =
  result = initDecisionEngine(sim)
  for seat in 0 ..< result.seats.len:
    result.seats[seat].isExternal = true
    result.seats[seat].registered = true
    result.seats[seat].label = "test-player"

proc replyFor(view: string): BatchReply =
  let observation = parseJson(view)
  let action = %*{
    "note": "from ordinary player",
    "cogs": [{
      "id": observation["you"]["id"],
      "intent": "cover", "target": [400, 300], "symbol": "F"
    }]
  }
  BatchReply(ok: true, action: $action)

suite "ordinary player turn loop":
  test "one batch carries four distinct private views":
    let sim = seatedSim(fixtureConfig(@[modeCrypto]))
    var engine = externalEngine(sim)
    var batches = 0
    engine.batch = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      inc batches
      check calls.len == 4
      check timeoutSeconds > 0
      for call in calls:
        check call.seat in 0 ..< 4
        let view = parseJson(call.view)
        check view["you"]["id"].getStr() in
          ["RED-alpha", "BLUE-alpha", "GREEN-alpha", "YELLOW-alpha"]
        check not view.hasKey("policy")
        result.add(replyFor(call.view))
    let records = engine.turn(sim, 0, 10, 0)
    check batches == 1
    check records.len == 0
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsLlm
      check engine.directives[seat].orders[0].cogIndex == seat

  test "unusable actions retry once and produce one fallback per seat":
    let sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = externalEngine(sim)
    var batches = 0
    engine.batch = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      inc batches
      for call in calls:
        check call.retry == (batches == 2)
        result.add(BatchReply(ok: true, action: "{}"))
    let records = engine.turn(sim, 1, 10, 0)
    check batches == 2
    check records.len == 4
    for record in records:
      let node = parseJson(record)
      check node["k"].getStr() == "fallback"
      check node["attempt"].getInt() == 2
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsFallback
      check engine.directives[seat].orders.len == 1

  test "reported no credentials falls back without a retry":
    let sim = seatedSim(fixtureConfig(@[modeSpread]))
    var engine = externalEngine(sim)
    var batches = 0
    engine.batch = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      inc batches
      for call in calls:
        result.add(BatchReply(cause: "no_credentials", error: "player has no key"))
    let records = engine.turn(sim, 0, 10, 0)
    check batches == 1
    check records.len == 4
    for record in records:
      let node = parseJson(record)
      check node["cause"].getStr() == "no_credentials"
      check node["attempt"].getInt() == 1

  test "budget guard skips player calls and keeps legal directives":
    var config = fixtureConfig(@[modeSpread])
    config.wallClockBudgetSeconds = 30
    let sim = seatedSim(config)
    var engine = externalEngine(sim)
    var batches = 0
    engine.batch = proc(calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
        {.closure, gcsafe.} =
      inc batches
    let records = engine.turn(sim, 5, 10, 25)
    check engine.externalOff
    check batches == 0
    check records.len == 5
    for seat in 0 ..< 4:
      check engine.directives[seat].source == dsFallback
      check engine.directives[seat].orders.len == 1
