## Stream complete private candidate games; shared review owns training admission.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT EPISODES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]

import std/[json, os, osproc, strutils]
import bitworld/spriteprotocol
import mpe/[sim, control, directives, baselines, decide, llm, prompts, evidence]

const
  Variants = ["default", "coop", "deception", "comms", "chase"]
  OperatorPrompt = "Use your role, observations, and public radio to coordinate your particle."

proc main() =
  let args = commandLineParams()
  if args.len notin 2 .. 6:
    quit("usage: export_posttrain OUTPUT EPISODES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT] [PROMPT_SEED]", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "default"
  var promptConfig = newJObject()
  if args.len >= 5: promptConfig["promptVariant"] = %args[4]
  if args.len == 6: promptConfig["promptSeed"] = %parseInt(args[5])
  let selection = promptSelection(promptConfig)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot enter training sources", 1)
  if episodes < 10 or firstSeed < 1:
    quit("at least ten episodes and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown certified variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting private candidates"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let sourceRevision = head.output.strip()
  writePrivate(output / "trajectories.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  defer: stream.close()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + episodes:
    let family = "particle-worlds-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    var
      engine = initDecisionEngine(sim, selection)
      orders = newSeq[CogOrder](4)
      inputs = newSeq[InputState](4)
      prev = newSeq[InputState](4)
      have = false
      played = 0
      decisions = 0
      pending = newJArray()
    while played < config.maxGames:
      if sim.phase == Lobby and sim.players.len < 4:
        for seat in 0 ..< 4:
          discard sim.addPlayer(config.slots[seat].name, seat,
            config.slots[seat].token, trusted = true)
        engine = initDecisionEngine(sim, selection)
        inputs = newSeq[InputState](4)
        prev = newSeq[InputState](4)
        have = false
      if sim.phase == Playing:
        let turn = sim.gameTicksElapsed() div config.turnTicks
        if sim.gameTicksElapsed() mod config.turnTicks == 0:
          for record in pending: stream.writeLine($record)
          pending = newJArray()
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
              @[seat], MapWidth div 2, MapHeight div 2, MapWidth - 1, MapHeight - 1)
            doAssert parsed.orders.len == 1
            doAssert parsed.orders[0].intent == directive.orders[0].intent
            doAssert parsed.orders[0].targetX == directive.orders[0].targetX
            doAssert parsed.orders[0].targetY == directive.orders[0].targetY
            doAssert parsed.orders[0].symbol == directive.orders[0].symbol
            let system = systemPrompt(selection)
            let user = userMessage(OperatorPrompt, views[seat])
            let messages = %*[{"role": "system", "content": system},
              {"role": "user", "content": user}]
            var observation = parseJson(views[seat])
            observation["prompt_template"] = selection.promptMetadata(system, user)
            let applied = parsed.directiveRecord(sim.roundIndex + 1,
              turn, seat, $sim.mode, sim.cogAlias(seat), roleName(sim.mode, sim.roleIndex[seat]))
            let executed = %*{"cogs": applied["cogs"], "note": parsed.note}
            doAssert completion == executed
            let attemptId = $decisions & "-teacher"
            pending.add(%*{
              "schema_version": "1", "event_type": "decision", "episode_id": episode,
              "decision_id": $decisions, "decision_index": decisions,
              "game": "particle-worlds", "game_version": "source-" & sourceRevision,
              "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
              "observation": observation, "prompt": messages,
              "attempts": [{"attempt_id": attemptId, "policy": "scripted-drifter",
                "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
                "response": $completion, "parsed_action": completion, "accepted": true,
                "request": newJNull(), "platform_call_id": newJNull(),
                "behavior_logprobs": newJNull(), "rejection_reason": newJNull()}],
              "selected_attempt_id": attemptId, "executed_action": executed,
              "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false
            })
            inc decisions
            orders[seat] = parsed.orders[0]
            engine.directives[seat] = parsed
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
    doAssert decisions > 0
    for record in pending:
      record["terminal"] = %true
      stream.writeLine($record)
    var participants = newJObject()
    for seat in 0 ..< 4:
      participants[$seat] = %*{"score": outcome["scores"][seat]}
    stream.writeLine($(%*{
      "schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "particle-worlds", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed",
      "outcome": outcome, "participant_outcomes": participants
    }))
    runs.add(%*{"seed": seed, "decisions": decisions,
      "scores": outcome["scores"], "wins": outcome["win"]})
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "particle-worlds",
    "variant": variant,
    "source_revision": sourceRevision,
    "prompt_configuration": selection.selectionMetadata(),
    "teacher": "scripted-drifter",
    "operator_prompt": OperatorPrompt,
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "runs": runs
  }) & "\n")
  echo "complete private games=", episodes

when isMainModule:
  main()
