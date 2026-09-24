## Persistent JSONL bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:particle-worlds-train-bridge tools/train_bridge.nim

import std/[json, os, posix]
import bitworld/spriteprotocol
import mpe/[sim, control, directives, baselines, decide, llm]

const
  Variants = ["default", "coop", "deception", "comms", "chase"]
  Modes = ["spread", "deceive", "crypto", "tag"]
  Roles = ["cooperator", "adversary", "good", "speaker", "listener",
    "eavesdropper", "evader", "pursuer"]
  Colours = ["amber", "teal", "violet", "bone"]
  Teams = ["red", "blue", "green", "yellow"]
  Intents = ["go", "hold", "cover", "shadow", "evade", "orbit"]
  Fields = ["intent", "target_x", "target_y", "face", "face_x", "face_y", "symbol"]
  OperatorPrompt = "Use your role, observations, and public radio to coordinate your particle."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32) + 1

proc heads(): JsonNode =
  result = newJArray()
  for name in Fields:
    var choices = newJArray()
    case name
    of "intent":
      for value in Intents: choices.add(%value)
    of "symbol":
      choices.add(%"-")
      for letter in SymbolAlphabet: choices.add(%($letter))
    else:
      let high = case name
        of "target_x", "face_x": MapWidth
        of "target_y", "face_y": MapHeight
        else: 1
      for value in 0 .. high: choices.add(%value)
    result.add(%*{"name": name, "choices": choices})

proc number(node: JsonNode): float =
  case node.kind
  of JInt: node.getInt().float
  of JFloat: node.getFloat()
  of JBool: (if node.getBool(): 1.0 else: 0.0)
  else: raise newException(ValueError, "expected numeric observation: " & $node)

proc values(view: JsonNode, variant: string): JsonNode =
  result = newJArray()
  for name in Variants: result.add(%(if name == variant: 1 else: 0))
  for name in Modes: result.add(%(if view["mode"].getStr() == name: 1 else: 0))
  for name in ["round", "of", "turn", "turns"]: result.add(%view[name].number())
  for name in ["played_s", "left_s"]: result.add(%view["clock"][name].number())
  for name in ["w", "h"]: result.add(%view["field"][name].number())
  for value in view["field"]["centre"]: result.add(%value.number())
  let me = view["you"]
  for name in Roles: result.add(%(if me["role"].getStr() == name: 1 else: 0))
  result.add(%(if me["anchored"].getBool(): 1 else: 0))
  for name in ["pos", "vel"]:
    for value in me[name]: result.add(%value.number())
  for name in ["speed_px_s", "accel_px_s2", "max_px_s"]:
    result.add(%me[name].number())
  let marks = view["marks"]
  doAssert marks.len == LandmarkCount
  for item in marks:
    for value in item["pos"]: result.add(%value.number())
    for name in Colours:
      result.add(%(if item["colour"].getStr() == name: 1 else: 0))
    result.add(%item["r"].number())
  let agents = view["agents"]
  doAssert agents.len == 4
  for item in agents:
    for name in Roles:
      result.add(%(if item["role"].getStr() == name: 1 else: 0))
    result.add(%(if item["anchored"].getBool(): 1 else: 0))
    for name in ["pos", "vel"]:
      for value in item[name]: result.add(%value.number())
    for name in Teams:
      result.add(%(if item["colour"].getStr() == name: 1 else: 0))
  for item in view["radio"]:
    for name in ["now", "last"]:
      result.add(%symbolIndexOfText(item[name].getStr()))
  let secret = view["secret"]
  result.add(%(if secret["goal"].kind == JNull: -1 else: secret["goal"].getInt()))
  for name in Colours:
    result.add(%(if secret["goal_colour"].kind != JNull and
      secret["goal_colour"].getStr() == name: 1 else: 0))
  result.add(%(if secret["key"].kind == JNull: 0 else: 1))
  if secret["key"].kind == JNull:
    for _ in 0 ..< LandmarkCount * 2: result.add(%0)
  else:
    doAssert secret["key"].len == LandmarkCount
    for pair in secret["key"]:
      result.add(%symbolIndexOfText(pair[0].getStr()))
      var colour = 0
      for i, name in Colours:
        if pair[1].getStr() == name: colour = i + 1
      result.add(%colour)
  for agent in agents:
    var found = false
    for item in view["beliefs"]:
      if item["id"].getStr() == agent["id"].getStr():
        found = true
        result.add(%item["nearest_mark"].number())
        result.add(%item["settled_ticks"].number())
    result.add(%(if found: 1 else: 0))
    if not found:
      result.add(%0)
      result.add(%0)
  for name in ["this_round_so_far", "episode_so_far"]:
    result.add(%view["score"][name].number())
  let banked = view["score"]["rounds_banked"]
  doAssert banked.len <= 4
  for i in 0 ..< 4:
    result.add(%(if i < banked.len: banked[i].number() else: 0.0))
  for name in ["cover_pct", "bumps", "tag_ticks"]:
    result.add(%(if view.hasKey(name): view[name].number() else: 0.0))
  for i in 0 ..< 4:
    result.add(%(if view.hasKey("contact"): view["contact"][i].number() else: 0.0))

proc action(order: CogOrder): JsonNode =
  %*{"intent": $order.intent, "target_x": order.targetX,
    "target_y": order.targetY, "face": (if order.hasFace: 1 else: 0),
    "face_x": (if order.hasFace: order.faceX else: 0),
    "face_y": (if order.hasFace: order.faceY else: 0),
    "symbol": symbolTextOf(order.symbol)}

proc hostedDirective(candidate: JsonNode, alias: string): JsonNode =
  var order = %*{"id": alias, "intent": candidate["intent"],
    "target": [candidate["target_x"], candidate["target_y"]],
    "symbol": candidate["symbol"]}
  if candidate["face"].getInt() == 1:
    order["face"] = %[candidate["face_x"], candidate["face_y"]]
  %*{"cogs": [order]}

proc decision(view: JsonNode, seat, id: int): JsonNode =
  var properties = newJObject()
  var required = newJArray()
  for head in heads():
    let name = head["name"].getStr()
    properties[name] = %*{"enum": head["choices"]}
    required.add(%name)
  %*{"kind": "decision", "game": "particle-worlds", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": view["turn"],
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(OperatorPrompt, $view)}],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": properties,
      "required": required}, "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2: quit("usage: particle-worlds-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  doAssert variant in Variants
  let manifest = parseFile(args[0])
  setCurrentDir(absolutePath(args[0]).parentDir)
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var game: SimServer
  var engine: DecisionEngine
  var views: array[4, JsonNode]
  var teachers: array[4, JsonNode]
  var orders: array[4, CogOrder]
  var inputs: array[4, InputState]
  var prev: array[4, InputState]
  var seat = 0
  var turn = 0
  var id = 0
  var played = 0
  let protocolFd = dup(1)
  doAssert protocolFd >= 0 and dup2(2, 1) >= 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 4
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      game = initSimServer(config)
      for actor in 0 ..< 4:
        discard game.addPlayer(config.slots[actor].name, actor,
          config.slots[actor].token, trusted = true)
      engine = initDecisionEngine(game)
      inputs = default(array[4, InputState])
      prev = inputs
      while game.phase != Playing:
        game.step(inputs, prev)
      turn = 0
      for actor in 0 ..< 4:
        views[actor] = parseJson(engine.seatViewJson(game, actor, turn,
          config.maxTicks div config.turnTicks))
        teachers[actor] = action(scriptedDirective(engine.ctl,
          game, blDrifter, @[actor]).orders[0])
      seat = 0
      id = 0
      played = 0
      response = views[seat].decision(seat, id)
    of "encode":
      doAssert played < game.config.maxGames
      response = %*{"decision_id": id,
        "values": views[seat].values(variant), "action_heads": heads()}
    of "teacher":
      doAssert played < game.config.maxGames
      response = %*{"response": $teachers[seat]}
    of "step":
      doAssert played < game.config.maxGames and request["decision_id"].getInt() == id
      let candidate = parseJson(request["response"].getStr())
      for head in heads():
        doAssert candidate[head["name"].getStr()] in head["choices"]
      let directive = parseSquadDirective(
        candidate.hostedDirective(game.cogAlias(seat)), @[game.cogAlias(seat)],
        @[seat], MapWidth div 2, MapHeight div 2, MapWidth, MapHeight)
      doAssert directive.orders.len == 1
      orders[seat] = directive.orders[0]
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      inc id
      inc seat
      var observation: JsonNode
      if seat < 4:
        observation = views[seat].decision(seat, id)
      else:
        for actor in 0 ..< 4:
          game.installSymbol(actor, orders[actor].symbol, turn)
        while game.phase == Playing:
          engine.ctl.observeEnemies(game)
          for actor in 0 ..< 4:
            inputs[actor] = decodeInputMask(
              engine.ctl.compileMask(game, orders[actor], actor))
          game.step(inputs, prev)
          prev = inputs
          if game.phase == Playing and game.gameTicksElapsed() mod game.config.turnTicks == 0:
            break
        if game.phase == GameOver:
          inc played
        if played == game.config.maxGames:
          let outcome = parseJson(game.particleResultsJson())
          var scores = newJObject()
          var utilities = newJObject()
          for actor in 0 ..< 4:
            let score = outcome["scores"][actor].number()
            scores[$actor] = %score
            utilities[$actor] = %(2.0 * score - 1.0)
          observation = %*{"kind": "terminal", "scores": scores,
            "utilities": utilities}
        else:
          if game.phase == GameOver:
            while game.phase != Lobby: game.step(inputs, prev)
            for actor in 0 ..< 4:
              discard game.addPlayer(game.config.slots[actor].name, actor,
                game.config.slots[actor].token, trusted = true)
            engine = initDecisionEngine(game)
            inputs = default(array[4, InputState])
            prev = inputs
            while game.phase != Playing: game.step(inputs, prev)
          turn = game.gameTicksElapsed() div game.config.turnTicks
          seat = 0
          for actor in 0 ..< 4:
            views[actor] = parseJson(engine.seatViewJson(game, actor, turn,
              game.config.maxTicks div game.config.turnTicks))
            teachers[actor] = action(scriptedDirective(engine.ctl,
              game, blDrifter, @[actor]).orders[0])
          observation = views[seat].decision(seat, id)
      response = %*{"kind": "accepted", "action": candidate,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.flushFile()
    doAssert dup2(protocolFd, 1) >= 0
    stdout.writeLine($response)
    stdout.flushFile()
    doAssert dup2(2, 1) >= 0
