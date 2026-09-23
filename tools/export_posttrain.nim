## Export complete native particle-worlds games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import mpe/[sim, control, directives, baselines, decide, llm]

const
  Variants = ["default", "coop", "deception", "comms", "chase"]
  OperatorPrompt = "Use your role, observations, and public radio to coordinate your particle."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "default"
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown certified variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    var
      engine = initDecisionEngine(sim)
      orders = newSeq[CogOrder](4)
      inputs = newSeq[InputState](4)
      prev = newSeq[InputState](4)
      have = false
      played = 0
      rows: seq[string]
    while played < config.maxGames:
      if sim.phase == Lobby and sim.players.len < 4:
        for seat in 0 ..< 4:
          discard sim.addPlayer(config.slots[seat].name, seat,
            config.slots[seat].token, trusted = true)
        engine = initDecisionEngine(sim)
        inputs = newSeq[InputState](4)
        prev = newSeq[InputState](4)
        have = false
      if sim.phase == Playing:
        let turn = sim.gameTicksElapsed() div config.turnTicks
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          var views: array[4, string]
          var directives: array[4, SquadDirective]
          for seat in 0 ..< 4:
            views[seat] = engine.seatViewJson(sim, seat, turn, config.maxTicks div config.turnTicks)
            directives[seat] = scriptedDirective(engine.ctl, sim, blDrifter, @[seat])
          for seat in 0 ..< 4:
            let directive = directives[seat]
            let record = directive.directiveRecord(sim.roundIndex + 1,
              turn, seat, $sim.mode, sim.cogAlias(seat),
              roleName(sim.mode, sim.roleIndex[seat]))
            let completion = %*{"cogs": record["cogs"], "note": directive.note}
            let parsed = parseSquadDirective(completion, @[sim.cogAlias(seat)],
              @[seat], MapWidth div 2, MapHeight div 2, MapWidth, MapHeight)
            doAssert parsed.orders.len == 1
            doAssert parsed.orders[0].intent == directive.orders[0].intent
            doAssert parsed.orders[0].targetX == directive.orders[0].targetX
            doAssert parsed.orders[0].targetY == directive.orders[0].targetY
            doAssert parsed.orders[0].symbol == directive.orders[0].symbol
            rows.add($(%*{
              "episode_id": "particle-worlds-" & variant & "-" & $seed,
              "seed": "particle-worlds-" & variant & "-" & $seed,
              "decision_id":
                sim.roundIndex * config.maxTicks div config.turnTicks * 4 +
                turn * 4 + seat,
              "prompt": [
                {"role": "system", "content": SystemPrompt},
                {"role": "user", "content": userMessage(OperatorPrompt, views[seat])}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "particle-worlds",
              "action_schema_revision": "particle-worlds-directive-v1"
            }))
            orders[seat] = directive.orders[0]
            engine.directives[seat] = directive
            engine.haveDirective[seat] = true
            sim.installSymbol(seat, orders[seat].symbol, turn)
          have = true
        engine.ctl.observeEnemies(sim)
        if have:
          for seat in 0 ..< 4:
            inputs[seat] = decodeInputMask(
              engine.ctl.compileMask(sim, orders[seat], seat))
      else:
        for seat in 0 ..< 4:
          inputs[seat] = InputState()
      let before = sim.phase
      sim.step(inputs, prev)
      prev = inputs
      if before != GameOver and sim.phase == GameOver:
        inc played
    let outcome = parseJson(sim.particleResultsJson())
    doAssert outcome["reason"].getStr() == ReasonComplete
    doAssert rows.len > 0
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "wins": outcome["win"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "particle-worlds",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-drifter",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
