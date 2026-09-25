## The manifest against the sim. `num_agents` everywhere, the results schema
## key-for-key in BOTH directions, the docs and protocols as non-empty TEXT, and
## every variant's game_config actually constructing a valid sim (the
## collab-cooking 0.1.1 scar: test EVERY variant, not just the fixture).

import std/[json, sets, strutils, unittest]
import bitworld/spriteprotocol
import ../src/mpe/sim
import fixture

proc mapItStr(items: seq[JsonNode]): seq[string] =
  for item in items:
    result.add(item.getStr())

let manifest = manifestJson()

proc configFrom(node: JsonNode): GameConfig =
  ## `tokens` are RUNNER-managed and must not appear in an authored game_config
  ## (coworld 0.1.42 rejects one at `matriculate`), so the test injects them the
  ## way the runner does before constructing the sim.
  var withTokens = copy(node)
  var tokens = newJArray()
  for seat in 0 ..< FixtureSeats:
    tokens.add(%("token-" & $seat))
  withTokens["tokens"] = tokens
  result = defaultGameConfig()
  result.update($withTokens)

suite "the manifest":

  test "num_agents is 4 in every variant AND in the certification fixture":
    check manifest["variants"].len == 5
    for variant in manifest["variants"]:
      check variant["game_config"]["num_agents"].getInt() == FixtureSeats
      check variant.hasKey("description")
      check variant["description"].getStr().len > 40
      check variant["game_config"]["players"].len == FixtureSeats
      check variant["game_config"]["slots"].len == FixtureSeats
      ## `tokens` are runner-managed: the schema requires them and the runner
      ## injects one per seated player, but an authored game_config carrying
      ## them fails certification `manifest_invalid: game_config must not
      ## include runner-managed tokens` (particle-worlds 0.1.0).
      check not variant["game_config"].hasKey("tokens")
    let cert = manifest["certification"]
    check cert["game_config"]["num_agents"].getInt() == FixtureSeats
    check cert["players"].len == FixtureSeats
    check cert["game_config"]["players"].len == FixtureSeats
    check cert["game_config"]["slots"].len == FixtureSeats
    check not cert["game_config"].hasKey("tokens")
    ## EVERY declared player must occupy a certification slot (the raid 0.1.2
    ## players_missing scar).
    var declared: HashSet[string]
    for player in manifest["player"]:
      declared.incl(player["id"].getStr())
    var seated: HashSet[string]
    for slot in cert["players"]:
      seated.incl(slot["player_id"].getStr())
    check declared == seated

  test "results_schema keys == particleResultsJson keys, both directions":
    var sim = seatedSim(fixtureConfig())
    sim.seatNames = ["a", "b", "c", "d"]
    sim.roundAccum = [500'i64, 500, 500, 500]
    sim.bankRound(1, EndRuleFullTime)
    let
      produced = parseJson(sim.particleResultsJson())
      schema = manifest["game"]["results_schema"]
    check schema["additionalProperties"].getBool() == false
    var
      schemaKeys: HashSet[string]
      producedKeys: HashSet[string]
    for key in schema["properties"].keys:
      schemaKeys.incl(key)
    for key in produced.keys:
      producedKeys.incl(key)
    check schemaKeys.len == 22
    for key in schemaKeys:
      if key notin producedKeys:
        echo "schema key not produced: ", key
      check key in producedKeys
    for key in producedKeys:
      if key notin schemaKeys:
        echo "produced key not in schema: ", key
      check key in schemaKeys
    for name in ["names", "scores", "win", "reason", "endRule", "roundsPlayed"]:
      check name in schema["required"].getElems().mapItStr()
    ## The ten seat-indexed arrays are pinned to exactly num_agents entries.
    for name in ["names", "scores", "win", "alias", "colour", "roles",
                 "roundScores", "bumps", "llmTurns", "fallbackTurns"]:
      let prop = schema["properties"][name]
      check prop["minItems"].getInt() == FixtureSeats
      check prop["maxItems"].getInt() == FixtureSeats
      check produced[name].len == FixtureSeats
    ## The six round-indexed arrays carry 1..4 entries.
    for name in ["coverPct", "tagTicks", "goalHits", "modes", "roundTicks",
                 "roundEndRules"]:
      let prop = schema["properties"][name]
      check prop["minItems"].getInt() == 1
      check prop["maxItems"].getInt() == 4
      check produced[name].len >= 1
      check produced[name].len <= 4
    ## And the inner arrays of roles / roundScores are bounded too.
    for name in ["roles", "roundScores"]:
      let items = schema["properties"][name]["items"]
      check items["minItems"].getInt() == 1
      check items["maxItems"].getInt() == 4
    check schema["properties"]["reason"]["enum"].len == 3
    check schema["properties"]["endRule"]["enum"].len == 4
    check schema["properties"]["roundEndRules"]["items"]["enum"].len == 2
    check schema["properties"]["modes"]["items"]["enum"].len == 4

  test "protocols carry BOTH player and global, in OBJECT form":
    let protocols = manifest["game"]["protocols"]
    for side in ["player", "global"]:
      check protocols.hasKey(side)
      check protocols[side].kind == JObject
      check protocols[side]["type"].getStr() == "text"
      check protocols[side]["value"].getStr().len > 500

  test "docs carry a readme and three non-empty TEXT pages":
    let docs = manifest["game"]["docs"]
    check docs["readme"]["type"].getStr() == "text"
    check docs["readme"]["value"].getStr().len > 500
    check docs["pages"].len == 3
    var ids: HashSet[string]
    for page in docs["pages"]:
      ids.incl(page["id"].getStr())
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr() == "text"
      check page["content"]["value"].getStr().len > 500
    check ids == ["rules", "protocol", "commanding"].toHashSet()

  test "the replay viewer is the STATIC bundle, never a pod":
    check manifest["game"]["replay_viewer"]["bundle"].getStr() ==
      "static-replay-viewer"
    check not manifest.hasKey("replay_viewer")
    check not manifest.hasKey("version")
    check not manifest["game"].hasKey("display_name")
    check manifest["game"]["owner"].getStr().len > 0
    check manifest["game"]["runnable"]["type"].getStr() == "game"
    check manifest["episode_timeout_minutes"].getInt() == 20
    check manifest["tags"].len >= 3
    check manifest.hasKey("$schema")

  test "every variant's wallClockBudgetSeconds is inside 60% of the timeout":
    let ceiling = manifest["episode_timeout_minutes"].getInt() * 60 * 6 div 10
    check ceiling == 720
    for variant in manifest["variants"]:
      check variant["game_config"]["wallClockBudgetSeconds"].getInt() <= ceiling
    check manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getInt() <= ceiling

  test "every ARRAY property in config_schema declares minItems/maxItems":
    let schema = manifest["game"]["config_schema"]
    check schema["additionalProperties"].getBool() == false
    check schema["required"].getElems().mapItStr() == @["tokens", "players"]
    for name, prop in schema["properties"]:
      if prop.hasKey("type") and prop["type"].getStr() == "array":
        check prop.hasKey("minItems")
        check prop.hasKey("maxItems")

  test "config_schema covers the particle-worlds surface and nothing unread":
    let
      schema = manifest["game"]["config_schema"]["properties"]
      source = sourceOf("src/mpe/sim_config.nim")
    ## Every declared property must be a field `sim_config.update` really
    ## reads, so a manifest cannot offer a knob the engine ignores.
    for name in schema.keys:
      if name in ["tokens", "players", "slots"]:
        continue                       ## read by the roster readers
      check ("\"" & name & "\"") in source
    ## And every constant the design pins must be offered.
    for name in ["rounds", "num_agents", "minPlayers", "teams", "cogsPerTeam",
                 "maxTicks", "maxGames", "turnTicks", "turnBudgetMs",
                 "attempt1Ms", "retryMs", "turnSpacingMs",
                 "wallClockBudgetSeconds", "lobbyJoinTimeoutTicks",
                 "startWaitTicks", "gameOverTicks", "mapPath", "fastMode",
                 "showPlayerLabels", "fullyObservable", "visionConeDeg",
                 "visionBubble", "motionScale", "accel", "maxSpeed",
                 "frictionNum", "frictionDen", "stopThreshold",
                 "playerBouncePct", "aimTurnRate", "pursuerAccelPct",
                 "pursuerSpeedPct", "landmarkRadius", "landmarkMargin",
                 "landmarkSpacingPx", "spawnRingPx", "closeScalePx", "bumpPx",
                 "bumpPenaltyPermille", "bumpPenaltyCap", "tagPx",
                 "tagTargetTicks", "orbitRadiusPx", "shadowStandoffPx",
                 "evadeProbePx", "symbolCount",
                 "seed"]:
      check schema.hasKey(name)

  test "the compose service derives the image placeholder":
    let compose = sourceOf("compose.yaml")
    ## Manifest image placeholders come from COMPOSE SERVICE NAMES (the lantern
    ## 0.1.0 scar): service `particle_worlds` -> {{PARTICLE_WORLDS_IMAGE}}.
    check "particle_worlds:" in compose
    check "image: coworld-particle-worlds:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    check manifest["game"]["runnable"]["image"].getStr() ==
      "{{PARTICLE_WORLDS_IMAGE}}"
    for player in manifest["player"]:
      check player["image"].getStr() == "{{PARTICLE_WORLDS_IMAGE}}"

  test "game identity is stable and the game receives no model secret":
    let name = manifest["game"]["name"].getStr()
    check name == "particle-worlds"
    check name == GameName
    check not manifest["game"]["runnable"].hasKey("env")

  test "the entrypoints are the ones the image builds":
    let dockerfile = sourceOf("Dockerfile")
    check manifest["game"]["runnable"]["run"][0].getStr() ==
      "/bin/particle-worlds"
    check "/bin/particle-worlds" in dockerfile
    check "/bin/particle-worlds-player" in dockerfile
    for player in manifest["player"]:
      check player["run"][0].getStr() == "/bin/particle-worlds-player"
    ## And every policy runs the SAME image, env-switched.
    let policies = parseJson(sourceOf("tools/ci/policies.json"))
    check policies.len == 4
    var prompts = 0
    var scripted = 0
    var owned = 0
    for policy in policies:
      check policy["run"].getStr() == "/bin/particle-worlds-player"
      check policy["name"].getStr().startsWith("particle-worlds-")
      if policy["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 400
      if policy["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["drifter", "beeline"]
      if policy.hasKey("player"):
        inc owned
        check policy["player"].getStr() ==
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    check prompts == 2          ## BOTH champions are LLM prompt policies
    check scripted == 2         ## two scripted fillers
    check owned == 1            ## champion #2 is owned by daveey-1

  test "EVERY variant's game_config constructs a valid sim":
    ## The collab-cooking 0.1.1 scar: a config-scaled mint blew a cap at the
    ## variants' maxTicks while the smaller cert fixture fit, and every league
    ## episode came back game_unhealthy with no logs after a green cert.
    for variant in manifest["variants"]:
      var config = configFrom(variant["game_config"])
      check config.numAgents == FixtureSeats
      check config.rounds.len >= 1
      var sim = initSimServer(config)
      for seat in 0 ..< FixtureSeats:
        discard sim.addPlayer(
          config.slots[seat].name, seat, config.slots[seat].token)
      sim.startGame()
      check sim.landmarks.len == LandmarkCount
      sim.checkFieldInvariants()
      ## And a handful of ticks of every variant really run.
      var inputs = newSeq[InputState](sim.players.len)
      for tick in 0 ..< 48:
        sim.step(inputs, inputs)
      check sim.phase == Playing

  test "the certification fixture constructs and outlasts a viewer soak":
    var config = configFrom(manifest["certification"]["game_config"])
    check config.numAgents == FixtureSeats
    check config.turnSpacingMs == 0        ## no rate floor offline
    check config.rounds.len == 4           ## all four modes are exercised
    var sim = initSimServer(config)
    for seat in 0 ..< FixtureSeats:
      discard sim.addPlayer(
        config.slots[seat].name, seat, config.slots[seat].token)
    sim.startGame()
    sim.checkFieldInvariants()
    ## 4 x 240 ticks = 960 ticks = 40 s of playback at 24 fps, deliberately
    ## longer than any viewer soak window (the ecos 2026-08-23 scar).
    let playbackSeconds = config.maxTicks * config.maxGames div ReplayFps
    check playbackSeconds >= 30
    ## And the fixture must still certify inside a 300 s timeout.
    check config.maxTicks * config.maxGames <= 4000
